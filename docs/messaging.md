# Messaging

How apps send messages that aren't alerts or error logs: transactional
email to users (password resets, notifications) and operational messages
to the operator (reports, digests, non-error warnings). Alerting is
separate and stays as described in [Monitoring](monitoring.md#alerting).
canst is the first app wired up: password reset emails, and a notice for
each new prompt suggestion.

**Status:** the operational path (Apprise) is live, posting to Discord.
Email needs the one-time [Postmark bootstrap](#postmark-bootstrap). Until
then, canst logs its emails instead of sending them, and Apprise has no
email target.

## Decision

The two kinds of message get different answers:

| Kind | Audience | Channel | Mechanism |
| --- | --- | --- | --- |
| Transactional | App users | Email | Each app talks SMTP to Postmark directly, with its own server's credential. No in-cluster service. |
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
- **Postmark's HTTP API instead of SMTP**: no gain at this volume, and
  SMTP keeps apps provider-agnostic. aoe2tm already has an SMTP
  `Mailer`, and canst uses the same one.
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

The reverse does hold: an app that fails to reach Apprise logs an
`ERROR`, which Vector posts to Discord. If critical alerts should also go
to email, give Alertmanager a native `email_configs` receiver using the
Postmark `internal` server's SMTP credential.

## Transactional email (Postmark)

- **One Postmark server per app × environment**, e.g. `canst-staging`.
  Each has its own token, activity log and stats. Staging servers can
  run in **sandbox mode**: they accept and log mail but never deliver
  it.
- **Sending domain:** `mail.zeta-two.com`, from addresses like
  `canst@mail.zeta-two.com`. The records are in `terraform/dns.tf`:
  - **Return-Path:** `pm-bounces.mail` CNAME `pm.mtasv.net`, which gives
    SPF alignment.
  - **DMARC:** `_dmarc.mail`, `p=none` until reports are clean, then
    `quarantine`, with reports to the operator.
  - **DKIM:** a key Postmark generates, added by hand (commented
    template in the file).
- **App config:** an optional `[smtp]` section, rendered by the app's
  role when the environment has a `postmark_token`. The server token is
  both username and password:

  ```toml
  [smtp]
  host = "smtp.postmarkapp.com"
  port = 587
  username = "<server token>"
  password = "<server token>"
  from = "Canst <canst@mail.zeta-two.com>"
  ```

  Without it, the app logs each email instead. Locally, that's how to
  get a reset link.
- **App code:** a `Mailer` enum over `lettre` (SMTP, log, or an
  in-memory stub for tests). See canst's `backend/src/mail.rs`, which
  matches aoe2tm's.

## Operational messages (Apprise)

- **Service:** `k8s/notify/` runs `caronc/apprise` (pinned) as a
  Deployment, with Service
  `notify.notify.svc.cluster.local:8000` and no Ingress. It's
  stateless: `/config` is an emptyDir, with only `apps.yml` mounted from
  the `apprise-config` Secret.
- **Routing:** `notify_targets` in `ansible/group_vars/all.yml`, rendered
  by `ansible/roles/notify` into Apprise's YAML config under the key
  `apps`. Each target is an Apprise URL with the tags it receives. A
  Discord webhook URL works as-is, and email is a `mailtos://` URL (see
  the comment there). `APPRISE_CONFIG_LOCK` stops any pod reading the
  URLs back over the API. The Secret is mounted via `subPath`, which
  never sees updates, so the role restarts Apprise whenever it changes
  the Secret.

  | Tag | Today | Target state |
  | --- | --- | --- |
  | `notice` | the alerts Discord channel | Discord `#app-notices` + email |
  | `report` | the alerts Discord channel | Discord `#reports` + email |

  `overflow: split` breaks long messages up for Discord's 2000-character
  cap. Email gets the full text.
- **API:** `POST /notify/apps` with JSON `{"tag", "title", "body"}`.
  Apprise sends to every target with that tag. It answers 200 when all
  sends succeeded, and 424 when one failed or no target has the tag.
- **App config:** a `[notify]` section with no secret:

  ```toml
  [notify]
  url = "http://notify.notify.svc.cluster.local:8000/notify/apps"
  ```

- **App code:** canst's `notify::Notifier` posts in the background and
  logs an `ERROR` on failure, so the triggering request never waits on
  it or fails because of it. Dedup, if a message can repeat, is the
  app's job.

## Postmark bootstrap

One-time steps that need accounts and secrets.

1. **Account and domain.** Create a Postmark account. Add the sender
   domain `mail.zeta-two.com`. Copy its DKIM hostname and value into the
   commented `mail_dkim` resource in `terraform/dns.tf`. Run
   `make tf-plan`, then `make tf-apply`, which also creates the
   Return-Path and DMARC records. Wait for Postmark to show DKIM and
   Return-Path as verified.
2. **Servers.** Create one server per app × environment
   (`canst-staging`, sandbox mode if you don't want real delivery from
   staging) plus one `internal` server for Apprise. Postmark holds new
   accounts in a review state until approved, and sends only to the
   account's own domain until then.
3. **canst.** Vault the server token:

   ```sh
   ansible-vault encrypt_string '<token>' --name canst_staging_postmark_token --vault-password-file .vault_pass
   ```

   Then add `postmark_token: "{{ canst_staging_postmark_token }}"` to the
   staging entry in `canst_environments`, run `make ansible-apply`, and
   restart: `kubectl -n canst-staging rollout restart deploy/canst-backend`.
4. **Apprise.** Create `#reports` and `#app-notices` Discord channels
   with a webhook each, and vault the webhooks and an email URL (format
   in the comment above `notify_targets`). Point `notify_targets` at
   them and run `make ansible-apply`.

## Verification

```sh
# Apprise answers and routes (from the node):
kubectl -n notify get pods
kubectl run -n notify notify-test --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s -H 'Content-Type: application/json' \
  -d '{"tag":"notice","title":"test","body":"hello"}' http://notify:8000/notify/apps
```

- The message appears in the channels for `notice`.
- For canst: submit a prompt suggestion on staging, and a "New prompt
  suggestion" notice arrives.
- For email, once bootstrapped: request a reset for your own canst
  account. The email shows up in the Postmark server's activity log, and
  `Authentication-Results` shows SPF, DKIM and DMARC passing.
