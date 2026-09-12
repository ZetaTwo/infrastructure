# infrastructure

Deploy-and-forget hosting for hobby projects on a single Hetzner Cloud VPS.
Terraform owns the server, firewall, and DNS. Ansible installs a single-node
k3s cluster and drops one Kubernetes manifest (Deployment + Service +
Ingress) per app. Traefik (bundled with k3s) handles ingress, and
cert-manager issues Let's Encrypt certificates per app via HTTP-01.

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
make ansible-apply  # install/configure k3s, cert-manager, and apps
```

If the server ever needs to be rebuilt from nothing: `make tf-apply` then
`make ansible-apply` fully restores it.

`ansible/roles/k3s` installs k3s (pinned via `k3s_version` in
`ansible/group_vars/all.yml`) and cert-manager (pinned via
`cert_manager_version`), and deploys a `ClusterIssuer` for Let's Encrypt.
Bumping either version in `group_vars/all.yml` and re-running
`make ansible-apply` performs a controlled upgrade; re-running with no
version change is a no-op.

## Accessing the cluster

There is no public route to the Kubernetes API (port 6443 is not opened in
`terraform/firewall.tf`). Run `kubectl` on the box itself over SSH, using its
DNS name (`terraform/dns.tf`'s `cluster_node` record — see Domains below)
rather than its raw IP:

```sh
ssh root@cluster-node.zetatwo.dev k3s kubectl get nodes
```

or tunnel the API port and use a local `kubectl` with the node's kubeconfig
(`/etc/rancher/k3s/k3s.yaml`, fetched over SSH):

```sh
ssh -L 6443:localhost:6443 root@cluster-node.zetatwo.dev
```

## Adding a new app

Follow the pattern in `ansible/roles/apps-demo/`:

1. Add a Cloudflare A record for the new hostname in `terraform/dns.tf`
   (on `var.cloudflare_zones["zetatwo_com"]` for a public app — or any other
   label in `cloudflare_zones` if it belongs elsewhere), then `make tf-apply`.
2. Copy `ansible/roles/apps-demo/` to `ansible/roles/apps-<name>/`, updating
   the image reference and hostname in `templates/<name>.yaml.j2`
   (Deployment + Service + Ingress).
3. Add `apps-<name>` to the role list in `ansible/site.yaml`.
4. `make ansible-apply`.

Each app's Ingress is annotated `cert-manager.io/cluster-issuer:
letsencrypt-prod`, so cert-manager issues and renews its certificate
automatically via HTTP-01 through Traefik.

There's no automated image-update mechanism yet (the old Podman setup had
`podman-auto-update`; nothing replaces it here). See the TODOs below. A
private GHCR image will also need an `imagePullSecret` configured — not set
up yet, add if/when a real app needs it.

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
- **App deployment / image updates.** Apps are applied with a plain
  `k3s kubectl apply` run from Ansible, with no automated rollout on new
  image tags. Worth evaluating once there's more than one real app: either
  a lightweight updater (a `CronJob` doing `kubectl rollout restart`, or a
  tool like Keel), or moving to a GitOps model (Flux/Argo CD reconciling
  manifests from this repo) instead of Ansible-driven `kubectl apply`.

## Admin login (zetatwo)

The `users` role creates a single non-root admin account, `zetatwo`, in the
`sudo` group. Its SSH key is pulled at apply time from
`https://github.com/zetatwo.keys`. Its login password is a pre-hashed
(crypt/shadow-style) vaulted variable:

```sh
mkpasswd --method=yescrypt
ansible-vault encrypt_string '<the hash>' --name zetatwo_password_hash
```

Append the resulting block to `ansible/group_vars/all.yml`.

Ansible itself still connects and manages the box as `root` over SSH
(`ansible_user: root` in the generated inventory) — `zetatwo` is for
interactive SSH login, not for Ansible's own access.

## Domains

Cloudflare zones are declared as a label → zone ID map,
`var.cloudflare_zones` (`terraform/secrets.auto.tfvars`), and aren't tied to
any specific purpose — any DNS record or app can use any label. Currently:

- `zetatwo_com` → `zeta-two.com` — hobby apps, e.g. `demo.zeta-two.com`.
- `zetatwo_dev` → `zetatwo.dev` — hosts `cluster-node.zetatwo.dev`, the
  node's own DNS name (used as the SSH/Ansible target instead of its raw
  IP, see `terraform/dns.tf` and `terraform/inventory.tf`). Otherwise
  reserved for future admin/management surfaces (see the TODOs above), but
  nothing stops it being used for something else too — e.g. dev instances
  at `dev.zetatwo.dev` would just be another record on the `zetatwo_dev`
  label.

The zone IDs are the single source of truth: Terraform looks up each zone's
domain name via a `for_each`'d `cloudflare_zone` data source
(`terraform/data.tf`) and writes the whole label → domain map into the
generated `ansible/inventory/hosts.yaml` as `domains`, so Ansible never
hardcodes domain names itself, and a new zone only needs to be added in one
place (tfvars) to become available everywhere.
