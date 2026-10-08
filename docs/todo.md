# TODOs / deferred

A few things were deliberately dropped or deferred in the move from
Podman+Caddy to k3s, rather than carried over 1:1:

- **Multi-node clustering.** `var.node_count` (`terraform/variables.tf`)
  scaffolds multiple node servers and DNS records (`node1`, `node2`, ...),
  but nodes don't join each other as a k3s cluster yet — bumping it above 1
  today just creates independent single-node servers. Needs k3s
  server/agent join logic (a shared cluster token, one initial server node)
  before it's actually usable.
- **No live storage redundancy for stateful apps.** Every PVC uses
  `local-path` (host-path, tied to the node's local disk) — see
  [Backups](backups.md#storage). Backups are the only recovery mechanism,
  not a layer on top of redundant storage. Revisit (Hetzner CSI + a
  detachable Volume) once multi-node clustering exists.
- **Repeat backup restore drills.** First drilled 2026-10-04 on
  canst-staging ([Backups](backups.md#restore)), but against a database
  with no user data yet. Repeat periodically, and once real data exists.
- **Vector's `victoriametrics` sink healthcheck.** Vector logs
  `Healthcheck failed: Unexpected status: 204 No Content` for the
  `prometheus_remote_write` sink (`k8s/monitoring/vector.yaml`) on every
  startup — cosmetic, not a real failure: VictoriaMetrics correctly
  returns `204` on a successful remote-write, but Vector's healthcheck
  probe doesn't accept that status as healthy. Metrics still flow fine;
  worth a fix (or a Vector config option to relax/skip this healthcheck)
  if the log noise becomes annoying.
- **No NetworkPolicy around the shared Postgres.** Every pod in the
  cluster can reach `postgres.postgres.svc.cluster.local:5432`; only
  per-database passwords and the revoked `CONNECT` keep apps apart. Add a
  NetworkPolicy admitting just app namespaces that have a database.
- **canst production.** Only `k8s/canst/overlays/staging/` exists. Production
  needs an overlay (`canst.zeta-two.com`, public), a `canst` database and
  environment entry, its own secrets and backup target, and a release job in
  the canst repo that promotes the tested `:<sha>` image.
- **Discord alerts drop every structured field but `message`.** Vector's
  `format_discord` transform (`k8s/monitoring/vector.yaml`) only ever
  forwards `.message.message` to Discord; any other field an app logs
  alongside it (`status`, request context, etc.) silently never reaches
  the alert even though it's sitting right there in the parsed JSON and
  still reaches Loki. This forces every app to cram all alert-worthy
  detail into the message string itself (worked around for
  aoe2-groups-proxy, see its `error.rs`), which is fragile and easy to
  regress. Fix properly: have `format_discord` render the other fields
  too (e.g. as a second embed field, or inline in the text) instead of
  discarding them.
