# Cluster setup

Provisioning the VPS and the base cluster (Terraform + Ansible), accessing
it afterward, and the admin login. For deploying apps onto an already-set-up
cluster, see [App setup](app-setup.md).

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
deployed by `make ansible-apply` — see [App setup](app-setup.md#gitops-flux-cd).

`ansible/roles/k3s` installs k3s (pinned via `k3s_version` in
`ansible/group_vars/all.yml`) and cert-manager (pinned via
`cert_manager_version`), and deploys a `ClusterIssuer` for Let's Encrypt.
`ansible/roles/flux` installs Flux CD (pinned via `flux_version`) the same
way. Bumping any of these versions in `group_vars/all.yml` and re-running
`make ansible-apply` performs a controlled upgrade; re-running with no
version change is a no-op.

Flux's release bundles 7 controllers; only 4 are installed
(`source-controller`, `kustomize-controller`, `helm-controller`,
`notification-controller`) — the other 3 (`image-reflector-controller`,
`image-automation-controller`, `source-watcher`) are explicitly pruned,
since nothing here uses Flux-managed image automation or
`ArtifactGenerator`s (see [App setup](app-setup.md#gitops-flux-cd) for why).

## Accessing the cluster

There is no public route to the Kubernetes API (port 6443 is not opened in
`terraform/firewall.tf`). Run `kubectl` on a node over SSH, using its DNS
name (`terraform/dns.tf`'s `cluster_node` records — `node1.zetatwo.dev`,
`node2.zetatwo.dev`, ... one per `var.node_count`, see [Domains](#domains)
below) rather than its raw IP:

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

- `zetatwo_com` → `zeta-two.com` — production hobby apps, e.g.
  `aoe2-groups.zeta-two.com`.
- `zetatwo_dev` → `zetatwo.dev` — hosts each node's own DNS name
  (`node1.zetatwo.dev`, `node2.zetatwo.dev`, ... one per `var.node_count`,
  used as the SSH/Ansible target instead of a raw IP, see `terraform/dns.tf`
  and `terraform/inventory.tf`), admin/management surfaces
  (`grafana.zetatwo.dev` and `auth.zetatwo.dev`, the shared GitHub OAuth
  gate — see [App setup](app-setup.md#one-time-auth-github-oauth-via-oauth2-proxy-bootstrap)),
  and staging deploys of apps that have one (e.g. `aoe2-groups.zetatwo.dev`
  — see [App setup](app-setup.md#staging-and-production)), also gated
  behind that same OAuth gate.

The convention going forward: `<app>.zetatwo.dev` = staging (auth-gated),
`<app>.zeta-two.com` = production (public). Nothing stops the zone being
used for something else too.

The zone IDs are the single source of truth: Terraform looks up each zone's
domain name via a `for_each`'d `cloudflare_zone` data source
(`terraform/data.tf`) and writes the whole label → domain map into the
generated `ansible/inventory/hosts.yaml` as `domains`, so Ansible never
hardcodes domain names itself, and a new zone only needs to be added in one
place (tfvars) to become available everywhere.
