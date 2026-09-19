# Backups

The general strategy for any stateful app in this cluster — not specific
to one app. There's no live storage redundancy here (see
[Storage](#storage) below), so backups are the *only* recovery mechanism
for app data, not a defense-in-depth layer on top of something else.

## Storage

Every PVC-backed workload (Grafana, Loki, VictoriaMetrics, and any future
stateful app) uses k3s's default `local-path` StorageClass — host-path,
tied to the node's local disk. There's no CSI driver for detachable
Hetzner Volumes installed. This was a deliberate choice to keep the
cluster simple: this is a single-node cluster, so a detachable volume
doesn't buy live failover anyway (no second node to move it to) — it would
only add network-storage durability against a local-disk failure. Revisit
once multi-node clustering exists (`docs/todo.md`).

## Strategy

`pg_dump` (or whatever an app's equivalent consistent-snapshot command is)
produces the dump; `restic` transports it to S3-compatible storage with
encryption, deduplication, and retention pruning built in. Restic is the
part that generalizes — a future non-Postgres stateful app reuses the
exact same CronJob/Ansible pattern, only its dump command differs.

Recovery target is **periodic (nightly) logical dumps**, not continuous
WAL archiving / point-in-time recovery. Worst case, you lose since the
last nightly dump. That's an acceptable RPO for a hobby-scale app; a
continuous-archiving setup (pgBackRest, WAL-G) is meaningfully more moving
parts and isn't worth it unless a specific app actually needs tighter
recovery guarantees.

## Bucket

A dedicated Hetzner Object Storage bucket, separate from the Terraform
state bucket (different retention/lifecycle, keeps arbitrary backup blobs
away from Terraform's state-locking traffic). Bootstrap steps:
[Cluster setup](cluster-setup.md#one-time-backups-bucket-bootstrap).

## Credentials

Two tiers, mirroring the existing "shared low-sensitivity credential +
per-app isolated secret" pattern already used for `ghcr_pull_token`:

- **Shared**: one S3 access/secret key pair for the bucket
  (`backups_s3_access_key`/`backups_s3_secret_key` in
  `ansible/group_vars/all.yml`), reused by every app's backup CronJob.
- **Per-app**: each app gets its own restic repository (its own path
  prefix within the bucket) and its own unique `RESTIC_PASSWORD`. Even
  though every app shares bucket-level S3 access, apps can't read, restore,
  or prune each other's backups — different path, different encryption
  key.

Wiring: `ansible/roles/backups/tasks/main.yml` loops over `backup_targets`
(`ansible/group_vars/all.yml`, empty until a real app registers) and
applies one `<app>-backup-secrets` Secret per entry, containing
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (restic reads these natively
for its S3 backend), and `RESTIC_PASSWORD`.

## Adding backups for a new stateful app

1. Generate a restic password (32 random bytes is plenty) and vault-encrypt
   it as `<app>_restic_password`:
   ```sh
   python3 -c "import secrets, base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())" \
     | ansible-vault encrypt_string --stdin-name <app>_restic_password \
       --vault-password-file ansible/.vault_pass
   ```
   Append the resulting block to `ansible/group_vars/all.yml`.
2. Add an entry to `backup_targets`:
   ```yaml
   backup_targets:
     - name: <app>
       namespace: <namespace>
       restic_password: "{{ <app>_restic_password }}"
   ```
3. `make ansible-apply` — creates `<app>-backup-secrets` in the app's
   namespace.
4. Add a CronJob to the app's own `k8s/<app>/` directory, adapted from the
   template below. `git push`; Flux reconciles it like anything else.

### CronJob template

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: <app>-backup
  namespace: <namespace>
spec:
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: backup
              image: alpine:3.22
              envFrom:
                - secretRef:
                    name: <app>-backup-secrets
              env:
                - name: RESTIC_REPOSITORY
                  value: s3:https://fsn1.your-objectstorage.com/zetatwo-infra-backups/<app>
              command:
                - sh
                - -c
                - |
                  set -eu
                  # Matches Vector's parse_app_json transform (vector.yaml)
                  # so a failure posts to Discord through the existing
                  # log-based alerting path — no new alerting infra.
                  trap 'echo "{\"level\":\"ERROR\",\"message\":\"<app> backup failed\"}"' ERR

                  apk add --no-cache postgresql16-client restic >/dev/null

                  pg_dump -h <app>-postgres -U <app> -d <app> -Fc \
                    | restic backup --stdin --stdin-filename dump.dump --host <app>

                  restic forget --prune \
                    --keep-daily 14 --keep-weekly 8 --keep-monthly 6
                  restic check
```

Adjust the `pg_dump` line (or replace it entirely) for whatever the app's
own consistent-snapshot command is — the restic/CronJob/Ansible plumbing
around it stays the same for any future stateful app.

## Restore

```sh
export RESTIC_REPOSITORY=s3:https://fsn1.your-objectstorage.com/zetatwo-infra-backups/<app>
export AWS_ACCESS_KEY_ID=...      # backups_s3_access_key
export AWS_SECRET_ACCESS_KEY=...  # backups_s3_secret_key
export RESTIC_PASSWORD=...        # <app>_restic_password

restic snapshots                       # list available backups
restic dump latest dump.dump > dump.dump
pg_restore -h <host> -U <user> -d <db> --clean dump.dump
```

Restore procedure is documented but not yet exercised in practice — do a
real restore drill (into a scratch database, not production) once the
first backup exists, and periodically after (`docs/todo.md`).
