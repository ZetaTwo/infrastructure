# Monitoring

Logs, metrics, dashboards and alerting for the cluster and its apps. Most of
it runs in the `monitoring` namespace (`k8s/monitoring/`, Flux-managed
HelmReleases), and a few parts live elsewhere (see [All the parts](#all-the-parts)).
The stack is chosen for one small node: few services, no clustering, and
every alert ends up in one private Discord channel. For what an app has to
do to fit in (JSON logs, the `app` label), see
[What an app must provide](app-setup.md#what-an-app-must-provide). App
metrics and feature counters are covered in [Analytics](analytics.md).

## How the data flows

```text
pod stdout/stderr ──► Vector ──► Loki ─────────────────────► Grafana
                        └─ ERROR lines ──────────────────────► Discord

node_exporter ────────┐
kube-state-metrics ───┤
kubelet (cAdvisor) ───┤
postgres_exporter ────┼─► VictoriaMetrics ──► Grafana
Vector's own metrics ─┤    (scrapes all)  └─► vmalert ──► Alertmanager ──► Discord
app pods (/metrics) ──┘

Flux reconcile errors ───────────────────────────────────────► Discord
```

There are three ways into Discord, all through one webhook: Vector for
ERROR logs, Alertmanager for metric alerts, and Flux for failed
reconciliations.

## All the parts

### Logs

| Part | Where | Purpose |
| --- | --- | --- |
| Vector (DaemonSet) | `k8s/monitoring/vector.yaml` | Tails every container's stdout/stderr, parses JSON lines, labels them, and ships them to Loki |
| Loki (single binary) | `k8s/monitoring/loki.yaml` | Log storage on a `local-path` PVC, 30-day retention. Its ruler is unused |
| App JSON logs | each app (`log_format = "json"`) | `level`/`message` at the top level, so `level` becomes a Loki label and ERROR lines can alert |

### Metrics

| Part | Where | Purpose |
| --- | --- | --- |
| node_exporter (DaemonSet) | `k8s/monitoring/node-exporter.yaml` | Host CPU, memory, disk and network (`node_*`). Also reads `*.prom` textfiles |
| Textfile metrics | `ansible/roles/reboot_required_metric` | `node_reboot_required`, written by a systemd timer on the node and read by node_exporter |
| kube-state-metrics | `k8s/monitoring/kube-state-metrics.yaml` | Kubernetes object state (`kube_*`): restarts, waiting reasons, replicas, Job and CronJob outcomes. Only the collectors the alerts use |
| cAdvisor (in the kubelet) | `victoria-metrics.yaml`, job `cadvisor` | Per-container CPU, throttling, memory, network and OOM kills |
| postgres_exporter | `k8s/postgres/exporter.yaml` | Per-database size, connections, transactions and cache hits for the shared Postgres |
| VictoriaMetrics (vmsingle) | `k8s/monitoring/victoria-metrics.yaml` | The only scraper and the metrics store, with a Prometheus-compatible API and 12-month retention |
| Recording rules | `k8s/monitoring/vmalert.yaml`, group `mappings` | Map namespaces and databases to app and environment for the Resources dashboard |
| App metrics | each app, port 9000 | RED metrics and feature counters ([Analytics](analytics.md)) |

### Alerts

| Part | Where | Purpose |
| --- | --- | --- |
| Vector → Discord | `k8s/monitoring/vector.yaml` | Posts every ERROR log line, throttled to one per app per 30 s |
| vmalert | `k8s/monitoring/vmalert.yaml` | Runs the metric alert rules against VictoriaMetrics |
| Alertmanager | `k8s/monitoring/alertmanager.yaml` | Groups, repeats and resolves metric alerts, and posts them to Discord |
| Flux notifications | `ansible/roles/flux/templates/notifications.yaml.j2` | Posts failed reconciliations (GitRepository, Kustomization, HelmRelease) to Discord. Applied by Ansible, so it doesn't depend on Flux reconciling it |
| Backup CronJobs | each app's `backup-cronjob.yaml` | Print a JSON ERROR line on failure ([Backups](backups.md#cronjob-template)), which reaches Discord through Vector |
| Discord webhook secret | `ansible/roles/monitoring`, `ansible/roles/flux` | One vaulted URL (`alertmanager_discord_webhook_url`): the `alertmanager-discord` Secret for Vector and Alertmanager, and `flux-discord` for Flux |

### Dashboards and ad-hoc views

| Part | Where | Purpose |
| --- | --- | --- |
| Grafana | `k8s/monitoring/grafana.yaml`, `grafana-ingress.yaml` | Dashboards and Explore over VictoriaMetrics and Loki, at `https://grafana.zetatwo.dev` |
| "Node Exporter Full" dashboard | `grafana.yaml` (grafana.com ID 1860) | Host resources |
| "Apps" dashboard | `grafana.yaml` | Per-app RED metrics and feature use ([Analytics](analytics.md#grafana)) |
| "Resources" dashboard | `grafana.yaml` | CPU, memory, network, restarts and database use per app and environment ([Resources](#resources)) |
| `just node-updates`, `just pods` | `justfile` | Terminal views of pending upgrades, kernel and reboot state, and pods |

### Not monitoring, but nearby

- **Apprise** (`notify` namespace, [Messaging](messaging.md)) carries the
  apps' operational messages (reports, notices) to Discord and email. It
  is deliberately not an alert path:
  [Alerting doesn't go through Apprise](messaging.md#alerting-doesnt-go-through-apprise).
- **Postmark** keeps its own activity log for transactional email.

### Addresses

| Component | In-cluster address |
| --- | --- |
| node_exporter | `node-exporter.monitoring.svc.cluster.local:9100` |
| kube-state-metrics | `kube-state-metrics.monitoring.svc.cluster.local:8080` |
| VictoriaMetrics | `vmsingle.monitoring.svc.cluster.local:8428` |
| Alertmanager | `alertmanager.monitoring.svc.cluster.local:9093` |
| Loki | `loki.monitoring.svc.cluster.local:3100` |

Chart versions are pinned in each HelmRelease. Bump them there.

## Logs

Vector reads every container's stdout/stderr (`kubernetes_logs`). Its
`parse_app_json` transform tries to parse each line as JSON. If that
works, the parsed object becomes the message and its `level` field is
promoted to a top-level field. Lines that aren't JSON pass through
unchanged with no level.

Everything goes to Loki with three labels:

- `namespace`: the pod's namespace.
- `app`: the pod's `app` label (empty if the pod has none).
- `level`: the parsed `level` (`INFO`, `ERROR`, ...), empty for non-JSON lines.

Logs are kept for 30 days (`retention_period` in `loki.yaml`, enforced by
the compactor). This is the only cap on their size, because `local-path`
volumes don't enforce their requested capacity.

Example queries in Grafana's Explore view (Loki datasource):

```logql
{namespace="canst-staging"}
{app="canst-backend", level="ERROR"}
{namespace="canst-staging"} |= "migrations"
```

## Metrics

vmsingle scrapes everything every 30 s, one job per source, each found
through Kubernetes discovery: `node-exporter`, `kube-state-metrics`,
`vector` (Vector's internal metrics, from its `prom_exporter` sink),
`cadvisor` (each node's kubelet) and `kubernetes-pods` (annotated pods: the
apps and postgres_exporter). The node_exporter, Vector and cAdvisor jobs
set `instance` to the node's name. Grafana ships with the
"Node Exporter Full" dashboard (grafana.com ID 1860) against the
VictoriaMetrics datasource. kube-state-metrics only runs the collectors the
alert rules need (pods, deployments, statefulsets, daemonsets, jobs,
cronjobs, nodes, namespaces, PVCs).

App pods opt in with `prometheus.io/*` annotations. Those metrics feed the provisioned
**Apps** dashboard and the `apps` alert group. See
[Analytics and app metrics](analytics.md).

## Resources

The **Resources** dashboard shows what each app uses, per environment,
with `Environment` and `App` pickers (several at once, or All):

- **Usage by app:** CPU and memory stacked against the node's capacity,
  and network in and out.
- **Containers:** each running container's CPU and memory against its
  requests and limits, restarts and OOM kills in the selected range, and
  CPU throttling for containers with a CPU limit.
- **Shared Postgres, per database:** size, connections, transactions per
  second and cache hit ratio, plus the server's own CPU and memory. Those
  two can't be split per database.

### How apps and environments are known

- **Namespaces carry the labels.** Each app namespace has
  `zetatwo.dev/app` and `zetatwo.dev/env` (`production` or `staging`),
  e.g. `obfuscation-challenge-sandbox-staging` is app
  `obfuscation-challenge`, env `staging`. Namespace names alone don't
  work: some production namespaces have no suffix, and an app can own
  several namespaces. kube-state-metrics exports the two labels
  (`metricLabelsAllowlist`), and the recording rule
  `namespace:app_env:info` turns them into one series per namespace.
  Namespaces without the labels (monitoring, postgres, kube-system, ...)
  count as their own app in env `infra`.
- **Databases follow their names.** postgres_exporter only knows database
  names, so `datname:app_env:info` reads app and env from the
  `<app>_<env>` naming convention (`obfuscation_challenge_staging`), with
  the app's dashes as underscores.
- **Queries join on those series**, for example:

  ```promql
  sum by (app, env) (
    rate(container_cpu_usage_seconds_total{container!=""}[5m])
    * on (namespace) group_left (app, env) namespace:app_env:info
  )
  ```

  `container!=""` keeps app containers and leaves out cAdvisor's
  pod-level totals and the pause containers. Network is per pod
  (`interface="eth0"`), with host-network pods left out, since they would
  report the whole node's traffic.

A new app needs both labels on its namespace and a database named
`<app>_<env>`. [App setup](app-setup.md) lists both steps.

### The collectors

- **cAdvisor** runs inside the kubelet. vmsingle scrapes
  `https://<node>:10250/metrics/cadvisor` with its service-account token
  (the chart's ClusterRole grants `nodes/metrics`), and verifies TLS
  against the service-account CA, which k3s also signs kubelet certs
  with. Only seven metric names are kept, out of about a hundred.
- **postgres_exporter** (`k8s/postgres/exporter.yaml`) logs in as
  `postgres_exporter`, a `pg_monitor` member that can read statistics but
  no table data. `ansible/roles/postgres` creates the role and the
  `postgres-exporter` Secret from the vaulted
  `postgres_exporter_password`, which the exporter reads from a file.
  The Postgres NetworkPolicy admits it by pod label. The server-settings
  and per-table collectors are off.

## Alerting

There are three independent paths to the same Discord webhook:

1. **Log alerts (Vector → Discord directly).** Any log line whose parsed
   `level` is `ERROR` is posted to Discord. The post names the pod's `app`
   label and includes the log message. Posts are throttled to one per `app`
   per 30 seconds, so a burst of errors produces one message, not hundreds.
   This bypasses Alertmanager on purpose: Alertmanager can only template a
   query result's labels, never the raw log text. Backup CronJobs use this
   path too: on failure they print a JSON `ERROR` line
   ([Backups](backups.md#cronjob-template)).
2. **Metric alerts (vmalert → Alertmanager → Discord).** Rules in
   `vmalert.yaml`, in three groups:

   | Group | Alert | Fires when |
   | --- | --- | --- |
   | `node` | `HighMemoryUsage` | memory above 90% for 2 min |
   | `node` | `HighCPUUsage` | CPU above 90% for 1 min |
   | `node` | `HighDiskUsage` | any ext4/xfs/btrfs filesystem above 90% for 2 min |
   | `node` | `RebootRequired` | the node needs a reboot after package upgrades, for 10 min |
   | `kubernetes` | `PodCrashLooping` | a container (init containers included) restarted more than 3 times in 15 min |
   | `kubernetes` | `ContainerStuckWaiting` | a container (init containers included) in `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull` or `CreateContainerConfigError` for 10 min |
   | `kubernetes` | `DeploymentUnavailable` | fewer available replicas than desired for 15 min (not a stuck rolling update: the old pod stays available) |
   | `kubernetes` | `DeploymentRolloutStuck` | a rollout has made no progress for its `progressDeadlineSeconds` (10 min by default), e.g. a failing `migrate` initContainer while the old pod keeps serving |
   | `kubernetes` | `StatefulSetUnavailable` | fewer ready replicas than desired for 15 min |
   | `kubernetes` | `JobFailed` | a Job started in the last 6 h has failed |
   | `kubernetes` | `BackupStale` (critical) | a `*-backup` CronJob hasn't succeeded in 26 h, or is over 26 h old and never has |
   | `apps` | `AppHighErrorRate` | more than 5% of an app's requests are 5xx for 10 min ([Analytics](analytics.md#alerts)) |
   | `apps` | `AppHighLatency` | an app's p95 latency is above 1 s for 10 min |

   `BackupStale` is the safety net for backups: the backup's own `ERROR`
   log line only fires when the job runs and fails, not when it never
   runs. Alertmanager groups by alert name (10 s initial wait, 5 min
   between updates), repeats an unresolved alert every 3 hours, and posts
   again when it resolves. Messages show the alert's `namespace` or
   `instance` label, whichever it has.
3. **Flux reconciliation errors (Flux → Discord directly).** A Flux
   `Alert` on error-severity events from every GitRepository and
   Kustomization, and from the HelmRepositories and HelmReleases in
   `monitoring`. Transient network errors are excluded, since the next
   attempt usually succeeds. Ansible applies it
   (`ansible/roles/flux/templates/notifications.yaml.j2`), so a broken
   tree can't stop the alert about itself.

To add a metric alert, add a rule to a group in `vmalert.yaml` and push.
Validate the rules first with vmalert's dry run (`vmalert -dryRun
-rule=<file>`, the rules extracted from the HelmRelease values). The chart
writes rules with `toYaml`, not `tpl`, so `{{ $labels.x }}` in annotations
needs no escaping.

## Where the parts overlap

Most apparent overlaps are deliberate. Each pair below does a similar job
in two places for a stated reason.

- **Vector and VictoriaMetrics both touched metrics, until 2026-11-26.**
  It wasn't designed that way; it grew. In the first version (2026-09-13)
  Vector collected everything, using its `host_metrics` source, and
  VictoriaMetrics was only storage. The same day, node_exporter replaced
  `host_metrics` so community dashboards would work, and Vector kept
  scraping it because it was already there. kube-state-metrics was added
  the same way. App metrics (2026-10-26) needed pod discovery, which
  Vector's `prometheus_scrape` can't do (static endpoints only), so
  vmsingle's own scraper was enabled for app pods alone. Now vmsingle
  scrapes everything and Vector only handles logs. The switch gave the
  infra series `job` and `instance` labels, which they never had before.
- **Two alert paths: Vector → Discord and vmalert → Alertmanager.**
  Alertmanager can only template a query result's labels, never the raw
  log text, so ERROR lines go straight from Vector. The cost is that
  Vector's path has no grouping, repeat or "resolved" message, just a
  30-second throttle per app.
- **Three senders on one webhook** (Vector, Alertmanager, Flux). Each
  posts natively with its own formatting. Routing all of them through
  Alertmanager would mean one place for silences and grouping, but log
  text and Flux events don't fit Alertmanager's model.
- **Failures can be reported twice.** A crashing app can log an ERROR
  (Vector) and also trip `PodCrashLooping` (vmalert), and a failing
  backup logs an ERROR and later trips `BackupStale`. These are
  intentional: the metric rules catch the cases where nothing gets
  logged, such as a pod that never starts or a CronJob that never runs.
- **Discord and Apprise.** Both reach Discord, but Apprise is for
  messages an app means to send, not for failures
  ([Messaging](messaging.md#alerting-doesnt-go-through-apprise)).
- **Unused leftovers.** Loki's ruler has no rules.

## Options considered

The reasoning for what's deployed, and what would change the decision.

| Choice | Instead of | Why |
| --- | --- | --- |
| Vector for logs | Promtail (deprecated) or Grafana Alloy | One DaemonSet, one config language (VRL), and it can post to Discord itself. Alloy would be the pick if this ever moved fully to the Grafana stack |
| VictoriaMetrics single | Prometheus, or kube-prometheus-stack | Less memory and disk for 12 months of retention, and a Prometheus-compatible API, so rules and dashboards stay standard. kube-prometheus-stack brings the operator, many CRDs and dozens of default rules and dashboards, which is too much for one node |
| vmsingle's own scraper for everything | vmagent, the VictoriaMetrics operator, or Vector scraping | No extra service, and pod discovery for every job. vmagent only matters with several storage targets or a remote store |
| Loki single binary, on the filesystem | Loki on object storage, Elasticsearch/OpenSearch, VictoriaLogs | Smallest footprint with label-only indexing. VictoriaLogs is the lighter alternative and a natural fit next to VictoriaMetrics. Worth a look if Loki's memory or query speed becomes a problem |
| node_exporter | Vector's `host_metrics` | Standard `node_*` names, so community dashboards work unmodified |
| kube-state-metrics with a trimmed collector list | Full defaults | Fewer series. Collectors are added when a rule or dashboard needs them |
| vmalert + Alertmanager | Grafana alerting | Rules live in git next to the stack and keep working when Grafana is down. Grafana alerting could also cover log rules, but it keeps state in Grafana's database |
| ERROR lines → Discord from Vector | Loki ruler → Alertmanager | Discord gets the full log message and fields, not just labels |
| Discord | Email, PagerDuty, ntfy | Already where the operator looks. Email could be added as a second Alertmanager receiver ([Messaging](messaging.md#alerting-doesnt-go-through-apprise)) |
| No tracing | Tempo or VictoriaTraces with OpenTelemetry | Single backends with no fan-out ([Analytics](analytics.md#tracing)) |
| No external uptime check | Uptime Kuma off-node, or a hosted checker or dead man's switch | Not built yet, see [Limitations](#limitations) |

## Access and secrets

Grafana is at `https://grafana.zetatwo.dev`, behind the oauth2-proxy
`admin` policy. Grafana's `[auth.proxy]` signs you in automatically from
the `X-Auth-Request-Email` header the gate sets, as an Admin. The
`grafana-admin-credentials` login is break-glass only, e.g. over
`kubectl port-forward`, where no auth header is present.

The Discord webhook URL and the Grafana admin password are vaulted and
applied by `ansible/roles/monitoring`, not Flux. Alertmanager and Vector
read the same `alertmanager-discord` Secret, Vector in its JSON form
because its file secrets backend requires a JSON object. Bootstrap steps:
[App setup](app-setup.md#one-time-monitoring-secrets-bootstrap).

## Limitations

- **Everything runs on the node it watches.** If node1, k3s or the
  `monitoring` namespace goes down, nothing alerts. An off-node check
  would close that gap: an external uptime probe of the public hosts, or
  a dead man's switch, where Alertmanager sends an always-firing
  `Watchdog` alert to a hosted service that alerts when it stops
  arriving.
- **No disk use per app.** Apps have no volumes of their own, so their
  database size is their disk use. The infra volumes (VictoriaMetrics,
  Loki, Postgres) only show up as node disk usage.
- **No query-level Postgres metrics.** `pg_stat_statements` isn't
  enabled, so slow queries aren't visible per statement.
