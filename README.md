# infrastructure

Deploy-and-forget hosting for hobby projects on a single Hetzner Cloud VPS.
Terraform owns the server, firewall, and DNS. Ansible installs a single-node
k3s cluster, cert-manager, and Flux CD. Flux continuously reconciles
Kubernetes manifests — one directory per app under `k8s/` in this repo —
onto the cluster, so deploying an app is a `git push`, not an Ansible run.
Traefik (bundled with k3s) handles ingress, and cert-manager issues Let's
Encrypt certificates per app via HTTP-01. A shared GitHub OAuth gate
(`k8s/auth/`) protects non-public surfaces — Grafana and any app's staging
environment — with a single login, instead of per-app passwords.

## Documentation

- **[Cluster setup](docs/cluster-setup.md)** — provisioning the VPS from
  scratch (Hetzner/Cloudflare tokens, Terraform state bucket), the
  day-to-day `make tf-apply`/`make ansible-apply` workflow, accessing the
  cluster over SSH, the admin login, and how domains map to Cloudflare
  zones.
- **[App setup](docs/app-setup.md)** — the GitOps workflow for deploying
  apps via Flux, the staging (`<app>.zetatwo.dev`) + production
  (`<app>.zeta-two.com`) pattern, per-app secrets bootstrap, and the shared
  GitHub OAuth (oauth2-proxy) auth gate.
- **[Monitoring](docs/monitoring.md)** — the observability stack design
  (Vector, VictoriaMetrics, Loki, Grafana, Alertmanager → Discord).
- **[TODOs / deferred](docs/todo.md)** — known gaps and things deliberately
  left for later.

Start with [Cluster setup](docs/cluster-setup.md) if you're bootstrapping
this from nothing; start with [App setup](docs/app-setup.md) if the cluster
already exists and you're deploying or changing an app.
