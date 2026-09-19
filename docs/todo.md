# TODOs / deferred

A few things were deliberately dropped or deferred in the move from
Podman+Caddy to k3s, rather than carried over 1:1:

- **Admin/management tooling.** Cockpit was removed: it only binds to
  `127.0.0.1:9090`, and Traefik (running in the pod network) can't reach a
  host-loopback-only service without extra plumbing. Revisit this —
  options include a proper Kubernetes dashboard, or keeping something
  SSH-tunneled rather than exposed as a public admin surface.
- **App deployment / image updates**: done via Flux CD — see
  [App setup](app-setup.md#gitops-flux-cd). Remaining gaps: the
  CI-commits-back tag bump has no PR gate (a rare race on the commit is
  possible, mitigated with a rebase-retry); and Flux's
  image-automation-controllers were deliberately skipped in favor of that
  CI-side commit, worth revisiting if the cross-repo write PAT
  (`INFRA_REPO_PAT` in each app's CI) becomes a bigger rotation burden than
  running 2 more controllers would be.
- **Multi-node clustering.** `var.node_count` (`terraform/variables.tf`)
  scaffolds multiple node servers and DNS records (`node1`, `node2`, ...),
  but nodes don't join each other as a k3s cluster yet — bumping it above 1
  today just creates independent single-node servers. Needs k3s
  server/agent join logic (a shared cluster token, one initial server node)
  before it's actually usable.
- **Per-app auth allowlists.** `k8s/auth/`'s oauth2-proxy has one global
  `--github-user` allowlist shared by every app behind it (see
  [App setup](app-setup.md#one-time-auth-github-oauth-via-oauth2-proxy-bootstrap)).
  Fine for a single admin; would need a second oauth2-proxy instance (or a
  policy layer in front) if different apps ever need different allowed
  users/orgs.
- **Vector's `victoriametrics` sink healthcheck.** Vector logs
  `Healthcheck failed: Unexpected status: 204 No Content` for the
  `prometheus_remote_write` sink (`k8s/monitoring/vector.yaml`) on every
  startup — cosmetic, not a real failure: VictoriaMetrics correctly
  returns `204` on a successful remote-write, but Vector's healthcheck
  probe doesn't accept that status as healthy. Metrics still flow fine;
  worth a fix (or a Vector config option to relax/skip this healthcheck)
  if the log noise becomes annoying.
