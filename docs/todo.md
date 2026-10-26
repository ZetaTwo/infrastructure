# TODOs / deferred

A few things were deliberately dropped or deferred in the move from
Podman+Caddy to k3s, rather than carried over 1:1:

- **Multi-node clustering.** `var.node_count` (`terraform/variables.tf`)
  scaffolds multiple node servers and DNS records (`node1`, `node2`, ...),
  but nodes don't join each other as a k3s cluster yet — bumping it above 1
  today just creates independent single-node servers. Needs k3s
  server/agent join logic (a shared cluster token, one initial server node)
  before it's actually usable. Storage also needs rethinking then: every
  PVC uses `local-path` (host-path, tied to the node's local disk — see
  [Backups](backups.md#storage)), which is fine on one node with backups
  but pins stateful pods to whichever node holds their data. Move them to
  storage that can follow a pod (e.g. Hetzner CSI + a detachable Volume).
- **Repeat backup restore drills.** First drilled 2026-10-04 on
  canst-staging ([Backups](backups.md#restore)), but against a database
  with no user data yet. Repeat periodically, and once real data exists.
- **aoe2tm production.** Only `k8s/aoe2tm/overlays/staging/` exists. Production
  needs an overlay (`aoe2tm.zeta-two.com`, public, no `seed` initContainer), an
  `aoe2tm` database and environment entry, its own secrets and backup target,
  and real login provider apps. The app repo's `release.yml` already promotes
  `:<sha>` images to `vX.Y.Z` tags for it.
- **canst production.** Only `k8s/canst/overlays/staging/` exists. Production
  needs an overlay (`canst.zeta-two.com`, public), a `canst` database and
  environment entry, and its own secrets and backup target. The canst repo's
  release workflow already promotes `:<sha>` images to `vX.Y.Z` tags.
