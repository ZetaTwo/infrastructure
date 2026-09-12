# infrastructure

Deploy-and-forget hosting for hobby projects on a single Hetzner Cloud VPS.
Terraform owns the server, firewall, and DNS. Ansible installs a single-node
k3s cluster, cert-manager, and Flux CD. Flux continuously reconciles
Kubernetes manifests — one directory per app under `k8s/` in this repo —
onto the cluster, so deploying an app is a `git push`, not an Ansible run.
Traefik (bundled with k3s) handles ingress, and cert-manager issues Let's
Encrypt certificates per app via HTTP-01.

## One-time setup

These steps only need to be done once (or again from scratch on a new
machine, restoring the two secret files from your password manager).

### 1. Hetzner Cloud API token

Hetzner Cloud Console → your project → **Security → API Tokens** → generate a
token with **Read & Write** permission.

### 2. Cloudflare API token

Cloudflare dashboard → **My Profile → API Tokens → Create Token**, using the
"Edit zone DNS" template, scoped to both `zeta-two.com` and `zetatwo.dev`
zones (or create one token per zone — either works, `terraform/providers.tf`
only expects a single `cloudflare_api_token`).

Note the two zone IDs while you're there (zone overview page, right-hand
sidebar) — you'll need them for the `cloudflare_zones` map, e.g.
`zetatwo_com` (`zeta-two.com`) and `zetatwo_dev` (`zetatwo.dev`).

### 3. Hetzner Object Storage bucket (Terraform state)

Hetzner Cloud Console → **Object Storage** → create a bucket (e.g.
`zetatwo-infra-tfstate`, location `fsn1`) and generate an S3-compatible
access key + secret key for it. This step can't be done by Terraform itself
— the state bucket has to exist before Terraform has anywhere to store state.

### 4. Fill in the secrets files

Two files are gitignored and must exist locally before running Terraform.
Copy the committed `.example` templates and fill in real values:

```sh
cp terraform/secrets.auto.tfvars.example terraform/secrets.auto.tfvars
cp terraform/backend.hcl.example terraform/backend.hcl
```

- `terraform/secrets.auto.tfvars` — `hcloud_token`, `cloudflare_api_token`
  (from steps 1–2 above). Auto-loaded by Terraform.
- `terraform/backend.hcl` — Object Storage bucket name, endpoint, and the
  access/secret key from step 3. Only read at `terraform init` time.

**Never commit these two files.** Copy their contents into your password
manager as the source of truth — restoring them on a fresh checkout is just
copying from the password manager back into these two filenames.

You'll also need to set `cloudflare_zones` (from step 2) somewhere Terraform
picks up — either add it to `terraform/secrets.auto.tfvars` alongside the
tokens, or pass it with
`terraform plan -var 'cloudflare_zones={"zetatwo_com":"...","zetatwo_dev":"..."}'`.
Labels are arbitrary — they're just how DNS records (`terraform/dns.tf`) and
Ansible (`domains.<label>`) refer to a zone, not tied to any specific
purpose. Add a new zone, or point a new purpose at an existing one, by
adding or reusing a label in this map — no other Terraform changes needed.

## Day-to-day workflow

```sh
make tf-init      # first time only, or after changing backend.hcl
make tf-plan       # review infrastructure changes
make tf-apply      # create/update the server, firewall, DNS records
                    # (also regenerates ansible/inventory/hosts.yaml)
make ansible-apply  # install/configure k3s, cert-manager, and Flux CD
```

If the server ever needs to be rebuilt from nothing: `make tf-apply` then
`make ansible-apply` fully restores it. Apps themselves are **not**
deployed by `make ansible-apply` — see "GitOps (Flux CD)" below.

`ansible/roles/k3s` installs k3s (pinned via `k3s_version` in
`ansible/group_vars/all.yml`) and cert-manager (pinned via
`cert_manager_version`), and deploys a `ClusterIssuer` for Let's Encrypt.
`ansible/roles/flux` installs Flux CD (pinned via `flux_version`) the same
way. Bumping any of these versions in `group_vars/all.yml` and re-running
`make ansible-apply` performs a controlled upgrade; re-running with no
version change is a no-op.

## Accessing the cluster

There is no public route to the Kubernetes API (port 6443 is not opened in
`terraform/firewall.tf`). Run `kubectl` on a node over SSH, using its DNS
name (`terraform/dns.tf`'s `cluster_node` records — `node1.zetatwo.dev`,
`node2.zetatwo.dev`, ... one per `var.node_count`, see Domains below) rather
than its raw IP:

```sh
ssh root@node1.zetatwo.dev k3s kubectl get nodes
```

or tunnel the API port and use a local `kubectl` with the node's kubeconfig
(`/etc/rancher/k3s/k3s.yaml`, fetched over SSH):

```sh
ssh -L 6443:localhost:6443 root@node1.zetatwo.dev
```

Flux's own status is worth checking too:

```sh
k3s kubectl get pods -n flux-system
k3s kubectl get gitrepository,kustomization -n flux-system
```

## GitOps (Flux CD)

Flux CD runs in the cluster (`ansible/roles/flux`) with a `GitRepository`
pointing at this repo's `main` branch (read-only, via a GitHub Deploy Key —
see bootstrap below) and a `Kustomization` reconciling everything under
`k8s/`. There is no `flux bootstrap` step and no write access to this repo
from inside the cluster — Flux only ever reads.

`k8s/` has one subdirectory per app, each with its own `kustomization.yaml`,
aggregated by the root `k8s/kustomization.yaml`. **Adding a new app is: add
a subdirectory + one line in the root file + `git push`** — no Ansible or
Terraform changes needed for the deployment itself:

1. Add a Cloudflare A record for the new hostname in `terraform/dns.tf`
   (on `var.cloudflare_zones["zetatwo_com"]` for a public app — or any other
   label in `cloudflare_zones` if it belongs elsewhere), then `make tf-apply`.
2. Create `k8s/<name>/{deployment,service,ingress}.yaml` and a
   `k8s/<name>/kustomization.yaml` listing them, with a top-level
   `namespace: default` in that file — follow `k8s/aoe2-groups-overlay/`
   as the reference. The explicit namespace matters: unlike plain
   `kubectl apply`, Flux's kustomize-controller does **not** default
   un-namespaced resources to `default` and fails with a confusing
   `namespace not specified: the server could not find the requested
   resource` error instead. Ingress should be annotated
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
copies them to the node, and builds the `Secret` with
`kubectl create secret generic ... --from-file=... --dry-run=client -o yaml
| kubectl apply -f -` for idempotent apply. Follow
`ansible/roles/aoe2-groups-proxy` as the reference (named after the app,
not "secrets," since it's that app's whole Ansible footprint and may end up
doing more than secrets later). The app's Deployment (in `k8s/`) references
that Secret by name only; Flux never sees or manages it. This deliberately
avoids adding a second secrets-encryption system (e.g. SOPS) alongside
`ansible-vault`.

Private images: a single shared `ghcr-pull-secret` (`ansible/roles/
ghcr-pull-secret`, `default` namespace) exists for pulling private
`ghcr.io` images — reference it from any app's Deployment with
`imagePullSecrets: [{name: ghcr-pull-secret}]` (see
`k8s/aoe2-groups-overlay/deployment.yaml`). One shared secret covers every
app; no per-app pull secret needed. Note that GitHub package visibility is
one-way — once a package is made public it can't be made private again —
so `aoe2-groups-proxy` stays private and pulls via this secret rather than
being flipped public.

Image updates: CI (in the app's own repo) builds and pushes an image, then
commits an update to the image tag in `k8s/<name>/deployment.yaml` and
pushes to `main` — see `aoe2-streaming`'s `.github/workflows/
backend-deploy.yml` for the reference implementation. Flux is **not**
running its image-automation-controllers (would add 2 more controllers and
require its deploy key to be read-write instead of read-only) — the CI job
in the app's own repo owns the tag bump instead.

One naming gotcha: plain Kustomize's config file (`kustomization.yaml`,
`apiVersion: kustomize.config.k8s.io/v1beta1`, never applied to the
cluster, just consumed by `kubectl kustomize`/`kustomize build`) and Flux's
own custom resource (`kind: Kustomization`,
`apiVersion: kustomize.toolkit.fluxcd.io/v1`, a live object in-cluster) are
unrelated things that happen to share a name.

### One-time Flux bootstrap

1. Generate an ed25519 deploy-key pair directly into the role's `files/`:
   ```sh
   ssh-keygen -t ed25519 -f ansible/roles/flux/files/flux-infrastructure-deploy-key \
     -C "flux@infrastructure" -N ""
   ```
2. Register the **public** half
   (`ansible/roles/flux/files/flux-infrastructure-deploy-key.pub`) as a
   read-only GitHub Deploy Key on this repo (Settings → Deploy keys → Add
   deploy key) — leave "Allow write access" unchecked. The `.pub` file is
   fine to commit as plain text (not a secret), same as
   `terraform/files/zetatwo.pub`.
3. Vault-encrypt the private half in place:
   ```sh
   ansible-vault encrypt ansible/roles/flux/files/flux-infrastructure-deploy-key \
     --vault-password-file ansible/.vault_pass
   ```
4. `make ansible-apply`.

GitHub's SSH host keys (the third piece of Flux's git auth secret) don't
need a bootstrap step: `ansible/roles/flux` fetches them live from
`https://api.github.com/meta` at apply time, the same way
`ansible/roles/users` already fetches `zetatwo`'s SSH key from
`https://github.com/zetatwo.keys`.

### One-time GHCR pull secret bootstrap

1. Create a **classic** GitHub Personal Access Token with just the
   `read:packages` scope, belonging to an account with access to the
   private packages (the one that pushes them from CI is sufficient).
   GHCR's own docs state it only supports classic PATs for pulling
   container images — fine-grained tokens aren't a documented/guaranteed
   option here, despite being generally preferred elsewhere.
2. Vault-encrypt it into `ghcr_pull_token`:
   ```sh
   ansible-vault encrypt_string '<the token>' \
     --name ghcr_pull_token --vault-password-file ansible/.vault_pass
   ```
   Append the resulting block to `group_vars/all.yml`.
3. Confirm `ghcr_pull_username` in `group_vars/all.yml` matches the account
   that owns the token.
4. `make ansible-apply`.

### One-time aoe2-groups-proxy secrets bootstrap

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
2. Move both into the role's `files/` and vault-encrypt them in place:
   ```sh
   mv service-account.json sheet-ids.toml ansible/roles/aoe2-groups-proxy/files/
   ansible-vault encrypt ansible/roles/aoe2-groups-proxy/files/service-account.json \
     --vault-password-file ansible/.vault_pass
   ansible-vault encrypt ansible/roles/aoe2-groups-proxy/files/sheet-ids.toml \
     --vault-password-file ansible/.vault_pass
   ```
3. `make ansible-apply`.

## TODOs / deferred

A few things were deliberately dropped or deferred in the move from
Podman+Caddy to k3s, rather than carried over 1:1:

- **Admin/management tooling.** Cockpit was removed: it only binds to
  `127.0.0.1:9090`, and Traefik (running in the pod network) can't reach a
  host-loopback-only service without extra plumbing. Revisit this —
  options include a proper Kubernetes dashboard, or keeping something
  SSH-tunneled rather than exposed as a public admin surface.
- **Logging/alerting.** The Vector → ntfy.sh pipeline (journald →
  JSON-`ERROR` filter → rate-limited push) was removed rather than adapted:
  k3s pods log to `/var/log/pods/...` via containerd, not journald, so the
  old pipeline wouldn't see app-level errors without rework. Revisit with a
  k8s-native log shipper (e.g. a DaemonSet) or a hosted alternative.
- **App deployment / image updates**: done via Flux CD — see "GitOps (Flux
  CD)" above. Remaining gaps: the CI-commits-back tag bump has no PR gate
  (a rare race on the commit is possible, mitigated with a rebase-retry);
  and Flux's image-automation-controllers were deliberately skipped in
  favor of that CI-side commit, worth revisiting if the cross-repo write
  PAT (`INFRA_REPO_PAT` in each app's CI) becomes a bigger rotation burden
  than running 2 more controllers would be.
- **Multi-node clustering.** `var.node_count` (`terraform/variables.tf`)
  scaffolds multiple node servers and DNS records (`node1`, `node2`, ...),
  but nodes don't join each other as a k3s cluster yet — bumping it above 1
  today just creates independent single-node servers. Needs k3s
  server/agent join logic (a shared cluster token, one initial server node)
  before it's actually usable.

## Admin login (zetatwo)

The `users` role creates a single non-root admin account, `zetatwo`, in the
`sudo` group. Its SSH key is pulled at apply time from
`https://github.com/zetatwo.keys`. Its login password is a pre-hashed
(crypt/shadow-style) vaulted variable:

```sh
mkpasswd --method=yescrypt
ansible-vault encrypt_string '<the hash>' --name zetatwo_password_hash \
  --vault-password-file ansible/.vault_pass
```

Append the resulting block to `ansible/group_vars/all.yml`.

Ansible itself still connects and manages the box as `root` over SSH
(`ansible_user: root` in the generated inventory) — `zetatwo` is for
interactive SSH login, not for Ansible's own access.

`ansible/roles/sshd` disables SSH password authentication entirely
(`PasswordAuthentication no`) — only key-based login works (root's
Hetzner-provisioned key, and `zetatwo`'s key from
`https://github.com/zetatwo.keys`). `zetatwo_password_hash` is only ever
used for local `sudo`, never for remote login.

## Domains

Cloudflare zones are declared as a label → zone ID map,
`var.cloudflare_zones` (`terraform/secrets.auto.tfvars`), and aren't tied to
any specific purpose — any DNS record or app can use any label. Currently:

- `zetatwo_com` → `zeta-two.com` — hobby apps, e.g. `aoe2-groups.zeta-two.com`.
- `zetatwo_dev` → `zetatwo.dev` — hosts each node's own DNS name
  (`node1.zetatwo.dev`, `node2.zetatwo.dev`, ... one per `var.node_count`,
  used as the SSH/Ansible target instead of a raw IP, see `terraform/dns.tf`
  and `terraform/inventory.tf`). Otherwise reserved for future
  admin/management surfaces (see the TODOs above), but nothing stops it
  being used for something else too — e.g. dev instances at
  `dev.zetatwo.dev` would just be another record on the `zetatwo_dev`
  label.

The zone IDs are the single source of truth: Terraform looks up each zone's
domain name via a `for_each`'d `cloudflare_zone` data source
(`terraform/data.tf`) and writes the whole label → domain map into the
generated `ansible/inventory/hosts.yaml` as `domains`, so Ansible never
hardcodes domain names itself, and a new zone only needs to be added in one
place (tfvars) to become available everywhere.
