# Monitoring

Logs, metrics, dashboards and alerting for the cluster and its apps, all in
the `monitoring` namespace (`k8s/monitoring/`, Flux-managed HelmReleases).
The stack is chosen for a small single node: Vector instead of
Promtail/Prometheus agents, VictoriaMetrics instead of Prometheus,
single-binary Loki. Alerts go to a private Discord channel via webhook. For
what an app has to do to fit in (JSON logs, the `app` label), see
[What an app must provide](app-setup.md#what-an-app-must-provide).

## Components

| Component | Manifest | Role | In-cluster address |
| --- | --- | --- | --- |
| Vector (DaemonSet) | `vector.yaml` | Tails every pod's logs, scrapes node_exporter, ships logs to Loki and metrics to VictoriaMetrics, posts ERROR logs to Discord | — |
| node_exporter | `node-exporter.yaml` | Host metrics (`node_*`), plus `*.prom` textfiles such as `node_reboot_required` from `ansible/roles/reboot_required_metric` | `node-exporter.monitoring.svc.cluster.local:9100` |
| kube-state-metrics | `kube-state-metrics.yaml` | Kubernetes object state (`kube_*`): restarts, waiting reasons, replica counts, Job and CronJob outcomes | `kube-state-metrics.monitoring.svc.cluster.local:8080` |
| VictoriaMetrics (single) | `victoria-metrics.yaml` | Metrics storage with a Prometheus-compatible API | `vmsingle.monitoring.svc.cluster.local:8428` |
| vmalert | `vmalert.yaml` | Evaluates metric alert rules, fires to Alertmanager | — |
| Alertmanager | `alertmanager.yaml` | Groups metric alerts, posts them to Discord | `alertmanager.monitoring.svc.cluster.local:9093` |
| Loki (single binary) | `loki.yaml` | Log storage, filesystem on a `local-path` PVC, 30-day retention | `loki.monitoring.svc.cluster.local:3100` |
| Grafana | `grafana.yaml`, `grafana-ingress.yaml` | Dashboards and queries over both stores | `https://grafana.zetatwo.dev` |

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

Vector scrapes node_exporter, kube-state-metrics and its own internal
metrics, and remote-writes them to VictoriaMetrics. Grafana ships with the
"Node Exporter Full" dashboard (grafana.com ID 1860) against the
VictoriaMetrics datasource. kube-state-metrics only runs the collectors the
alert rules need (pods, deployments, statefulsets, daemonsets, jobs,
cronjobs, nodes, namespaces, PVCs).

**App metrics are not scraped**: no app's own `/metrics` endpoint is picked
up. See [Limitations](#limitations).

## Alerting

There are two independent paths to the same Discord webhook:

1. **Log alerts (Vector → Discord directly).** Any log line whose parsed
   `level` is `ERROR` is posted to Discord. The post names the pod's `app`
   label and includes the log message. Posts are throttled to one per `app`
   per 30 seconds, so a burst of errors produces one message, not hundreds.
   This bypasses Alertmanager on purpose: Alertmanager can only template a
   query result's labels, never the raw log text. Backup CronJobs use this
   path too: on failure they print a JSON `ERROR` line
   ([Backups](backups.md#cronjob-template)).
2. **Metric alerts (vmalert → Alertmanager → Discord).** Rules in
   `vmalert.yaml`, in two groups:

   | Group | Alert | Fires when |
   | --- | --- | --- |
   | `node` | `HighMemoryUsage` | memory above 90% for 2 min |
   | `node` | `HighCPUUsage` | CPU above 90% for 1 min |
   | `node` | `HighDiskUsage` | any ext4/xfs/btrfs filesystem above 90% for 2 min |
   | `node` | `RebootRequired` | the node needs a reboot after package upgrades, for 10 min |
   | `kubernetes` | `PodCrashLooping` | a container restarted more than 3 times in 15 min |
   | `kubernetes` | `ContainerStuckWaiting` | a container in `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull` or `CreateContainerConfigError` for 10 min |
   | `kubernetes` | `DeploymentUnavailable` | fewer available replicas than desired for 15 min, e.g. a failing `migrate` initContainer |
   | `kubernetes` | `StatefulSetUnavailable` | fewer ready replicas than desired for 15 min |
   | `kubernetes` | `JobFailed` | a Job started in the last 6 h has failed |
   | `kubernetes` | `BackupStale` (critical) | a `*-backup` CronJob hasn't succeeded in 26 h, or is over 26 h old and never has |

   `BackupStale` is the safety net for backups: the backup's own `ERROR`
   log line only fires when the job runs and fails, not when it never
   runs. Alertmanager groups by alert name (10 s initial wait, 5 min
   between updates), repeats an unresolved alert every 3 hours, and posts
   again when it resolves. Messages show the alert's `namespace` or
   `instance` label, whichever it has.

To add a metric alert, add a rule to a group in `vmalert.yaml` and push.
Validate the rules first with vmalert's dry run (`vmalert -dryRun
-rule=<file>`, the rules extracted from the HelmRelease values). The chart
writes rules with `toYaml`, not `tpl`, so `{{ $labels.x }}` in annotations
needs no escaping.

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

- **No app metrics.** Apps' own `/metrics` endpoints aren't scraped, so
  there's no request rate, latency or error-rate alerting. App problems
  surface only through `ERROR` logs or the Kubernetes state rules above.
- Vector logs a harmless healthcheck failure for the VictoriaMetrics sink
  on every startup ([TODOs](todo.md)).
