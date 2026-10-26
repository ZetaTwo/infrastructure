# Analytics and app metrics

How to see what's going on inside the apps: whether they're healthy, and
which features get used, how often, and how that trends over time.
Per-user analysis (who did what, funnels, distinct users) is out of
scope on purpose. canst is the first app wired up.

## Decision

Both questions are answered with **Prometheus metrics from the apps**,
scraped by VictoriaMetrics (vmsingle) and shown in Grafana, on the stack
described in [Monitoring](monitoring.md). There are no new services.

| Question | Signal | Metric |
| --- | --- | --- |
| Is the app healthy? | RED metrics per route | `http_requests_total`, `http_request_duration_seconds` |
| Which features are used, how often, trending how? | Feature counters | `feature_used_total{feature="submission.create"}` |
| Why was this request slow? | Traces | Not built, see [Tracing](#tracing) |

**RED** is the standard set of health metrics for a request-serving
service, each per route:

- **Rate**: requests per second.
- **Errors**: failed requests (mostly 5xx), as a share of all requests.
- **Duration**: latency percentiles such as p95.

Product analytics tools usually need an event store because they slice
by user. Without that, usage questions become aggregate counts per
feature over time, which is what metrics are good at. The counters are
anonymous totals, which also fits canst's no-public-counting,
low-surveillance rules.

### Why not

- **An `events` table in each app's Postgres**, queried from Grafana:
  the upgrade path if distinct-user counts, funnels or ad-hoc event
  properties ever matter.
- **Event log lines in Loki**: 30-day retention and weak aggregation.
- **PostHog, OpenPanel, Matomo**: hosted is ruled out. Self-hosted, they
  need ClickHouse, Kafka or Redis and several services, which is too
  heavy for one node. Their strength is per-user analysis.
- **Umami**: anonymous frontend stats (page views, referrers). It
  overlaps with feature counters. Add it if page-level traffic becomes
  interesting.
- **An OpenTelemetry Collector**: Vector already collects logs and
  metrics. See [Tracing](#tracing).

### Tracing

Deferred. The apps are single backends with no service fan-out, so a
trace mostly shows handler time versus database time. The apps already
emit `tracing` spans. When slow-request debugging needs it, add a
`tracing-opentelemetry` + `opentelemetry-otlp` exporter, have Vector
receive OTLP, and add a trace store (Tempo or VictoriaTraces) as a
Grafana datasource.

## How it works

### Scraping

vmsingle scrapes app pods directly (`scrape` in
`k8s/monitoring/victoria-metrics.yaml`, which uses Kubernetes pod
discovery and the chart's RBAC). Vector keeps scraping the infra
exporters. Its `prometheus_scrape` source only takes static endpoints,
so it can't discover pods.

A pod is scraped when:

- it has the annotations `prometheus.io/scrape: "true"` and
  `prometheus.io/port: "<port>"`, and
- that port is a declared `containerPort` (`keep_if_equal`), serving
  `/metrics`.

Each series gets the pod's `app` label, `namespace` and `pod`, the same
`app`/`namespace` as its logs in Loki. Apps serve metrics on a separate
port (`9000`) that's left out of the Service, so no Ingress can route to
it.

### Retention

`retentionPeriod: 12` (months), long enough for usage trends. That's
about 1.4 GB per month at the series count when it was set, mostly
node_exporter and kube-state-metrics, so roughly 17 GB on the node disk.
`HighDiskUsage` covers it.

### Metrics an app serves

| Metric | Type | Labels |
| --- | --- | --- |
| `http_requests_total` | counter | `method`, `route`, `status` |
| `http_request_duration_seconds` | histogram | `method`, `route` |
| `feature_used_total` | counter | `feature` |

- **`route` is the matched route template** (`/api/submissions/{id}`),
  never the raw path. Requests that match no route get `unmatched`.
- **Feature names are `noun.verb`** in lower case (`submission.create`),
  from a fixed list in the app. The counter is incremented server-side
  **when the action succeeds**. Every feature is registered at 0 on
  startup, so unused features show as zero instead of being missing.
- **Label values come from a fixed, small set.** Never put user ids,
  emails, entity ids, raw paths or free text in a label, because each
  distinct value is a new series.
- Durations must be a **histogram** (buckets), not a summary, so
  `histogram_quantile` can aggregate across routes and pods.

In canst (`backend/src/telemetry.rs`), the `metrics` crate and
`metrics-exporter-prometheus` serve `[metrics] listen_addr`. An axum
middleware records the RED metrics, and `telemetry::record(Feature::...)`
counts a feature. Without `[metrics]`, nothing is served and the calls
are no-ops.

### Grafana

The provisioned **Apps** dashboard (`k8s/monitoring/grafana.yaml`) has
`namespace` and `app` variables and these panels: requests per second
by route, 5xx share, p95 latency by route, feature use in the selected
time range, and feature use per day. Useful ad-hoc queries:

```promql
# Feature use per week
sum by (feature) (increase(feature_used_total{app="canst-backend"}[1w]))

# Features unused in the last 30 days
sum by (feature) (increase(feature_used_total{app="canst-backend"}[30d])) == 0

# Is scraping working? (1 per scraped pod)
up{job="kubernetes-pods"}
```

### Alerts

The `apps` group in `vmalert.yaml`. Both rules only fire above 0.05
req/s (about 30 requests in 10 minutes), so one failed request on an
idle staging app doesn't alert.

| Alert | Fires when |
| --- | --- |
| `AppHighErrorRate` | more than 5% of an app's requests are 5xx for 10 min |
| `AppHighLatency` | an app's p95 latency is above 1 s for 10 min |

## Adding an app

1. Serve the three metrics above on a separate port.
2. In its Deployment, declare the port as a `containerPort` and add the
   two annotations (see `k8s/canst/base/backend-deployment.yaml`).
3. The app then shows up in the Apps dashboard's `app` variable.
