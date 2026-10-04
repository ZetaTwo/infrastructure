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
| VictoriaMetrics (single) | `victoria-metrics.yaml` | Metrics storage with a Prometheus-compatible API | `vmsingle.monitoring.svc.cluster.local:8428` |
| vmalert | `vmalert.yaml` | Evaluates metric alert rules, fires to Alertmanager | — |
| Alertmanager | `alertmanager.yaml` | Groups metric alerts, posts them to Discord | `alertmanager.monitoring.svc.cluster.local:9093` |
| Loki (single binary) | `loki.yaml` | Log storage, filesystem on a `local-path` PVC | `loki.monitoring.svc.cluster.local:3100` |
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

Example queries in Grafana's Explore view (Loki datasource):

```logql
{namespace="canst-staging"}
{app="canst-backend", level="ERROR"}
{namespace="canst-staging"} |= "migrations"
```

## Metrics

Vector scrapes node_exporter and its own internal metrics, and
remote-writes both to VictoriaMetrics. Grafana ships with the
"Node Exporter Full" dashboard (grafana.com ID 1860) against the
VictoriaMetrics datasource.

That's all that is collected today. **App metrics are not scraped** (no
`/metrics` endpoints are picked up), and there's no kube-state-metrics, so
Kubernetes object state (restarts, crash loops, failed Jobs) isn't
available as metrics. See [Limitations](#limitations).

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
2. **Metric alerts (vmalert → Alertmanager → Discord).** The rules in
   `vmalert.yaml` cover the node only:

   | Alert | Fires when |
   | --- | --- |
   | `HighMemoryUsage` | memory above 90% for 2 min |
   | `HighCPUUsage` | CPU above 90% for 1 min |
   | `HighDiskUsage` | any ext4/xfs/btrfs filesystem above 90% for 2 min |
   | `RebootRequired` | the node needs a reboot after package upgrades, for 10 min |

   Alertmanager groups by alert name (10 s initial wait, 5 min between
   updates) and repeats an unresolved alert every 3 hours.

To add a metric alert, add a rule to the `node` group (or a new group) in
`vmalert.yaml` and push.

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

- **No app metrics and no Kubernetes state.** A pod stuck in
  `CrashLoopBackOff` or `ImagePullBackOff`, or a failed Job, alerts only if
  it happens to log an `ERROR` line first. A crash before logging, or a pod
  that never starts, is silent. Adding kube-state-metrics (scraped by
  Vector) plus a few vmalert rules would close this.
- **Loki has no retention configured.** Logs are kept forever. `local-path`
  volumes don't enforce their requested size, so they grow on the node's
  root disk, shared with every other app and the database, until
  `HighDiskUsage` fires. It also runs with the chart's
  `useTestSchema: true` instead of an explicit schema config.
- **Metric alerts have no `app` label**, so the `App:` line in their Discord
  message is empty. Only log alerts name an app.
- Vector logs a harmless healthcheck failure for the VictoriaMetrics sink
  on every startup ([TODOs](todo.md)).
