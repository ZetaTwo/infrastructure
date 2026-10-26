# Messaging

**Status: design only, not built yet** ([TODOs](todo.md)).

How apps send messages that aren't alerts or error logs: transactional
email to users (password resets, sign-in links, notifications) and
operational messages to the operator (reports, digests, non-error
warnings). Alerting is separate and stays as described in
[Monitoring](monitoring.md#alerting).

## Decision

The two kinds of message get different answers:

| Kind | Audience | Channel | Mechanism |
| --- | --- | --- | --- |
| Transactional | App users | Email | Each app talks to Postmark directly with its own credential. No in-cluster service. |
| Operational | Operator | Discord and email | Apps POST to one in-cluster Apprise API service, which fans out by tag. |

User email needs per-app sender identity and isolation, and Postmark
already queues, retries and handles bounces and suppression, so a
central service would only add a hop. Operational messages must reach
two channels. Without a central fan-out, every app would carry a
Discord webhook, an email credential and its own routing code.

### Why not

- **Own MTA** (Postfix, maddy, Stalwart): Hetzner Cloud blocks outbound
  25/465 by default, and inbox placement needs IP reputation work.
- **Notification platform** (Novu and similar): templates, user
  preferences and in-app inboxes we don't need, and Novu needs Mongo,
  Redis and several services. Reconsider if apps need per-user channel
  preferences.
- **Shared in-cluster SMTP relay**: a stateful queue and a single point
  of failure, and it either shares one sender credential across apps or
  re-creates per-app credentials as SASL users.
- **Alertmanager as the operational router**: works for warnings (dedup,
  grouping), but reports would live in alert annotations with
  firing/resolved semantics.
- **Other providers**: Resend (bigger free tier, weaker per-app
  separation), Amazon SES (cheapest, but a new AWS account and a
  sandbox-exit request), Scaleway TEM or Brevo (EU-hosted).

### Alerting doesn't go through Apprise

Vector, Alertmanager and Flux keep posting to Discord directly:

- **Alerting must not depend on what it watches.** Apprise is a
  Deployment covered by `DeploymentUnavailable` and `PodCrashLooping`,
  so a dead notify pod would silence the alert about itself. This is
  the same reason Flux's alerts are applied by Ansible, not Flux
  (`ansible/roles/flux/templates/notifications.yaml.j2`).
- **Apprise is best-effort.** It has no queue or retries, while
  Alertmanager retries, repeats and sends resolve notifications.
- **The senders already do it natively**, with their own formatting and
  throttling.

The only thing shared with alerting is the Postmark `internal` server's
SMTP credential. That lets Alertmanager get a native `email_configs`
receiver for `severity=critical` if critical alerts should also go to
email.

## Transactional email (Postmark)

- **One Postmark server per app × environment**, e.g. `canst-production`
  and `canst-staging`. Each has its own token, activity log and stats.
  Staging servers run in **sandbox mode**: they accept and log mail but
  never deliver it.
- **Sending domain:** `mail.zeta-two.com`, from addresses like
  `canst@mail.zeta-two.com`. DKIM, the return-path CNAME, SPF and DMARC
  (`p=none` at first, `quarantine` once reports are clean, `rua` to the
  operator) are explicit Cloudflare records in `terraform/dns.tf`.
- **App config:** an `[email]` section in the app's `config.toml.j2`.
  The token is vaulted per environment like `paseto_key`:

  ```toml
  [email]
  provider_token = "{{ item.postmark_token }}"
  from = "canst@mail.zeta-two.com"
  reply_to = "calle.svensson@zeta-two.com"
  ```

- **App code:** a `Mailer` trait with a Postmark HTTP implementation
  (or `lettre` over SMTP on 587) and a logging no-op for tests.

## Operational messages (Apprise)

- **Service:** `k8s/notify/` has a namespace, a Deployment of the pinned
  `caronc/apprise` image and a Service at
  `notify.notify.svc.cluster.local:8000`. There's no ingress, no PVC and
  no database. A NetworkPolicy optionally admits only app namespaces.
- **Routing config:** an Apprise YAML config stored under the key `apps`.
  It maps tags to targets:

  | Tag | Targets |
  | --- | --- |
  | `report` | Discord `#reports` + email to the operator |
  | `notice` | Discord `#app-notices` + email to the operator |

  The webhooks and the Postmark `internal` server's SMTP credential are
  vaulted. `ansible/roles/notify` applies the config as a Secret, like
  the monitoring secrets. Long bodies are split or truncated for
  Discord's 2000-character limit, while email gets the full text.
- **App config:** a `[notify]` section with no secret:

  ```toml
  [notify]
  url = "http://notify.notify.svc.cluster.local:8000/notify/apps"
  ```

- **App code:** a `Notifier` that POSTs `{title, body, tag}`. Dedup is
  the app's job, e.g. "warn at most once per hour".

## Implementation checklist

- [ ] Postmark account, the `mail.zeta-two.com` sender domain, and
      servers per app × env plus `internal`.
- [ ] `terraform/dns.tf`: DKIM, return-path, SPF and DMARC records.
- [ ] `ansible/group_vars/all.yml`: vaulted Postmark tokens, the Discord
      webhooks for `#reports` and `#app-notices`, and the internal SMTP
      credential.
- [ ] `ansible/roles/notify/` plus `ansible/site.yaml`: the Apprise
      config Secret.
- [ ] `k8s/notify/` plus `k8s/kustomization.yaml`: the Apprise
      deployment.
- [ ] `ansible/roles/<app>/templates/config.toml.j2`: `[email]` and
      `[notify]` per app.
- [ ] Optional: an Alertmanager `email_configs` receiver for
      `severity=critical`.
- [ ] Document the new sections in
      [What an app must provide](app-setup.md#what-an-app-must-provide),
      and add `Mailer`/`Notifier` to the `fullstack-webapp` skill.

## Verification

- `dig` the new records, then Postmark's domain check passes.
- From a `canst-staging` pod, send through the sandbox server. The mail
  appears in the Postmark activity log and isn't delivered.
- Send a real message to a Gmail address. `Authentication-Results` shows
  SPF, DKIM and DMARC passing, and it lands in the inbox.
- From a debug pod, run
  `curl -XPOST notify.notify.svc:8000/notify/apps -d 'tag=report&title=test&body=hello'`.
  The message arrives in `#reports` and by email. Repeat with
  `tag=notice` and a body over 2000 characters.
