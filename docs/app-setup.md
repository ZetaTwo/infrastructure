# App setup

Deploying and managing apps on an already-set-up cluster: GitOps, the
staging/production pattern, per-app secrets bootstrap, and the shared auth
gate. For provisioning the cluster itself, see
[Cluster setup](cluster-setup.md). If the app is stateful (has a PVC worth
losing sleep over), see [Backups](backups.md) too.

## GitOps (Flux CD)

Flux CD runs in the cluster (`ansible/roles/flux`) with a `GitRepository`
pointing at this repo's `main` branch (read-only, via a GitHub Deploy Key —
see [Cluster setup](cluster-setup.md#one-time-flux-bootstrap)) and a
`Kustomization` reconciling everything under `k8s/`. There is no `flux
bootstrap` step and no write access to this repo from inside the cluster —
Flux only ever reads.

`k8s/` has one subdirectory per app, each with its own `kustomization.yaml`,
aggregated by the root `k8s/kustomization.yaml`. **Adding a new app is: add
a subdirectory + one line in the root file + `git push`** — no Ansible or
Terraform changes needed for the deployment itself:

1. **Web apps only**: add a Cloudflare A record for the new hostname in
   `terraform/dns.tf` (on `var.cloudflare_zones["zetatwo_com"]` for a public
   app — or any other label in `cloudflare_zones` if it belongs elsewhere),
   then `make tf-apply`. Skip this for a headless app with no inbound
   traffic (e.g. `k8s/aoe2-tournament-bot/` — a Discord bot with no
   Service/Ingress at all, just a `Deployment`).
2. Each app gets its own namespace. Create
   `k8s/<name>/{namespace,deployment}.yaml` (plus `service.yaml`/
   `ingress.yaml` if it's a web app) and a `k8s/<name>/kustomization.yaml`
   listing them (`namespace.yaml` included as a resource, plus a top-level
   `namespace: <name>` in that file) — follow `k8s/aoe2-tournament-bot/`
   (headless, single environment) as the reference, or
   `k8s/aoe2-groups-proxy/` (web app with a staging + production split —
   see [Staging and production](#staging-and-production) below) if the new
   app needs the same split. The explicit namespace matters: unlike plain
   `kubectl apply`, Flux's kustomize-controller does **not** default
   un-namespaced resources to `default` and fails with a confusing
   `namespace not specified: the server could not find the requested
   resource` error instead — the `namespace:` transformer handles this
   correctly and leaves the cluster-scoped `Namespace` object itself
   untouched. If it does need an Ingress, annotate it
   `cert-manager.io/cluster-issuer: letsencrypt-prod` with
   `ingressClassName: traefik`, so cert-manager issues/renews its
   certificate automatically via HTTP-01 through Traefik.
3. Add `<name>` to `resources` in `k8s/kustomization.yaml`.
4. `git push` to `main`. Flux reconciles within ~1 minute (no
   `make ansible-apply` needed).

If the app needs a secret that shouldn't live in git (API keys, credentials
files), it does **not** go through Flux — add a small dedicated Ansible
role that keeps the secret material as `ansible-vault`-encrypted files
under the role's own `files/` directory (`ansible-vault encrypt <file>`),
ensures the app's namespace exists (a `kubernetes.core.k8s` `Namespace`
task — ordering against Flux creating the same namespace from
`k8s/<name>/namespace.yaml` isn't guaranteed, so both sides create it
idempotently), and applies the `Secret` as a `kubernetes.core.k8s` task
with an inline `definition:`, reading the encrypted files straight into
`stringData` via `lookup('file', role_path + '/files/...')` (which
transparently decrypts them) — nothing is ever written to disk on the
node. Follow `ansible/roles/aoe2_groups_proxy` as the reference (named
after the app, not "secrets," since it's that app's whole Ansible
footprint and may end up doing more than secrets later). The app's
Deployment (in `k8s/`) references that Secret by name only; Flux never
sees or manages it. This deliberately avoids adding a second
secrets-encryption system (e.g. SOPS) alongside `ansible-vault`.

Private images: `ghcr-pull-secret` (`ansible/roles/ghcr_pull_secret`)
exists for pulling private `ghcr.io` images — reference it from any app's
Deployment with `imagePullSecrets: [{name: ghcr-pull-secret}]` (see
`k8s/aoe2-groups-proxy/base/deployment.yaml`). Since k8s Secrets can't be
referenced across namespaces, the role loops over
`ghcr_pull_secret_namespaces` (`group_vars/all.yml`) and creates one copy
of the same underlying token per namespace — add a new app's namespace to
that list if it needs private image pulls, no other Ansible changes
needed. Note that GitHub package visibility is one-way — once a package is
made public it can't be made private again — so `aoe2-groups-proxy` stays
private and pulls via this secret rather than being flipped public.

Image updates: the app's own CI only builds and pushes images. It then
triggers this repo's `deploy` workflow (`.github/workflows/deploy.yml`),
which pins every target in `deploy-targets.toml` to its newest ghcr.io tag
and commits any change to `main` with its own `GITHUB_TOKEN`. Flux rolls
that commit out. App repos never write to this repo. Their only credential
is a GitHub App that can start workflows here (Actions: write) but can't
push code. The trigger carries no data: every run recomputes all targets,
so runs that GitHub coalesces in the workflow's concurrency group lose
nothing, and there's no race between apps.

Tag policies (per target in `deploy-targets.toml`):

- `release`: highest `vX[.Y[.Z]]` tag. The app's release job creates it by
  retagging an already-tested image (see
  [Staging and production](#staging-and-production) below).
- `main`: newest `main-<unix epoch>-<sha>` tag, pushed alongside `:<sha>`
  on every push to `main`. Used for staging.

The app-side CI step, after pushing the image:

```yaml
- uses: ZetaTwo/infrastructure/.github/actions/trigger-deploy@main
  with:
    client-id: ${{ secrets.DEPLOY_APP_CLIENT_ID }}
    private-key: ${{ secrets.DEPLOY_APP_PRIVATE_KEY }}
```

**Adding an app** to this flow takes three steps:
1. Add a `[[target]]` per environment to `deploy-targets.toml`. The target
   file needs exactly one `newTag:` line (kustomize overlay) or one
   `image: <image>:<tag>` line. An overlay with several images (e.g.
   `k8s/canst/overlays/staging/`) backs one target per image, with each
   image's `newTag:` directly under its own `- name: <image>` line.
2. In the package's settings on GitHub (Manage Actions access), give
   `ZetaTwo/infrastructure` Read access, so the workflow can list its tags.
3. Add the two `DEPLOY_APP_*` secrets to the app repo.

**Rolling back** means setting `hold = true` on the target and editing its
tag by hand. Remove `hold` to resume automatic updates.

One-time GitHub App setup: GitHub → Settings → Developer settings → GitHub
Apps → New GitHub App. Turn the webhook off. Give it one repository
permission, **Actions: Read and write**, and install it on
`ZetaTwo/infrastructure` only. Its client ID and a generated private key
become each app repo's `DEPLOY_APP_CLIENT_ID` / `DEPLOY_APP_PRIVATE_KEY`
secrets.

## Staging and production

Apps that need it get a kustomize `base` + `overlays/{staging,production}`
split (`k8s/aoe2-groups-proxy/` is the reference) instead of a flat
`k8s/<name>/` directory:

- `base/` holds the Deployment/Service common to both environments, with an
  inert placeholder image tag — every overlay's own `images:` transformer
  always overrides it by repository name, so the literal placeholder is
  never actually deployed.
- `overlays/staging/` adds its own `namespace.yaml` (`<name>-staging`),
  `ingress.yaml` (host `<name>.zetatwo.dev`, gated behind the oauth2-proxy
  `collaborators` policy — see
  [Auth (Google login via oauth2-proxy) bootstrap](#one-time-auth-google-login-via-oauth2-proxy-bootstrap)
  below), any environment-specific config as a strategic-merge patch (e.g.
  `allowed-origins-patch.yaml`), and an `images: newTag:` the deploy
  workflow updates after every push to the app's `main`.
- `overlays/production/` mirrors it with the app's real namespace, host
  `<name>.zeta-two.com` (public, no auth middleware), and an `images:
  newTag:` the deploy workflow updates **only** when a release tag appears.
- Root `k8s/kustomization.yaml` lists both overlays as separate resources
  — they're two permanently co-resident Deployments, not templated
  variants of one.

CI's production job doesn't rebuild the image — it verifies the release's
commit already produced a `:<sha>` image (via the `deploy-staging` job
having already run against it) and promotes that exact artifact with
`docker buildx imagetools create --tag <image>:<release-tag>
<image>:<sha>`, so what ships to production is bit-identical to what was
tested in staging. See `aoe2-streaming`'s `.github/workflows/
backend-deploy.yml` for the reference `deploy-staging`/`deploy-production`
implementation. If a release is cut from a commit that never went through
`deploy-staging` (e.g. tagged from a branch, not `main`), this step fails
loudly rather than promoting an untested artifact.

Not every app needs this split — `aoe2-tournament-bot` (a Discord bot)
deliberately has no staging tier, since Discord allows only one gateway
connection per bot token and a second running instance would conflict with
production. It still moved from "deploy on every push" to "deploy only on
release, promoting the tested image" (see `.github/workflows/ci.yml`'s
`deploy-production` job) — it just has one environment instead of two.

One naming gotcha: plain Kustomize's config file (`kustomization.yaml`,
`apiVersion: kustomize.config.k8s.io/v1beta1`, never applied to the
cluster, just consumed by `kubectl kustomize`/`kustomize build`) and Flux's
own custom resource (`kind: Kustomization`,
`apiVersion: kustomize.toolkit.fluxcd.io/v1`, a live object in-cluster) are
unrelated things that happen to share a name.

## Shared Postgres

`k8s/postgres/` runs one Postgres 16 StatefulSet for every app, at
`postgres.postgres.svc.cluster.local:5432`, on a `local-path` PVC (so
[Backups](backups.md) are the only recovery mechanism). It's one instance
rather than one per app to keep memory and upgrade overhead flat as apps
are added. Each app (and each environment of an app) gets its own role and
database of the same name. The role owns the database, so the app can run
its own migrations, and `CONNECT` is revoked from `PUBLIC` so apps can't
reach each other's databases.

The StatefulSet is Flux-managed. Everything secret is Ansible's
(`ansible/roles/postgres`): the `postgres-superuser` Secret, and an
idempotent `psql` run inside `postgres-0` per `postgres_databases` entry
that creates the role and database if missing and resets the password
every run, so the vaulted value stays the source of truth.

**An app gets a database** by:

1. Generating and vault-encrypting a password as `<db>_db_password` (same
   command as the restic password in [Backups](backups.md)) and appending it
   to `ansible/group_vars/all.yml`.
2. Adding `{name: <db>, password: "{{ <db>_db_password }}"}` to
   `postgres_databases`.
3. Giving the app its connection string from its own Ansible role, e.g. a
   rendered config file Secret (see `ansible/roles/canst`), never in git.
4. `make ansible-apply`.

On the very first rollout, push `k8s/postgres/` and then run
`make ansible-apply` straight away — don't wait for `postgres-0` first.
The pod can't start until the role has created its `postgres-superuser`
Secret (until then it sits in `CreateContainerConfigError`, which is
expected); the role creates the Secret, then waits up to 5 minutes for the
pod to become Ready before provisioning databases.

Major-version upgrades are a dump/restore, not an image tag bump.

## One-time canst staging bootstrap

canst (`ZetaTwo/canst`) staging runs at `canst.zetatwo.dev`, gated by the
`collaborators` policy, from `k8s/canst/` (`base/` plus
`overlays/staging/`): a backend Deployment whose `migrate` initContainer
applies pending migrations before each rollout, a Caddy frontend serving
the built SPA, an Ingress routing `/api` to the backend and everything else
to the frontend, and a nightly backup CronJob.

Its secrets are already vaulted in `ansible/group_vars/all.yml`
(`canst_staging_db_password`, `canst_staging_paseto_key`,
`canst_staging_restic_password`, plus `postgres_superuser_password`).
`ansible/roles/canst` renders them into a `canst-config` Secret holding
the backend's `config.toml`. On a fresh setup:

1. Do the [backups bucket bootstrap](cluster-setup.md#one-time-backups-bucket-bootstrap)
   if it hasn't been done yet.
2. `make tf-apply` for the `canst` DNS record.
3. Push `k8s/postgres/`, then run `make ansible-apply` straight away (see
   [Shared Postgres](#shared-postgres) for why not to wait for the pod).
4. Wire up the deploy flow (see [GitOps](#gitops-flux-cd)): give this repo
   read access to both `canst-backend` and `canst-frontend` packages, and
   add the `DEPLOY_APP_*` secrets to the canst repo.
5. Promote the first admin (canst has no bootstrap route by design):
   ```sh
   kubectl exec -n postgres postgres-0 -- psql -U postgres -d canst_staging \
     -c "UPDATE users SET is_admin = true WHERE username = '<name>'"
   ```

## One-time aoe2-groups-proxy production secrets bootstrap

1. Export the runtime service account's key and fetch the real
   `sheet-ids.toml`:
   ```sh
   gcloud iam service-accounts keys create service-account.json \
     --iam-account=groups-proxy@aoe2-streaming.iam.gserviceaccount.com \
     --project=aoe2-streaming
   gcloud secrets versions access latest \
     --secret=aoe2-groups-proxy-sheet-ids --project=aoe2-streaming \
     > sheet-ids.toml
   ```
2. Move both into the role's `files/production/` and vault-encrypt them in
   place:
   ```sh
   mv service-account.json sheet-ids.toml ansible/roles/aoe2_groups_proxy/files/production/
   ansible-vault encrypt ansible/roles/aoe2_groups_proxy/files/production/service-account.json \
     --vault-password-file ansible/.vault_pass
   ansible-vault encrypt ansible/roles/aoe2_groups_proxy/files/production/sheet-ids.toml \
     --vault-password-file ansible/.vault_pass
   ```
3. `make ansible-apply`.

## One-time aoe2-groups-proxy staging secrets bootstrap

The per-environment split under `ansible/roles/aoe2_groups_proxy/files/`
supports fully separate credentials per environment (each namespace gets
its own copy of the Secret, from its own `files/<name>/` pair) — but for
aoe2-groups-proxy specifically, staging deliberately reuses production's
service account and Google Sheet rather than provisioning dedicated ones.
This was a one-off, judgment call for this app (low risk: read-mostly Sheet
access, no destructive writes), not the default policy — a future app
added to this split should default to separate staging credentials unless
there's a similar reason not to.

1. Reuse the same service account and Sheet as production (see
   [production secrets bootstrap](#one-time-aoe2-groups-proxy-production-secrets-bootstrap)
   above), fetching a fresh key the same way:
   ```sh
   gcloud iam service-accounts keys create service-account.json \
     --iam-account=groups-proxy@aoe2-streaming.iam.gserviceaccount.com \
     --project=aoe2-streaming
   gcloud secrets versions access latest \
     --secret=aoe2-groups-proxy-sheet-ids --project=aoe2-streaming \
     > sheet-ids.toml
   ```
2. Move both into the role's `files/staging/` and vault-encrypt them in
   place — still a separate vaulted copy from `files/production/` (each
   namespace needs its own Secret object), just with identical content:
   ```sh
   mv service-account.json sheet-ids.toml ansible/roles/aoe2_groups_proxy/files/staging/
   ansible-vault encrypt ansible/roles/aoe2_groups_proxy/files/staging/service-account.json \
     --vault-password-file ansible/.vault_pass
   ansible-vault encrypt ansible/roles/aoe2_groups_proxy/files/staging/sheet-ids.toml \
     --vault-password-file ansible/.vault_pass
   ```
3. `make ansible-apply`.

## One-time aoe2-tournament-bot secrets bootstrap

1. Export the runtime service account's key and fetch the real
   `config.toml` (Discord token, admin user IDs, GCS bucket, Sheet ID):
   ```sh
   gcloud iam service-accounts keys create service-account.json \
     --iam-account=tournament-bot@aoe2-tournaments.iam.gserviceaccount.com \
     --project=aoe2-tournaments
   gcloud secrets versions access latest \
     --secret=aoe2-tournament-bot-config --project=aoe2-tournaments \
     > config.toml
   ```
2. Move both into the role's `files/` and vault-encrypt them in place:
   ```sh
   mv service-account.json config.toml ansible/roles/aoe2_tournament_bot/files/
   ansible-vault encrypt ansible/roles/aoe2_tournament_bot/files/service-account.json \
     --vault-password-file ansible/.vault_pass
   ansible-vault encrypt ansible/roles/aoe2_tournament_bot/files/config.toml \
     --vault-password-file ansible/.vault_pass
   ```
3. `make ansible-apply`.

## One-time monitoring secrets bootstrap

The observability stack itself (Vector, VictoriaMetrics, Loki, Grafana,
Alertmanager — see [Monitoring](monitoring.md) and `k8s/monitoring/`) is
entirely Flux-managed, but its secrets are not, following the same pattern
as `aoe2-groups-proxy`/`aoe2-tournament-bot` above (`ansible/roles/
monitoring`):

1. Create a Discord webhook (Server Settings → Integrations → Webhooks) in
   whichever channel should receive alerts, and vault-encrypt its URL:
   ```sh
   ansible-vault encrypt_string 'https://discord.com/api/webhooks/...' \
     --name alertmanager_discord_webhook_url \
     --vault-password-file ansible/.vault_pass
   ```
2. Generate a Grafana admin password and vault-encrypt it:
   ```sh
   ansible-vault encrypt_string '<a generated password>' \
     --name grafana_admin_password --vault-password-file ansible/.vault_pass
   ```
3. Append both resulting blocks to `ansible/group_vars/all.yml` (alongside
   `ghcr_pull_token`/`zetatwo_password_hash`), then `make ansible-apply`.

Grafana's admin login here is a break-glass fallback only — normal access
goes through the oauth2-proxy `admin` policy (see
[Auth (Google login via oauth2-proxy) bootstrap](#one-time-auth-google-login-via-oauth2-proxy-bootstrap)
below), and Grafana itself logs the user in automatically by their
Google account email via `[auth.proxy]` in `k8s/monitoring/grafana.yaml`
(trusting the `X-Auth-Request-Email` header oauth2-proxy's ForwardAuth
Middleware sets), so there's no second, separate login screen.

## One-time Auth (Google login via oauth2-proxy) bootstrap

`k8s/auth/` runs a single `oauth2-proxy` instance as a reusable Traefik
`ForwardAuth` gate, backed by Google sign-in (any Google account: Gmail,
Workspace, or a Google account on another address). It's the cluster's one
login for every non-public app. Access is keyed on the account's verified
email and defined as named **policies** (`oauth2_proxy_policies` in
`ansible/group_vars/all.yml`). Each policy is its own Traefik Middleware,
`auth-oauth2-proxy-auth-<policy>`, and only lets through the emails it
lists. Currently `admin` (Grafana) and `collaborators` (staging apps).

Because this repo is public, the email lists are vaulted, so
`ansible/roles/oauth2_proxy` renders the policy Middlewares and the
`oauth2-proxy-emails` Secret instead of them living under `k8s/`. That
Secret is the union of all policies, i.e. who may sign in at all.

Important distinction: this middleware, by itself, only gates
*reachability* to an Ingress (can this browser get through at all). It has
no way to tell an app who authenticated unless the app reads the
`X-Auth-Request-*`/`Authorization` headers the middleware forwards, the way
Grafana's `[auth.proxy]` config does to skip its own login screen. An app
that doesn't do this still gets its own, separate in-app login (if it has
one) behind the gate.

1. In Google Cloud Console, project `kubernetes-cluster-510516`, open
   **Google Auth Platform**. The consent screen and client can't be managed
   by Terraform (Google has no API for them), so they're Console-only:
   - **Branding:** app name, support email, authorized domain `zetatwo.dev`.
   - **Audience:** user type **External** (Internal would only admit your
     own Workspace organization), publishing status **In production**.
     Testing mode caps users at a listed 100 and expires sessions after 7
     days. Only the basic `openid email profile` scopes are used, so
     production needs no Google verification.
   - **Clients → Create client:** type *Web application*, authorized
     redirect URI `https://auth.zetatwo.dev/oauth2/callback`.

   Vault-encrypt the resulting client ID and client secret:
   ```sh
   ansible-vault encrypt_string '<client id>' \
     --name oauth2_proxy_client_id --vault-password-file ansible/.vault_pass
   ansible-vault encrypt_string '<client secret>' \
     --name oauth2_proxy_client_secret --vault-password-file ansible/.vault_pass
   ```
2. Generate and vault-encrypt a cookie secret (32 random bytes):
   ```sh
   python3 -c "import secrets, base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())" \
     | ansible-vault encrypt_string --stdin-name oauth2_proxy_cookie_secret \
       --vault-password-file ansible/.vault_pass
   ```
3. Vault-encrypt each policy's email list (comma-separated):
   ```sh
   ansible-vault encrypt_string 'you@example.com' \
     --name oauth2_proxy_admin_emails --vault-password-file ansible/.vault_pass
   ansible-vault encrypt_string 'a@example.com,b@example.com' \
     --name oauth2_proxy_collaborator_emails --vault-password-file ansible/.vault_pass
   ```
4. Put all resulting blocks in `ansible/group_vars/all.yml`, then
   `make ansible-apply`.

**An app opts in** by adding one annotation to its Ingress, naming the
policy:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: auth-oauth2-proxy-errors@kubernetescrd,auth-oauth2-proxy-auth-<policy>@kubernetescrd
```

**Adding a collaborator** means re-encrypting their policy's email list and
running `make ansible-apply`. No push is needed. **A new policy** is one
more entry in `oauth2_proxy_policies` (plus its vaulted list). Removing a
policy doesn't delete its Middleware, so delete that by hand.

A signed-in user who isn't on an app's policy gets a plain 403. The errors
middleware deliberately only redirects 401s to sign-in, otherwise that 403
would loop. A Workspace account can also be refused by Google itself if its
organization's admin restricts third-party app access.
