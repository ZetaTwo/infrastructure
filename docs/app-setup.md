# App setup

Deploying and managing apps on an already-set-up cluster: GitOps, the
staging/production pattern, per-app secrets bootstrap, and the shared auth
gate. For provisioning the cluster itself, see
[Cluster setup](cluster-setup.md).

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

Image updates: CI (in the app's own repo) builds and pushes an image, then
commits an update to the image tag and pushes to `main`. Flux is **not**
running its image-automation-controllers (would add 2 more controllers and
require its deploy key to be read-write instead of read-only) — the CI job
in the app's own repo owns the tag bump instead. There are two patterns in
use, depending on whether the app has a staging tier (see
[Staging and production](#staging-and-production) below for why some apps
don't):

- **Single-environment apps** (e.g. `k8s/aoe2-tournament-bot/`): CI commits
  a tag bump straight to `deployment.yaml`'s `image:` line on every push to
  `main` — see `aoe2-tournament-bot`'s `.github/workflows/ci.yml` for the
  reference implementation.
- **Staging/production apps** (e.g. `k8s/aoe2-groups-proxy/`): CI bumps the
  relevant overlay's kustomize `images: newTag:` line instead of a
  `deployment.yaml` image string directly — see
  [Staging and production](#staging-and-production) below.

## Staging and production

Apps that need it get a kustomize `base` + `overlays/{staging,production}`
split (`k8s/aoe2-groups-proxy/` is the reference) instead of a flat
`k8s/<name>/` directory:

- `base/` holds the Deployment/Service common to both environments, with an
  inert placeholder image tag — every overlay's own `images:` transformer
  always overrides it by repository name, so the literal placeholder is
  never actually deployed.
- `overlays/staging/` adds its own `namespace.yaml` (`<name>-staging`),
  `ingress.yaml` (host `<name>.zetatwo.dev`, gated behind the shared GitHub
  OAuth forward-auth — see
  [Auth (GitHub OAuth via oauth2-proxy) bootstrap](#one-time-auth-github-oauth-via-oauth2-proxy-bootstrap)
  below), any environment-specific config as a strategic-merge patch (e.g.
  `allowed-origins-patch.yaml`), and an `images: newTag:` CI updates on
  every push to `main`.
- `overlays/production/` mirrors it with the app's real namespace, host
  `<name>.zeta-two.com` (public, no auth middleware), and an `images:
  newTag:` CI updates **only** when a GitHub Release is published.
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
goes through the shared GitHub OAuth gate (see
[Auth (GitHub OAuth via oauth2-proxy) bootstrap](#one-time-auth-github-oauth-via-oauth2-proxy-bootstrap)
below), and Grafana itself logs the user in automatically with their
GitHub identity via `[auth.proxy]` in `k8s/monitoring/grafana.yaml`
(trusting the `X-Auth-Request-User`/`-Email` headers oauth2-proxy's
ForwardAuth Middleware sets), so there's no second, separate login screen.

## One-time Auth (GitHub OAuth via oauth2-proxy) bootstrap

`k8s/auth/` runs a single `oauth2-proxy` instance as a reusable Traefik
`ForwardAuth` gate (`ansible/roles/oauth2_proxy` applies its secrets), backed
by GitHub OAuth and restricted to an allowlist of GitHub usernames. It's the
cluster's one login for every non-public app — see Grafana's
`k8s/monitoring/grafana-ingress.yaml` for the reference usage. Important
distinction: this middleware, by itself, only gates *reachability* to an
Ingress (can this browser get through at all) — it has no way to tell an
app who authenticated unless the app is explicitly configured to read the
`X-Auth-Request-*`/`Authorization` headers the middleware forwards, the way
Grafana's `[auth.proxy]` config does (see the monitoring secrets bootstrap
above) to skip its own separate login screen. An app that doesn't do this
still gets its own, separate in-app login (if it has one) behind the gate.

1. Create a GitHub OAuth App (**not** a GitHub App): GitHub → Settings →
   Developer settings → OAuth Apps → New OAuth App.
   - Homepage URL: `https://auth.zetatwo.dev`
   - Authorization callback URL: `https://auth.zetatwo.dev/oauth2/callback`

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
3. Append all three resulting blocks to `ansible/group_vars/all.yml`, then
   `make ansible-apply`.
4. Edit `k8s/auth/deployment.yaml`'s `--github-user=...` flag to the
   allowlisted GitHub username(s) (comma-separated for more than one) — this
   is plain committed text, not a secret, since nothing under `k8s/` is
   templated by Ansible. `git push`.

**A future app opts in** by adding one annotation to its Ingress — no new
Deployment, Secret, or per-app oauth2-proxy config:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: auth-oauth2-proxy-errors@kubernetescrd,auth-oauth2-proxy-auth@kubernetescrd
```

Restricting different apps to different GitHub users/orgs isn't supported
yet — one oauth2-proxy instance has one global allowlist; deferred until
actually needed (see [TODOs](todo.md)).
