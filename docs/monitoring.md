Here is the markdown summary of your lightweight, self-hosted observability stack tailored for a k3s cluster and a Rust backend.

***

# Lightweight k3s Observability Stack

A resource-efficient, self-hosted monitoring and alerting pipeline designed for Kubernetes (k3s). It leverages Rust-based tooling for minimal CPU/Memory footprint and routes alerts directly to a mobile device via Discord.

## 🏗️ Architecture Overview

| Component | Tool | Purpose |
| :--- | :--- | :--- |
| **Application** | **Rust (`tracing`)** | Generates structured JSON logs/events to `stdout`. |
| **Collector** | **Vector** | Runs as a DaemonSet. Tails logs, scrapes metrics, executes VRL (Vector Remap Language) to parse JSON, and routes data. |
| **Metrics Storage** | **VictoriaMetrics** | Drop-in Prometheus replacement. Highly compressed, low RAM usage. |
| **Log Storage** | **Loki** | Label-based log aggregation. Doesn't index full text, keeping it extremely lightweight. |
| **Visualization** | **Grafana** | Queries VictoriaMetrics and Loki. Provides a responsive web UI accessible from mobile browsers. |
| **Alerting** | **Alertmanager** | Groups, deduplicates, and routes triggered alerts to Discord. |
| **Delivery** | **Discord** | A private Discord server with a dedicated Webhook channel for mobile push notifications. |

---

## 🔄 End-to-End Data Flow

### 1. Log Generation (Rust)
The Rust application uses the `tracing` and `tracing-subscriber` crates to format events as JSON and write them to standard output. 
* *Why:* JSON preserves structured key-value pairs (e.g., `user_id`, `error_code`) without requiring complex regex parsing later.

### 2. Collection & Transformation (Vector)
Kubernetes natively writes the `stdout` streams to node disks. **Vector** picks up these files and applies a pipeline:
1. **Ingest:** Reads the raw Kubernetes log line.
2. **Transform (VRL):** Parses the embedded Rust JSON. Extracts keys (like `level` or `app`) and promotes them to Kubernetes labels.
3. **Sink:** Forwards the processed payload to Loki and VictoriaMetrics.

### 3. Storage & Querying (Loki & Grafana)
Loki receives the logs and indexes **only the labels** (e.g., `level="ERROR"`). The heavy JSON payload is compressed and stored cheaply. 
You can open **Grafana** on your mobile browser, query `{app="my-rust-app", level="ERROR"}`, and easily read the cleanly formatted JSON fields.

### 4. Alerting & Mobile Delivery (Alertmanager & Discord)
1. **Rule Evaluation:** Loki/VictoriaMetrics constantly evaluates rules (e.g., *"> 5 ERROR logs in 1 minute"*).
2. **Trigger:** An alert is fired to **Alertmanager**.
3. **Grouping:** Alertmanager bundles duplicate alerts together based on your configured `group_wait` window.
4. **Push Notification:** Alertmanager POSTs a JSON payload to a **Discord Webhook** attached to a private Discord server. You receive a native push notification on your phone with a neatly formatted summary of the errors.

---

## 🛠️ Key Configuration Highlights

### Rust Application (`main.rs`)
```rust
// Output structured JSON to stdout for k3s to capture
tracing_subscriber::fmt()
    .json()
    .flatten_event(true) 
    .init();
```

### Vector Log Parsing (`vector.yaml`)
```yaml
transforms:
  parse_rust_json:
    type: remap
    inputs: ["kubernetes_logs"]
    source: |
      # Parse JSON and extract the log level for Loki indexing
      parsed_json, err = parse_json(.message)
      if err == null {
          .message = parsed_json 
          .level = parsed_json.level
      }
```

### Alertmanager to Discord (`alertmanager.yml`)
```yaml
receivers:
- name: 'discord_alerts'
  discord_configs:
  - webhook_url: 'https://discord.com/api/webhooks/YOUR_ID/YOUR_TOKEN'
    title: '🚨 Alert: {{ .GroupLabels.alertname }}'
    message: |-
      {{ range .Alerts }}
      **App:** {{ .Labels.app }}
      **Details:** {{ .Annotations.summary }}
      {{ end }}
```

---

## 🌟 Why this design works for you
* **Extremely Low Resource Usage:** Vector and VictoriaMetrics use a fraction of the RAM/CPU compared to Promtail and Prometheus, leaving more room on your k3s nodes for your actual apps.
* **No "Dumb Text" Logs:** By using JSON in Rust and parsing it in Vector, your logs are highly structured and instantly searchable.
* **Frictionless Mobile Alerts:** By using a private Discord server and native Webhooks, you get instantaneous mobile push notifications without maintaining custom bot code or exposing internal network ports.
