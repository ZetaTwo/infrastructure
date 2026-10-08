# App setup

Deploying and managing apps on an already-set-up cluster: what an app must
provide, the end-to-end checklist, GitOps, the staging/production pattern,
the shared Postgres, per-app secrets bootstrap, and the shared auth gate.
For provisioning the cluster itself, see [Cluster setup](cluster-setup.md).
If the app is stateful, see [Backups](backups.md) too.

This repo is the single source of truth for how apps are deployed. App
repos contain the app, its Dockerfile(s) and a CI workflow that builds
images, and nothing about the cluster.

## What an app must provide

The cluster assumes these of every app. `ZetaTwo/canst` is a complete
reference for a web app with a database (`backend/Dockerfile`,
`frontend/Dockerfile`, `.github/workflows/deploy.yml`).

- **Container images on `ghcr.io/zetatwo/<image>`**, pushed by the app's CI
  on every push to `main` as both `:<sha>` and `:main-<unix epoch>-<sha>`.
  The epoch is the commit time (`git log -1 --format=%ct`), so the deploy
  workflow can always pick the newest. Production uses `vX[.Y[.Z]]` tags
  created by retagging an already-tested `:<sha>` image, never by
  rebuilding (see [Staging and production](#staging-and-production)).
- **Plain HTTP on one container port.** Traefik terminates TLS. A web app
  whose frontend and API are separate images still gets one hostname: the
  Ingress routes by path (canst sends `/api` to the backend and everything
  else to a Caddy container serving the built SPA), so the browser sees a
  single origin and cookie auth needs no CORS.
- **A health endpoint** for liveness/readiness probes (canst:
  `GET /api/healthz`, which round-trips the database). Headless apps
  without HTTP skip probes.
- **Structured logs on stdout**: one JSON object per line with a `level`
  field (`ERROR` posts to Discord, see [Monitoring](monitoring.md)) and a
  `message` field. For Rust `tracing`:
  `tracing_subscriber::fmt().json().flatten_event(true)`. Non-JSON lines
  still reach Loki, but never alert.
- **Pod label `app: <name>`** on every workload, including CronJob pod
  templates. Vector uses it as the Loki `app` label and to name the app in
  Discord alerts.
- **Config and secrets from outside the image**: a config file mounted from
  a Secret (canst's `config.toml`) or environment variables. Ansible renders
  the Secret from vaulted values (see
  [secrets](#gitops-flux-cd) below); nothing secret is ever baked into an
  image or committed unencrypted.
- **Schema migrations as a separate command** that exits when done (canst:
  `canst-backend --config <path> migrate`), run as an initContainer of the
  app's Deployment. If it fails, the new pod never becomes Ready and the old
  one keeps serving. Migrations must stay compatible with the previous app
  version for the few seconds both run.
- **Awareness of the auth gate in staging.** Staging is reachable only
  through Google login (oauth2-proxy). The app's own login, if it has one,
  works unchanged behind it, provided its API paths are routed past the
  gate's errors middleware (see
  [Gated apps with an API](#gated-apps-with-an-api)).

## New app checklist

The full order for a new web app with a database, linking the details
below. Skip what doesn't apply (headless apps need no DNS or Ingress;
stateless apps no database or backups). The order matters: each step
depends on the ones before it.

1. **App repo**: Dockerfile(s) and a CI workflow that tests, pushes the
   images (see [What an app must provide](#what-an-app-must-provide)), then
   triggers this repo's deploy (see [GitOps](#gitops-flux-cd)). Add the two
   `DEPLOY_APP_*` secrets. Push once so the ghcr packages exist, then give
   `ZetaTwo/infrastructure` Read access to each package.
2. **DNS**: an A record in `terraform/dns.tf`, then `make tf-apply`. Do this
   before the Ingress exists, so cert-manager's first HTTP-01 challenge
   resolves.
3. **Secrets, database, backups** in `ansible/group_vars/all.yml` and an
   app role (`ansible/roles/<app>`, added to `site.yaml`): vaulted secrets,
   a `postgres_databases` entry ([Shared Postgres](#shared-postgres)), a
   `backup_targets` entry ([Backups](backups.md)), and the namespace in
   `ghcr_pull_secret_namespaces`. Then `make ansible-apply`. This creates
   the namespace and every Secret the manifests will reference.
4. **Manifests**: `k8s/<app>/` (flat, or `base/` + `overlays/`), a backup
   CronJob if stateful, and the app added to the root
   `k8s/kustomization.yaml`.
5. **Deploy targets**: a `[[target]]` per image per environment in
   `deploy-targets.toml`.
6. Push 4 and 5 together, then let the app's CI trigger the deploy workflow
   (or run it by hand). Until it commits real tags, the overlay's
   placeholder tags leave the pods in `ImagePullBackOff`; that's expected.
7. [Check the rollout](#checking-a-rollout), then run one backup by hand
   and a restore drill ([Backups](backups.md#restore)).

## GitOps (Flux CD)

Flux CD runs in the cluster (`ansible/roles/flux`) with a `GitRepository`
pointing at this repo's `main` branch (read-only, via a GitHub Deploy Key —
see [Cluster setup](cluster-setup.md#one-time-flux-bootstrap)) and a
`Kustomization` reconciling everything under `k8s/`. There is no `flux
bootstrap` step and no write access to this repo from inside the cluster —
Flux only ever reads.

`k8s/` has one subdirectory per app, each with its own `kustomization.yaml`,
aggregated by the root `k8s/kustomization.yaml`. The manifests part of
adding an app is a subdirectory, one line in the root file and a
`git push` (DNS, secrets and the database are separate steps, see the
[New app checklist](#new-app-checklist)):

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

Releasing means pushing a `vX.Y.Z` tag. The app's `.github/workflows/release.yml`
doesn't rebuild the image — it verifies the tagged commit already has a
`:<sha>` image from `main`'s CI and promotes that exact artifact with
`docker buildx imagetools create --tag <image>:<release-tag>
<image>:<sha>`, so what ships to production is bit-identical to what was
tested in staging. See `aoe2-streaming`'s `.github/workflows/release.yml`
for the reference. If the tagged commit was never built on `main`, this
step fails loudly rather than promoting an untested artifact.

A web app with several images (canst: backend + frontend) lists each in
the overlay's `images:`, one `- name:`/`newTag:` pair per image, with one
deploy target per image. Its Ingress routes by path on the one host (see
`k8s/canst/overlays/staging/ingress.yaml`).

Not every app needs this split — `aoe2-tournament-bot` (a Discord bot)
deliberately has no staging tier, since Discord allows only one gateway
connection per bot token and a second running instance would conflict with
production. It still moved from "deploy on every push" to "deploy only on
release, promoting the tested image" (see `.github/workflows/release.yml`) — it just has one environment instead of two.

One naming gotcha: plain Kustomize's config file (`kustomization.yaml`,
`apiVersion: kustomize.config.k8s.io/v1beta1`, never applied to the
cluster, just consumed by `kubectl kustomize`/`kustomize build`) and Flux's
own custom resource (`kind: Kustomization`,
`apiVersion: kustomize.toolkit.fluxcd.io/v1`, a live object in-cluster) are
unrelated things that happen to share a name.

## Checking a rollout

Run these on the node (`ssh root@node1.zetatwo.dev`, see
[Cluster setup](cluster-setup.md#accessing-the-cluster)):

```sh
# Has Flux applied the latest commit? (lastAppliedRevision = main's sha)
k3s kubectl get kustomization apps -n flux-system
# Pods, Ingress and certificate for the app
k3s kubectl get pods,ingress,certificate -n <namespace>
# Why a pod isn't starting (missing Secret, image pull, failing probe)
k3s kubectl describe pod -n <namespace> <pod>
k3s kubectl get events -n <namespace> --sort-by=.lastTimestamp
# Migration initContainer output
k3s kubectl logs -n <namespace> deploy/<deployment> -c migrate
```

From outside, a staging URL should answer anonymous requests with a 302
to `accounts.google.com` (the auth gate), and the certificate should come
from Let's Encrypt. Common first-rollout states:

- `CreateContainerConfigError`: a referenced Secret doesn't exist yet. Run
  `make ansible-apply`.
- `ImagePullBackOff` on a `placeholder-...` tag: the deploy workflow hasn't
  committed real tags yet. On a real tag: the namespace is missing from
  `ghcr_pull_secret_namespaces`.
- Certificate stuck not Ready: the DNS record is missing or proxied
  through Cloudflare (it must be un-proxied for HTTP-01).

## Removing an app

Flux runs with `prune: true` (`ansible/roles/flux`), so deleting an app's
directory under `k8s/` (or its line in the root kustomization) deletes
everything Flux created for it, **including its Namespace, and with it
every Secret Ansible put there**. That's what you want when removing an
app, and a hazard otherwise: never delete or rename a `namespace.yaml` by
accident. The one exception is `k8s/postgres/`: its namespace holds the
database volume for every app, so it carries
`kustomize.toolkit.fluxcd.io/prune: disabled` and Flux never deletes it,
even if the directory is removed. Deleting it is a deliberate manual
`kubectl delete namespace postgres`. Give any future namespace holding
shared, hard-to-recreate data the same annotation.

To remove an app completely:

1. Delete `k8s/<app>/` and its line in `k8s/kustomization.yaml`, and its
   targets in `deploy-targets.toml`. Push.
2. Remove its Ansible role (and `site.yaml` entry), its entries in
   `ghcr_pull_secret_namespaces`, `backup_targets` and
   `postgres_databases`, and its vaulted variables.
3. `ansible/roles/postgres` never drops anything, so drop the database and
   all three roles by hand:
   `k3s kubectl exec -n postgres postgres-0 -- psql -U postgres -c 'DROP DATABASE <db>' -c 'DROP ROLE <db>_migrate' -c 'DROP ROLE <db>_app' -c 'DROP ROLE <db>_backup'`.
4. Remove its DNS record from `terraform/dns.tf` and `make tf-apply`.
5. Its restic repository in the backups bucket is left alone. Delete it in
   the Hetzner console once the backups are no longer wanted.

## Shared Postgres

`k8s/postgres/` runs one Postgres 16 StatefulSet for every app, at
`postgres.postgres.svc.cluster.local:5432`, on a `local-path` PVC (so
[Backups](backups.md) are the only recovery mechanism). It's one instance
rather than one per app to keep memory and upgrade overhead flat as apps
are added. Each app (and each environment of an app) gets its own database
and *three* roles, not one: `<db>_migrate` owns the database (full DDL,
used only by a migration step), `<db>_app` gets DML-only grants (SELECT/
INSERT/UPDATE/DELETE, plus default privileges so objects `<db>_migrate`
creates later are automatically covered) for the running app itself, and
`<db>_backup` gets read-only grants the same way, for `pg_dump`. `CONNECT`
is revoked from `PUBLIC` so apps can't reach each other's databases, then
re-granted explicitly to `_app`/`_backup` (the owner role doesn't need it
granted back). The running app never holds DDL rights, and backups never
hold write access.

The StatefulSet is Flux-managed. Everything secret is Ansible's
(`ansible/roles/postgres`): the `postgres-superuser` Secret, and an
idempotent `psql` run inside `postgres-0` per `postgres_databases` entry
that creates the database and all three roles if missing and resets every
password every run, so the vaulted values stay the source of truth.

**An app gets a database** by:

1. Generating and vault-encrypting three passwords — `<db>_migrate_db_password`,
   `<db>_app_db_password`, `<db>_backup_db_password` (same command as the
   restic password in [Backups](backups.md)) — and appending them to
   `ansible/group_vars/all.yml`.
2. Adding an entry to `postgres_databases`:
   ```yaml
   postgres_databases:
     - name: <db>
       migrate_password: "{{ <db>_migrate_db_password }}"
       app_password: "{{ <db>_app_db_password }}"
       backup_password: "{{ <db>_backup_db_password }}"
   ```
3. Giving the app its connection strings from its own Ansible role, e.g.
   rendered config file Secrets (see `ansible/roles/canst` — one Secret for
   the app's own `<db>_app` role, a separate one for whatever runs
   migrations with `<db>_migrate`, so the DDL-owner credential never lands
   on the running app's filesystem), never in git.
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

### Gated apps with an API

The errors middleware rewrites **every** 401 that passes through it into
the sign-in redirect, not only the gate's own: Traefik's errors middleware
is built for replacing an app's error pages. On a page path that's what
you want. On an API path it hides the app's own 401s (e.g. "not logged in
to the app", or an expired app token the client should refresh): the
browser's `fetch` follows the redirect to `accounts.google.com`, and CORS
blocks it.

So an app that serves an API under the gate gets two Ingresses on the same
host. Page paths get both middlewares as above. The API path gets the auth
middleware only:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: auth-oauth2-proxy-auth-<policy>@kubernetescrd
```

Give only one of the two the `cert-manager.io/cluster-issuer` annotation,
and have both reference the same TLS secret. Traefik's longer-rule-wins
priority routes `/api` to the API Ingress. `k8s/canst/overlays/staging/
ingress.yaml` is the reference. An expired gate session then makes API
calls return the gate's plain 401 rather than a redirect; reloading the
page goes through the sign-in as usual.

**Adding a collaborator** means re-encrypting their policy's email list and
running `make ansible-apply`. No push is needed. **A new policy** is one
more entry in `oauth2_proxy_policies` (plus its vaulted list). Removing a
policy doesn't delete its Middleware, so delete that by hand.

A signed-in user who isn't on an app's policy gets a plain 403. The errors
middleware deliberately only redirects 401s to sign-in, otherwise that 403
would loop. A Workspace account can also be refused by Google itself if its
organization's admin restricts third-party app access.
