# infrastructure

Deploy-and-forget hosting for hobby projects on a single Hetzner Cloud VPS.
Terraform owns the server, firewall, and DNS. Ansible configures the OS and
drops one Podman quadlet + Caddy site per app. See [idea1.md](idea1.md) for
the original design rationale.

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
sidebar) — you'll need them for `apps_zone_id` (`zeta-two.com`) and
`admin_zone_id` (`zetatwo.dev`).

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

You'll also need to set `apps_zone_id` and `admin_zone_id` (from step 2)
somewhere Terraform picks up — either add them to
`terraform/secrets.auto.tfvars` alongside the tokens, or pass them with
`terraform plan -var apps_zone_id=... -var admin_zone_id=...`.

## Day-to-day workflow

```sh
make tf-init      # first time only, or after changing backend.hcl
make tf-plan       # review infrastructure changes
make tf-apply      # create/update the server, firewall, DNS records
                    # (also regenerates ansible/inventory/hosts.yaml)
make ansible-apply  # configure the OS: podman, caddy, vector, cockpit, apps
```

If the server ever needs to be rebuilt from nothing: `make tf-apply` then
`make ansible-apply` fully restores it.

## Adding a new app

Follow the pattern in `ansible/roles/apps-demo/`:

1. Add a Cloudflare A record for the new hostname in `terraform/dns.tf`
   (on `apps_zone_id` for a public app), then `make tf-apply`.
2. Copy `ansible/roles/apps-demo/` to `ansible/roles/apps-<name>/`, updating
   the image reference in `templates/<name>.container.j2` and the hostname in
   `templates/<name>.caddy.j2`.
3. Add `apps-<name>` to the role list in `ansible/site.yaml`.
4. `make ansible-apply`.

Each app's quadlet runs with `DynamicUser=yes` — systemd allocates it its own
ephemeral, unprivileged host UID rather than sharing a fixed account.
`podman auto-update` (nightly timer) pulls new `:latest`/tagged images from
GHCR automatically. A private GHCR image will need a pull secret configured
on the server — not set up yet, add if/when a real app needs it.

## Alerting (Vector → ntfy.sh)

Vector watches journald for JSON `ERROR` logs and posts them to an ntfy.sh
topic, rate-limited to 1/minute. The topic URL is a secret, kept out of the
Caddy/Podman config and out of plaintext Ansible vars:

```sh
ansible-vault encrypt_string 'https://ntfy.sh/<your-private-topic>' \
  --name vault_ntfy_topic_url
```

Append the resulting block to `ansible/group_vars/all.yml`. Runs against the
inventory need `--ask-vault-pass`, or a gitignored `ansible/.vault_pass` file
passed via `--vault-password-file ansible/.vault_pass`.

ntfy.sh is the first-step backend; the topic URL is the only place it's
referenced, so swapping it for another push service later only means editing
`ansible/roles/vector/templates/vector.yaml.j2`'s sink and the one vaulted
variable.

## Cockpit (mobile administration)

Reachable at `https://admin.zetatwo.dev`, proxied by Caddy. `cockpit.socket`
itself only listens on `127.0.0.1:9090` — never exposed directly — and the
Hetzner Cloud Firewall only opens 22/80/443, so port 9090 is unreachable from
the internet regardless of Caddy's config.

**Note:** since this design has no non-root admin OS user (Ansible connects
and manages the box as `root`), Cockpit's default root-login block is
explicitly disabled so you can log in as `root`. This makes the Cockpit UI a
root-equivalent entry point, gated only by the Cockpit login password and the
network restrictions above. Understand that trade-off before relying on it.

## Domains

Two Cloudflare zones, both Terraform-managed, both with explicit
(never wildcard) A records:

- `zeta-two.com` — hobby apps, e.g. `demo.zeta-two.com`.
- `zetatwo.dev` — admin/infra surfaces, e.g. `admin.zetatwo.dev` (Cockpit).

The domain names are duplicated in two places — `terraform/variables.tf`
(`apps_domain`/`admin_domain` defaults) and `ansible/group_vars/all.yml`
(`apps_domain`/`admin_domain`) — update both together if either ever changes.
