# PMM-HA Backup & Restore (`pmm-backup.sh`)

One tool, three subcommands, documented in one place:

```
pmm-backup.sh backup  [OPTIONS]                          # back up components
pmm-backup.sh restore --backup-id <id|latest> [OPTIONS]  # restore from a backup (§8)
pmm-backup.sh list    [BACKUP_ID]                        # list / inspect backups
```

Sections 1–7 cover backup (architecture, per-component methods, chart integration,
scheduling, concurrency, metrics, CLI, operations); §8 covers restore end-to-end;
§9 lists known limitations.

---

## 1. Overview

`pmm-backup.sh backup` orchestrates backups across all PMM-HA components using their
**native backup tools**, writing to a configurable **target** (`--target`):

- **`s3`** (default, recommended): each component uploads **directly** to any
  S3-compatible object storage (AWS S3, MinIO, Ceph RGW, ...). Credentials are either
  **static keys** in a Kubernetes Secret (works everywhere) or **IRSA** (AWS EKS only,
  keyless) — see §3. Implemented and validated end-to-end for all components.
- **`shared`**: a user-provided RWX/NFS volume is mounted into the component pods and each
  lands its backup with an in-pod write (no API-server streaming). Implemented and validated.

In `s3` mode each tool writes straight to object storage — the data does not transit the
Kubernetes API server.

| Component | Tool | s3 mechanism |
|---|---|---|
| PostgreSQL | pg_dump | logical dump per database, streamed `pg_dump -Fc \| rclone rcat` to S3 |
| ClickHouse | clickhouse-backup | `upload` to S3 (`REMOTE_STORAGE=s3`, configured credentials) |
| VictoriaMetrics | vmbackup | `-dst=s3://…` direct (writes its own `backup_complete.ignore`) |
| PMM server `/srv` | tar + rclone | `pmm-backup` sidecar streams `tar -czf - /srv \| rclone rcat` to S3 |
| Encryption key | kubectl + rclone | Secret exported and uploaded to S3 |

**S3 layout** — PostgreSQL, PMM `/srv`, VictoriaMetrics and the encryption key all land under
one per-run prefix; only clickhouse-backup keeps its own native remote layout:

```
s3://<bucket>/<prefix>/postgresql/<id>/<db>.dump                     (pg_dump, custom format)
s3://<bucket>/<prefix>/pmm-server/<id>/<pod>/srv.tar.gz
s3://<bucket>/<prefix>/victoriametrics/<id>/<pod>/vm_backup_<id>/…  (+ backup_complete.ignore)
s3://<bucket>/<prefix>/encryption/<id>/pg-encryption-key.yaml
s3://<bucket>/<prefix>/manifests/<id>.json                           (per-run index)
s3://<bucket>/<prefix>/clickhouse/backup_<id>/…                          (clickhouse-backup layout)
```

A run only marks itself complete when **every selected component fully succeeds**
(fail-on-partial): a partial multi-pod backup (e.g. one vmstorage pod down) records
`status: partial` in the manifest and never moves the `latest` pointer, so a half-empty
backup can never masquerade as good (and `restore --backup-id latest` can never pick it up).

### Architecture (s3 mode)

```
        orchestrator (run manually, or on a schedule via the <release>-backup CronJob — §3a)
        ┌───────────────────────────┐
        │  pmm-backup.sh backup     │   kubectl exec carries COMMANDS only,
        └─┬────┬────┬────┬───────────┘   never bulk data
          │    │    │    │  (trigger native tools / sidecars via exec)
   ┌──────┘    │    │    └───────────────┐
   ▼           ▼    ▼                    ▼
 PG primary  CH pod  vmstorage-0/1/2   pmm-ha-0/1/2
 pg_dump     ch-     vmbackup          pmm-backup
 (-Fc|rclone) backup (-dst=s3)         (rclone) sidecar
   │           │       │                 │
   │  each authenticates with the configured credentials (static keys or IRSA)
   └───────────┴───────┴─────────────────┘
                       │  direct PUT (multipart, retries)
                       ▼
            ┌───────────────────────┐
            │   S3 bucket / prefix   │
            └───────────────────────┘
```

Authentication — the target is **any S3-compatible object storage** (AWS S3, MinIO, Ceph
RGW, ...); pick one of two credential models (see §3 for setup):

- **Static keys** (works everywhere): an access/secret key pair stored in a Kubernetes
  Secret and injected into every uploading pod. The only option on non-AWS storage.
- **IRSA** (AWS EKS only, keyless): each uploading pod runs under a ServiceAccount
  annotated with an IAM role (`eks.amazonaws.com/role-arn`); the EKS pod-identity webhook
  injects a web-identity token that the AWS SDK credential chain picks up.

For non-AWS endpoints set `centralBackupStorage.s3.endpoint` (and `provider` for the
rclone-based clients); the orchestrator passes the endpoint through to every tool,
including `-customS3Endpoint` for vmbackup/vmrestore.

---

## 2. Components and Backup Methods

### PostgreSQL

- **Tool**: `pg_dump` (logical backup). PMM's PostgreSQL holds config/inventory/Grafana
  metadata only (the metrics live in VictoriaMetrics/ClickHouse), so it's small and a
  logical dump is the right fit — and unlike a physical pgBackRest repo it is **not tied to
  a cluster identity/stanza**, so it restores into any namespace/cluster trivially.
- **How**: `kubectl exec` into the primary pod (container `database`), discover the
  application databases (everything except templates and the empty `postgres` db), and run
  `pg_dump -Fc` per database via local peer auth as the `postgres` superuser.
- **Where stored**: one custom-format file per database under this component's prefix —
  `s3://<bucket>/<prefix>/postgresql/<id>/<db>.dump` (s3, streamed `pg_dump | rclone rcat`
  by the backup-tools pod's own rclone) or `<central>/postgresql/<id>/<db>.dump`
  (shared, `pg_dump` streamed onto the mounted volume). For PMM that's typically
  `pmm-managed` + `grafana`.
- **Operator pgBackRest**: untouched. The Percona/Crunchy operator keeps its own local
  `repo1` for replica bootstrap / HA — the orchestrator does **not** use or require it.
- **Trade-off**: no point-in-time recovery (you restore to the last dump). Acceptable for
  PMM's config database.

### ClickHouse

- **Tool**: clickhouse-backup (Altinity sidecar)
- **How**: `kubectl exec` into the ClickHouse pod, issues SQL commands against the `system.backup_actions` table to trigger `clickhouse-backup create`
- **Where stored** (s3): `clickhouse-backup create` makes near-zero-space hardlinks on the pod, then `upload` pushes them to S3 (`REMOTE_STORAGE=s3`, `S3_PATH=<prefix>/clickhouse`, configured credentials — static keys or IRSA), then `delete local`. Objects land at `s3://<bucket>/<prefix>/clickhouse/backup_<id>/…`.
- **Incremental** (`--ch-backup-type incremental`): the local `create` is always a full
  hardlink snapshot; the diff happens at **upload** time — `upload
  --diff-from-remote=<previous-remote-backup> <name>` (flags before the positional name).
  Only changed parts are uploaded; `list remote` shows the linkage as `+<prev>`. Verified
  against clickhouse-backup 2.8.0 (`create --diff-from-remote` applies only to
  embedded/object-disk backups, which we don't use). Incremental runs do NOT move the
  `latest` pointer (single-component scope).
- **Prerequisite**: The `clickhouse-backup` sidecar must be running (check for `system.backup_actions` table)

### VictoriaMetrics

- **Tool**: vmbackup (sidecar in vmstorage pods)
- **How**: For each vmstorage pod, `kubectl exec` into the `vmbackup` sidecar, creates a snapshot and runs `vmbackup-prod -dst=<target>`
- **Where stored** (s3): `vmbackup -dst=s3://<bucket>/<prefix>/victoriametrics/<id>/<pod>/vm_backup_<id>` uploads the snapshot **directly to S3** (configured credentials, `AWS_REGION` from the pod env; custom endpoints via `-customS3Endpoint`). vmbackup writes `backup_complete.ignore` at the destination as its **final** step, so the completion marker that `vmrestore` requires is always present.
- **Note**: per-pod backups; the run is only marked complete if **every** vmstorage pod succeeds.

### PMM Server `/srv`

- **Tool**: `tar` + `rclone` in the `pmm-backup` sidecar
- **How**: PMM pods are discovered by label (`app.kubernetes.io/component=pmm-server`); for each, `kubectl exec` into the `pmm-backup` sidecar and run `tar -czf - -C / srv | rclone rcat --s3-no-check-bucket s3:<bucket>/<prefix>/pmm-server/<id>/<pod>/srv.tar.gz`. The exec carries only the command; the tarball streams sidecar→S3.
- **Where stored** (s3): `s3://<bucket>/<prefix>/pmm-server/<id>/<pod>/srv.tar.gz`. After upload the script verifies the object exists (`rclone size`) and treats an empty/missing result as a failure.
- **Prerequisite**: the `pmm-backup` rclone sidecar (added by the chart in `s3` mode) running in the PMM pods.

### Encryption Key

- **Tool**: `kubectl get secret` + rclone
- **How**: Exports the `pg-encryption-key` Kubernetes Secret to clean YAML
- **Tied to**: Only backed up when `--postgresql` is selected (it's a PostgreSQL encryption key)
- **Where stored** (s3): uploaded to `s3://<bucket>/<prefix>/encryption/<id>/pg-encryption-key.yaml` (SHA256 recorded). Note: the key is stored in the **same bucket** as the data — tighten with a separate prefix/restricted IAM if required.

---

## 3. Helm Chart Integration

The backup infrastructure is provisioned by the PMM-HA Helm chart when
`centralBackupStorage.enabled: true` in `values.yaml`. The target mode is set with
`centralBackupStorage.mode` (`s3` default, or `shared`).

### Backup Target & S3 Configuration

```yaml
centralBackupStorage:
  enabled: true
  mode: s3                       # s3 (default) | shared
  s3:
    bucket: "my-bucket"
    region: "eu-central-1"
    endpoint: ""                 # empty for AWS; set for S3-compatible (e.g. http://minio.minio.svc:9000)
    provider: "AWS"              # rclone provider: AWS | Minio | Ceph | Other
    prefix: "pmm-ha"             # key namespace under the bucket

    ## Credentials — set ONE of the two:
    ## (A) static keys (any S3-compatible storage): Secret with access-key/secret-key
    existingSecret: ""           # e.g. "pmm-s3-secret"
    # existingSecretKeys:        # which keys inside the Secret hold the credentials
    #   accessKey: "access-key"
    #   secretKey: "secret-key"
    ## (B) IRSA (AWS EKS only, keyless):
    irsaRoleArn: ""              # e.g. arn:aws:iam::<acct>:role/pmm-ha-backup-s3
    serviceAccountName: "pmm-ha-backup-s3"   # SA for operator-managed pods (IRSA-annotated on AWS)
  client:
    image:                       # rclone — PMM /srv sidecar + ad-hoc orchestrator uploads
      registry: docker.io
      repository: rclone/rclone
      tag: "1.74.3"
  tools:
    image:                       # backup-tools Deployment (kubectl + orchestrator scripts)
      registry: docker.io
      repository: alpine/kubectl
      tag: "1.36.3"              # pinned; see values.yaml
```

**Configure `centralBackupStorage.s3` once.** ClickHouse and VictoriaMetrics have their own
`backup.s3` blocks (`clickhouse.backup.s3`, `victoriaMetrics.vmstorage.backup.s3`), but their
`existingSecret` (+ `existingSecretKeys`), `endpoint`, and `region` all **fall back to the
central `centralBackupStorage.s3` values when left empty**. So on a MinIO/Ceph (or any static-key)
install you set the credentials, endpoint, and region ONCE centrally; each component block only
needs `enabled: true` (plus an optional per-component `bucket`/`path` — those are the only
per-component settings). Set a value in a component block only to point that component at a
different secret/endpoint/region. See the simplified example under *S3 Authentication Setup* below.

In `s3` mode the chart wires each component's credentials — static keys (`existingSecret`)
or, on AWS, IRSA:

| Component | Chart wiring |
|---|---|
| PMM `/srv` | adds the `pmm-backup` rclone sidecar to the PMM StatefulSet; creds via `centralBackupStorage.s3.existingSecret` or the PMM SA's `irsaRoleArn` annotation |
| VictoriaMetrics | `VMCluster.spec.serviceAccountName` = backup SA; vmbackup gets `AWS_REGION` + creds (`existingSecret` or IRSA chain) |
| ClickHouse | CHI pod-template `serviceAccountName` = backup SA; clickhouse-backup gets `REMOTE_STORAGE=s3` + `S3_PATH` + creds (`existingSecret` or IRSA chain) |
| PostgreSQL | nothing PG-specific — `pg_dump` streams through the `pmm-backup` rclone sidecar, which already has the S3 credentials. No pgBackRest S3 repo wiring. |

### S3 Authentication Setup (one-time, per cluster)

**Option A — static keys (any S3-compatible storage: MinIO, Ceph RGW, Wasabi, AWS, ...).**
No IAM roles or cloud-specific identity involved: the storage admin creates a bucket and
an access-key/secret-key pair with read/write/list/delete on it, and you store the pair in
a Kubernetes Secret in the PMM namespace:

```bash
kubectl create secret generic pmm-s3-secret -n <namespace> \
  --from-literal=access-key=<ACCESS_KEY> --from-literal=secret-key=<SECRET_KEY>
```

```yaml
centralBackupStorage:
  s3:
    bucket: "pmm-backups"
    endpoint: "http://minio.minio.svc:9000"   # empty for AWS S3
    provider: "Minio"                         # AWS | Minio | Ceph | Other
    region: "us-east-1"                       # many S3-compatibles accept any value
    existingSecret: "pmm-s3-secret"           # credentials — inherited by CH & VM below
clickhouse:
  backup:
    s3: { enabled: true }        # bucket/path optional; secret+endpoint+region inherited from central
victoriaMetrics:
  vmstorage:
    backup:
      s3: { enabled: true }      # secret+endpoint+region inherited from central
```

The ClickHouse and VictoriaMetrics blocks need only `enabled: true` — their credentials,
endpoint, and region come from `centralBackupStorage.s3` (see *Configure once* above). Add a
`bucket`/`endpoint`/`existingSecret` there only to override for that component.

For restores you normally pass nothing extra — inside the backup-tools pod the chart already
exports the secret name, endpoint, provider and region as env (see *Flag-less operation*), so
`pmm-backup.sh restore --backup-id latest` just works. Pass `--s3-secret` / `--s3-endpoint` /
`--s3-provider` explicitly only for an ad-hoc or cross-prefix run that differs from the install.

**Option B — IRSA (AWS EKS only): keyless.** Pods authenticate via an IAM role assumed
through the cluster's OIDC provider — **no access keys in the cluster**:

1. **IAM policy** granting the bucket `s3:ListBucket`/`GetObject`/`PutObject`/`DeleteObject`
   (no `CreateBucket` needed).
2. **IAM role** whose trust policy allows the cluster OIDC provider for the backup
   ServiceAccounts (`system:serviceaccount:<ns>:pmm-ha-backup*` and the PMM server SA;
   scope tighter for prod).
3. Set `centralBackupStorage.s3.irsaRoleArn`. The chart annotates the SAs
   (`eks.amazonaws.com/role-arn`); the EKS pod-identity webhook injects a web-identity
   token that the AWS SDK / rclone pick up automatically.
4. The STS regional endpoint must be ACTIVE in the cluster's region (IAM console →
   Account settings) — a deactivated region fails every credential exchange with
   `403 RegionDisabledException`.

> rclone is invoked with `--s3-no-check-bucket` (works without bucket-creation rights).
> PostgreSQL needs no credentials of its own — its `pg_dump` is streamed to S3 through the
> `pmm-backup` rclone sidecar.

### Helm Template Files

| File | Purpose |
|---|---|
| `templates/backup-tools.yaml` | backup-tools Deployment, ServiceAccount, Role, RoleBinding; projects target + S3 settings into the pod env |
| `templates/backup-scripts-configmap.yaml` | orchestrator + scheduler scripts (`pmm-backup.sh`, `cron-backup.sh`) rendered into a ConfigMap, mounted at `/usr/local/bin` |
| `templates/backup-cronjob.yaml` | scheduled-backup CronJob `<release>-backup` (conditional on `schedule.enabled`; see §3a) |
| `templates/backup-s3-serviceaccount.yaml` | IRSA SA for operator-managed pods (created when `irsaRoleArn` is set) |
| `templates/statefulset.yaml` | PMM StatefulSet — `pmm-backup` rclone sidecar + S3 credentials wiring (s3 mode) |
| `templates/vmcluster.yaml` | VMCluster — backup `serviceAccountName` + vmbackup s3 env/creds |
| `templates/clickhouse-cluster.yaml` | CHI — backup `serviceAccountName` + clickhouse-backup s3 env/creds |
| `templates/central-backup-pvc.yaml` | PVC for the `shared` target (conditional) |
| `templates/vmagent.yaml` | VMAgent scrape jobs for backup metrics |
| `pg-db` values | `repo1` (local, operator HA only) — no pgBackRest S3/RWX repo; PG is backed up with `pg_dump` |

### Storage Options (`shared` mode)

These apply to **`mode: shared`** only. In **`s3` mode no shared volume is needed** —
backups go straight to the bucket; the backup-tools pod keeps only a small volume for
logs/metrics.

The shared volume is mounted into the component pods that write directly (vmstorage, the
clickhouse-backup sidecar, PMM) **and** the backup-tools pod simultaneously, so it **must be
`ReadWriteMany` (RWX)**. (PostgreSQL needs no mount — its `pg_dump` is streamed through the
orchestrator onto the backup-tools mount.) EBS / `gp3` (ReadWriteOnce) cannot be used. Provide an RWX backend
yourself — EFS, an NFS server, `nfs-subdir-external-provisioner`, etc.; the chart does not
provision RWX storage for you.

**Option 1: Bring-your-own RWX PVC (recommended)**

```yaml
centralBackupStorage:
  enabled: true
  mode: shared
  existingClaim: "my-rwx-backup-pvc"   # a ReadWriteMany PVC you created
```

**Option 2: Direct NFS mount**

```yaml
centralBackupStorage:
  enabled: true
  mode: shared
  nfs:
    enabled: true
    server: "10.0.1.50"
    path: "/exports/pmm-backups"
```

When `nfs.enabled` is true, both PVC creation and `existingClaim` are ignored.

**Option 3: Chart-created PVC (only with an RWX storage class)**

```yaml
centralBackupStorage:
  enabled: true
  mode: shared
  storageSize: 100Gi
  storageClassName: "efs-sc"     # MUST support ReadWriteMany
  accessMode: ReadWriteMany
```

The chart creates a PVC named `<release>-central-backup`; only works if the storage class
provisions RWX volumes.

**Priority**: `nfs.enabled` > `existingClaim` > chart-created PVC.

**`accessMode` / `storageClassName` defaults.** Leave `accessMode` empty and the chart derives
it from `mode`: `ReadWriteMany` for `shared`, `ReadWriteOnce` for `s3` (where the volume only holds
the backup-tools logs/metrics). Set it explicitly to override. An empty `storageClassName` uses the
cluster's default storage class; set one that actually exists (a non-existent class leaves the PVC
`Pending` and blocks the install).

### Pod Startup

backup-tools runs as a **Deployment** (`replicas: 1`, `strategy: Recreate` — the
logs/metrics volume is typically RWO) using a pinned `alpine/kubectl` image
(`centralBackupStorage.tools.image`, default tag pinned in values.yaml). The scripts
(`pmm-backup.sh` and the scheduler's `cron-backup.sh`)
are **shipped by the chart** (`files/*.sh`), rendered into the `<release>-backup-scripts`
ConfigMap and mounted into `/usr/local/bin/` — no manual copying, and a checksum annotation
rolls the pod whenever the scripts change.
On startup the container:

1. Creates the metrics directory (`/backups/.metrics/`)
2. Initializes placeholder `.prom` files for each component
3. Starts five netcat listeners in the background (ports 9091, 9092, 9093, 9095 for the four backup components and 9094 for restore) to serve per-component metrics
4. Sleeps indefinitely, waiting for backup or restore script invocations

Two operational notes:

- The pod template carries `karpenter.sh/do-not-disrupt: "true"`: even though the
  Deployment recreates an evicted pod, a disruption would still kill any backup/restore
  running inside it — so consolidation-driven disruption (Karpenter / EKS Auto Mode) is
  opted out; the annotation is harmless on other platforms.
- The orchestrator scripts require **jq** (manifest generation/merging/parsing, secret
  export). Preflight checks it and auto-installs via `apk` on Alpine; other images must
  ship it. `nc` (metrics listeners) likewise gets a fallback install at startup.

Run the tools via the Deployment (the pod name is generated):

```bash
kubectl exec -n <namespace> deploy/<release>-backup-tools -- pmm-backup.sh --help
```

### RBAC

The chart creates a ServiceAccount (`<release>-backup-sa`) with a Role granting:

- `get`, `list`, `create`, `delete` on `pods`, `pods/log`, `pods/exec` (delete for VM pod restart on restore)
- `get`, `list`, `create`, `update`, `patch` on `secrets` (patch for encryption key restore)
- `get`, `list` on `persistentvolumeclaims`
- `get`, `list` on `services`
- `get` on `namespaces`
- **Restore**: `get`, `list`, `patch` on `vmclusters` and `statefulsets` (scale down/up); `pods/exec` for `pg_restore` / `clickhouse-backup` / `vmrestore` / `/srv` tar. *(No `perconapgrestores`/`perconapgclusters` access needed — PostgreSQL restores via `pg_restore`.)*
- **Scheduled backups**: `get`, `list` on `deployments` — the CronJob resolves `deploy/<release>-backup-tools` to a pod to `kubectl exec` into.

---

## 3a. Scheduled Backups (CronJob)

Backups can run on a schedule via a Kubernetes CronJob — **disabled by default**. Enable it under
`centralBackupStorage.schedule`. Restore is never scheduled; it stays a deliberate manual action.

```yaml
centralBackupStorage:
  schedule:
    enabled: false            # create the <release>-backup CronJob
    cron: "0 2 * * *"         # cron expression, cluster timezone (default: daily 02:00)
    retentionDays: 7          # prune backups older than N days (passed as --retention)
    components: []            # [] = all four; or e.g. ["--postgresql","--clickhouse"] or ["--skip-victoriametrics"]
    extraArgs: []             # extra `pmm-backup.sh backup` args
    startingDeadlineSeconds: 600    # skip a run that can't start within N seconds
    activeDeadlineSeconds: 21600    # hard cap on one run (6h default; MUST exceed the real backup duration)
    successfulJobsHistoryLimit: 3
    failedJobsHistoryLimit: 3
```

The chart renders a CronJob `<release>-backup` (`concurrencyPolicy: Forbid`, `backoffLimit: 3`).
Target and all S3 settings come from the same `centralBackupStorage.s3` values as manual runs —
nothing S3-specific is repeated in the schedule block. In `s3` mode the bucket is required, so the
chart fails the render if `schedule.enabled` is set with an empty `centralBackupStorage.s3.bucket`.

**How a run executes.** The CronJob does **not** mount the central volume in its own pod (that would
Multi-Attach the RWO logs PVC held by the always-on backup-tools Deployment). Instead its trigger
pod `kubectl exec`s the shipped `cron-backup.sh` **into** the backup-tools pod, reusing that pod's
volume, scripts and env. `cron-backup.sh`:

1. Starts `pmm-backup.sh backup` **detached** (`setsid`/`nohup`) so the backup survives the
   trigger's exec stream dropping — an apiserver/network blip no longer aborts a multi-hour run —
   recording the orchestrator's exit code in a status file.
2. Polls that status file and reports the result as the Job's exit code.
3. On a Job retry, **re-attaches** to the same in-flight run (keyed by `--run-id` = the Job name)
   instead of starting a second orchestrator that would collide on the per-component locks.
4. If the backup-tools pod itself dies mid-run (eviction / OOM / rollout) so no status is ever
   written, detects the stalled run (its log stops advancing) and **restarts** it on the next
   trigger rather than polling a never-arriving status forever.

`concurrencyPolicy: Forbid` prevents overlapping scheduled runs; the orchestrator's per-component
locks are the second line of defense against any other overlap (e.g. a manual run during a
scheduled one — the later run declines the busy component). See §4.

**Tuning** — environment variables read by `cron-backup.sh` (override by adding them to the
backup-tools Deployment; rarely needed): `CRON_BACKUP_POLL_INTERVAL` (status poll seconds,
default 30), `CRON_BACKUP_STALL_MIN` (minutes of no log progress before a run is treated as
crashed, default 15), `CRON_BACKUP_MARKER_RETENTION_DAYS` (age out per-run marker/log files after
N days, default 7).

Trigger a run off-schedule (e.g. to test) with a manual Job from the CronJob:

```bash
kubectl create job --from=cronjob/<release>-backup <release>-backup-manual -n <namespace>
```

---

## 4. Concurrency Model

The script supports running separate component backups in parallel — e.g. a manual
`--postgresql` run alongside another that does `--clickhouse`. The chart's scheduled CronJob runs
a single **full** backup (all components); per-component locks + `concurrencyPolicy: Forbid` keep
concurrent runs from clobbering each other.

### Backup ID Grouping

When running components concurrently, use `--backup-id` to group them into the same backup directory:

`date -u`, not `date`: an auto-generated id is UTC (see §4), and `backup_id_epoch` converts any
id back as UTC. A local-time `--backup-id` is therefore mis-aged by your offset — west of UTC it
looks *older* than it is and can be purged before its retention window is up.

```bash
BACKUP_ID=$(date -u +%Y%m%d-%H%M%S)
pmm-backup.sh backup --postgresql      --backup-id "$BACKUP_ID" &
pmm-backup.sh backup --clickhouse      --backup-id "$BACKUP_ID" &
pmm-backup.sh backup --victoriametrics --backup-id "$BACKUP_ID" &
wait
```

Without `--backup-id`, each process auto-generates its own timestamp, resulting in separate directories. With `--backup-id`, all three write under the same backup id (e.g. `/backups/postgresql/backup_20260223-150001/`, `/backups/clickhouse/backup_20260223-150001/`, …), and one shared `manifests/backup_20260223-150001.json` records the set. This makes it clear which backups belong together for a coordinated restore.

In concurrent mode (single component with `--backup-id`), each process writes its own
per-component log file (`logs/backup_<id>_postgresql.log`) to avoid conflicts; run status
is consolidated in the shared `manifest.json` via the merge below.

**Manifest merging**: each finishing process performs a read-merge-write of
`manifests/<id>.json`, serialized by a `Lease` named `pmm-backup-manifest-<id>`: it fetches
the manifest written so far, carries over the component entries it does not own, and
recomputes the overall status from the merged set. The last finisher therefore
produces a manifest listing ALL components of the group — no last-writer-wins clobbering.
The merge is jq-based; manifests are plain JSON with no format/indentation contract.

If that lease cannot be taken within 60s the manifest is still written, unmerged — the data is
already uploaded at that point, and refusing to write the index would be worse. A run that
cannot read the existing manifest and cannot positively prove it absent refuses to overwrite
it instead, so a sibling's entries are never erased.

### Per-Component Locking

Each component's lock is a Kubernetes `Lease` in the release namespace:

```
kubectl get leases -n <ns> -l app.kubernetes.io/component=pmm-backup-lock

pmm-backup-clickhouse
pmm-backup-pmm-server
pmm-backup-postgresql
pmm-backup-victoriametrics
pmm-backup-manifest-<backup-id>     # only while a manifest merge is in flight
```

The locks are **cluster-wide in reach** — that is the point. (The Lease objects themselves are
namespaced, and live in the release namespace; they serialize every client that can reach *this*
namespace's API, not runs in other namespaces.) They used to be a
`mkdir /backups/.backup_<component>.lock` plus a `kill -0 <pid>` liveness check, and that only
excludes processes sharing both a filesystem and a PID namespace — while the thing being
protected (a database in the cluster) is shared by everything with `kubectl` access. A restore
run from a laptop and the CronJob's backup in the pod could therefore write the same database
at the same time, which is exactly what the locking exists to prevent.

A `Lease` is the mechanism Kubernetes provides for this:

| Concern | How |
|---|---|
| Acquisition | `kubectl create` — atomic; `AlreadyExists` is the contention signal. Never `apply`, which would take over a live lock. |
| Liveness | `spec.renewTime` is refreshed every `LOCK_RENEW_SECONDS` (60) by a background renewer for as long as the run lives. |
| Expiry | A lease is takeable only once `renewTime` is older than `leaseDurationSeconds` (`LOCK_LEASE_SECONDS`, 900). |
| Takeover | `kubectl replace` with the `resourceVersion` that was observed — optimistic concurrency, so exactly one of two racing takeovers wins. |
| Release | `kubectl delete`, but only if `holderIdentity` is still ours: a run that aborted *because* someone else holds the lock must not delete that live lock. |
| Unknown age | If `renewTime` cannot be parsed, the answer is "cannot tell", not "expired" — the lock is left alone. Stealing a live lock means two writers on one database. |

All timestamps are UTC and are converted arithmetically rather than through `date -d`, which
has no portable way to parse a string as UTC and does not exist in that form on BSD/macOS at
all. A local-time conversion made a lease written a second ago look 3 hours stale in
`TZ=Europe/Bucharest` (instant, silent takeover of a live lock) and made every lease
un-expirable west of UTC.

The renewer stops when the orchestrator does, including when the orchestrator is killed
abruptly: it re-checks that its parent process is alive before every renewal, and has a
`LOCK_RENEWER_MAX_SECONDS` (86400) backstop. Without that check a SIGKILL'd or OOM-killed run
left a renewer patching `renewTime` for the life of the backup-tools pod, and every later
backup and restore aborted on a lock whose holder no longer existed.

### Lock Acquisition Order

Locks are always acquired in **alphabetical order** (clickhouse, pmm-server, postgresql, victoriametrics) to prevent deadlocks when invocations select components in different orders. The restore orchestrator acquires the **same** lock names, so a restore can't race a backup of the same component. (Restore also always holds the `pmm-server` lock, since it scales PMM down/up.)

### What Can Run Concurrently

| Scenario | Allowed? |
|---|---|
| `--postgresql` + `--clickhouse` | Yes |
| `--postgresql` + `--victoriametrics` | Yes |
| `--clickhouse` + `--victoriametrics` | Yes |
| All three as separate processes | Yes |
| Two `--postgresql` runs | No (second is blocked) |
| `--postgresql` + full backup (no flags) | No (full backup acquires all locks) |

### Shared Resource Safety

- **Log files**: When using `--backup-id` with a single component, each process gets a component-suffixed log file (`backup_<id>_postgresql.log`). Without `--backup-id`, each run uses a unique timestamp so logs never collide.
- **Backup subdirectories**: With `--backup-id`, concurrent processes share the same `backup_<id>/` parent directory but write only to their own component subdirectory (`postgresql/`, `clickhouse/`, etc.). `mkdir -p` is safe for concurrent use.
- **No consolidation**: each component writes its payload to the final target from inside its own pod; per-run status is consolidated only in the merged `manifest.json`.
- **Metrics**: Each component writes to its own `.prom` file atomically (write to `.tmp`, then `mv`).
- **Manifest / latest pointer**: written once at the end of a run under the
  `pmm-backup-manifest-<id>` `Lease` (concurrent `--backup-id` processes merge, see §4). The `latest` pointer only moves
  when the (merged) manifest is a **complete, full-scope** backup — all four core
  components present and successful. Single-component or partial runs never move it, so
  `restore --backup-id latest` cannot silently resolve to (e.g.) an ad-hoc ClickHouse-only
  incremental run.

---

## 5. Metrics and Monitoring

### Metric Files

After each backup run, per-component Prometheus metrics files are written to `/backups/.metrics/` on the PVC:

```
/backups/.metrics/postgresql_metrics.prom
/backups/.metrics/clickhouse_metrics.prom
/backups/.metrics/victoriametrics_metrics.prom
```

Files are written atomically (write to temp file, then `mv`) to prevent partial reads during scraping.

### Metric Names

All metrics use the `pmm_ha_backup_` prefix:

| Metric | Type | Description |
|---|---|---|
| `pmm_ha_backup_last_success` | gauge | Whether the last backup succeeded (1=yes, 0=no) |
| `pmm_ha_backup_last_timestamp_seconds` | gauge | Unix timestamp of backup completion |
| `pmm_ha_backup_last_duration_seconds` | gauge | Backup duration in seconds |
| `pmm_ha_backup_last_size_bytes` | gauge | Backup size in bytes |

Each metric includes labels: `component` (postgresql/clickhouse/victoriametrics/pmm-server) and `namespace`. All four components, PMM `/srv` included, are served and scraped — see the port table below.

### HTTP Serving

The backup-tools pod runs five netcat listeners, each serving one metrics file:

| Port | Component | Served File |
|---|---|---|
| 9091 | PostgreSQL | `postgresql_metrics.prom` |
| 9092 | ClickHouse | `clickhouse_metrics.prom` |
| 9093 | VictoriaMetrics | `victoriametrics_metrics.prom` |
| 9094 | Restore | `restore_metrics.prom` |
| 9095 | PMM `/srv` | `pmm-server_metrics.prom` |

Port 9095 was added late: the orchestrator has always written `pmm-server_metrics.prom`, but
nothing served or scraped it, so a `/srv` backup that failed for **every** PMM pod was invisible
in Prometheus while the other three components reported correctly.

### VMAgent Scrape Configuration

Five scrape jobs are defined in `vmagent.yaml` (conditionally enabled when `centralBackupStorage.enabled`):

- `backup-postgresql` -- scrapes port 9091
- `backup-clickhouse` -- scrapes port 9092
- `backup-victoriametrics` -- scrapes port 9093
- `backup-pmm-server` -- scrapes port 9095
- `backup-restore` -- scrapes port 9094 (restore metrics)

All use `kubernetes_sd_configs` with `role: pod`, filtering on label `app.kubernetes.io/component: backup-tools` and the corresponding container port number. The three original backup jobs scrape every 60s; `backup-pmm-server` and `backup-restore` scrape every 30s.

### Alerting Examples

With metrics stored in VictoriaMetrics, create alerts for:

```
# No backup in the last 24 hours
time() - pmm_ha_backup_last_timestamp_seconds{component="postgresql"} > 86400

# Last backup failed
pmm_ha_backup_last_success{component="postgresql"} == 0

# Backup took too long (over 5 minutes)
pmm_ha_backup_last_duration_seconds{component="victoriametrics"} > 300

# Suspiciously small backup (possible empty/corrupt)
pmm_ha_backup_last_size_bytes{component="clickhouse"} < 1000
```

---

## 6. CLI Reference

### Usage

```
pmm-backup.sh <COMMAND> [OPTIONS]
```

A subcommand is **required** — there is deliberately no default operation, because a bare
invocation carrying restore-shaped flags would otherwise run a destructive backup over the
id being restored.

Commands:

| Command | Description |
|---|---|
| `backup` | Back up the selected components. |
| `restore` | Restore the selected components from a backup (see §8). |
| `list [BACKUP_ID]` | List backups, or — given a `BACKUP_ID` — show every file/location belonging to that one backup (read from its `manifest.json`). Reuses the same `--s3-bucket` / `--s3-prefix` / `--namespace` flags. |

With no component flags, all four components are backed up (PostgreSQL, ClickHouse, VictoriaMetrics, PMM server `/srv`). Specifying any `--postgresql`, `--clickhouse`, `--victoriametrics`, or `--pmm-server` flag switches to selective mode (only specified components run).

See [Listing Backups](#listing-backups-s3-mode) for the manifest/catalog details.

### Flags

> **Flag-less by default.** Inside the backup-tools pod the chart pre-populates the target and
> every S3 setting from `values.yaml` as env (see *Environment Variables* below), so
> `pmm-backup.sh backup` runs with **no `--s3-*`/`--target` flags** — they default to the
> install. Pass a flag only to override for an ad-hoc run.

| Flag | Description | Default |
|---|---|---|
| `-h`, `--help` | Show help message | |
| `-v`, `--verbose` | Show detailed backup tool output | false |
| `--dry-run` | Print the commands that would run, without executing them | false |
| `-n`, `--namespace NS` | Kubernetes namespace | demo |
| `-d`, `--backup-dir DIR` | Backup directory for logs/metadata | /backups |
| `-r`, `--retention DAYS` | Number of days to retain backups | 7 |
| `--backup-id ID` | Shared identifier for grouping concurrent runs | auto (timestamp) |
| `--postgresql` | Include PostgreSQL in backup | |
| `--clickhouse` | Include ClickHouse in backup | |
| `--victoriametrics` | Include VictoriaMetrics in backup | |
| `--pmm-server` | Include PMM server `/srv` in backup | |
| `--skip-postgresql` | Exclude PostgreSQL from all-component run | |
| `--skip-clickhouse` | Exclude ClickHouse from all-component run | |
| `--skip-victoriametrics` | Exclude VictoriaMetrics from all-component run | |
| `--skip-pmm-server` | Exclude PMM server `/srv` from all-component run | |
| `--skip-encryption-key` | Skip the PMM encryption key (captured with PostgreSQL by default) | |
| `--ch-backup-type TYPE` | ClickHouse backup type: full or incremental | full |
| `--ch-secret NAME` | Kubernetes secret for ClickHouse credentials | pmm-secret |
| `--target MODE` | Backup target: `s3` or `shared` | s3 |
| `--s3-bucket BUCKET` | S3 bucket name (required for `s3`; chart-set via `S3_BUCKET`, so optional inside backup-tools) | |
| `--s3-endpoint URL` | S3 endpoint (empty for AWS; set for S3-compatible/MinIO) | |
| `--s3-region REGION` | S3 region | us-east-1 |
| `--s3-prefix PREFIX` | Key namespace under the bucket | `<namespace>/pmm-ha` (matches what the chart projects) |
| `--shared-mount-path PATH` | RWX mount path inside pods (`--target shared`) | /central |

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `BACKUP_DIR` | Backup directory | /backups |
| `BACKUP_RETENTION` | Retention in days | 7 |
| `CENTRAL_BACKUP_PATH` | Central storage path (set by Helm) | |
| `METRICS_DIR` | Directory for .prom metrics files | /backups/.metrics |
| `KUBECTL_EXEC_TIMEOUT` | Timeout (seconds) for backup commands | 600 |
| `KUBECTL_STATUS_TIMEOUT` | Timeout (seconds) for status queries | 30 |
| `RCLONE_TIMEOUT` | Wall clock (seconds) for one rclone read or delete | `KUBECTL_STATUS_TIMEOUT` |
| `RCLONE_PURGE_TIMEOUT` | Wall clock (seconds) for one recursive rclone purge | 300 |
| `RCLONE_IO_TIMEOUT` / `RCLONE_CONNECT_TIMEOUT` | rclone's own idle-IO / connect bounds, applied to every call including streams | 60 / 15 |
| `LOCK_LEASE_SECONDS` / `LOCK_RENEW_SECONDS` | Component lock lease duration / renewal interval | 900 / 60 |
| `LOCK_RENEWER_MAX_SECONDS` | Backstop lifetime for the lease renewer | 86400 |
| `CH_SECRET_NAME` | Kubernetes secret for ClickHouse | pmm-secret |
| `CH_CREATE_TIMEOUT` / `CH_UPLOAD_TIMEOUT` | Max seconds to wait for clickhouse-backup create / upload | 300 / 600 |
| `NAMESPACE` | Kubernetes namespace (the chart sets this to the release namespace in backup-tools) | demo |
| `BACKUP_TARGET` | Target mode: `s3` or `shared` (set by Helm from `centralBackupStorage.mode`) | s3 |
| `S3_BUCKET` | S3 bucket (required for `s3`; set by Helm) | |
| `S3_REGION` / `S3_ENDPOINT` / `S3_PREFIX` | S3 region / endpoint / key prefix (set by Helm) | us-east-1 / / pmm-ha |
| `SHARED_MOUNT_PATH` | RWX mount path inside pods (`shared` mode; set by Helm) | /central |
| `RCLONE_REMOTE` | rclone remote name (configured via `RCLONE_CONFIG_*`) | s3 |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | S3 static keys (required on non-AWS S3-compatible storage; on AWS, IRSA is the keyless alternative) | |

The chart also injects these into the backup-tools pod from `centralBackupStorage.s3.*`. They are
consumed by **`pmm-backup.sh restore`** (its temp vmrestore / `/srv` pods), so a restore inside
the pod needs no flags:

| Variable | Description | Default |
|---|---|---|
| `S3_PROVIDER` | rclone provider profile (`AWS`/`Minio`/`Ceph`/`Other`) projected into the restore temp pods' rclone config | AWS |
| `S3_SECRET_NAME` | Static-key Secret name injected into restore temp pods (empty ⇒ IRSA / SA credential chain) | |
| `S3_SECRET_ACCESS_KEY_KEY` / `S3_SECRET_SECRET_KEY_KEY` | Keys within that Secret | access-key / secret-key |
| `S3_SERVICE_ACCOUNT` | ServiceAccount for restore temp pods (IRSA SA, or one carrying imagePullSecrets) | pmm-ha-backup-s3 |

### Examples

```bash
# Full backup of all components
pmm-backup.sh backup --namespace demo

# PostgreSQL only
pmm-backup.sh backup --namespace demo --postgresql

# PostgreSQL and ClickHouse together
pmm-backup.sh backup --namespace demo --postgresql --clickhouse

# Run all three concurrently, grouped into the same backup directory.
# date -u: ids are UTC and are aged as UTC, so a local-time id is mis-aged by your offset.
BACKUP_ID=$(date -u +%Y%m%d-%H%M%S)
pmm-backup.sh backup --namespace demo --postgresql      --backup-id "$BACKUP_ID" &
pmm-backup.sh backup --namespace demo --clickhouse      --backup-id "$BACKUP_ID" &
pmm-backup.sh backup --namespace demo --victoriametrics --backup-id "$BACKUP_ID" &
wait

# Skip VictoriaMetrics (faster backup)
pmm-backup.sh backup --namespace demo --skip-victoriametrics

# Custom retention and verbose output
pmm-backup.sh backup --namespace demo --retention 14 --verbose

# List all backups in the bucket
pmm-backup.sh list --namespace demo --s3-bucket my-bucket --s3-prefix demo/pmm-ha

# Show all files belonging to one backup (manifest + objects)
pmm-backup.sh list backup_20260610-120000 --namespace demo --s3-bucket my-bucket
```

---

## 7. Operations Guide

### Running a Backup

**From inside the backup-tools pod** (via K9s shell or `kubectl exec`):

```bash
# Shell into the pod (Deployment — the pod name is generated)
kubectl exec -it -n <namespace> deploy/<release>-backup-tools -- sh

# Run backup
pmm-backup.sh backup --namespace <namespace>
```

**Remotely via kubectl exec**:

```bash
kubectl exec -n <namespace> deploy/<release>-backup-tools -- \
  pmm-backup.sh backup --namespace <namespace>
```

### Log Locations

All logs are written to the logs/ directory on the backup-tools volume:

```
/backups/logs/backup_<id>.log              # Single-process mode
/backups/logs/backup_<id>_postgresql.log   # Concurrent mode (per-component)
/backups/logs/backup_<id>_clickhouse.log
/backups/logs/backup_<id>_victoriametrics.log
/backups/logs/restore_<id>.log             # Restore runs
```

### Central Storage Layout (`shared` mode)

> In **`s3` mode there is no central directory tree** — each tool writes straight to the
> bucket (see §1 for the S3 object layout). The directory structure below applies to the
> **`shared`** (RWX/NFS) target. The backup-tools pod still keeps logs/metrics locally.

After a backup run, the shared volume (mounted at `/central` in the pods, `/backups` in
backup-tools — same volume) contains one directory **per component**, each holding one
subdirectory per backup id. There is no single per-run directory: a backup is a *correlation*
of per-component paths tied together by its manifest (see §4 and DN-06), which is why the
manifest is deleted last during retention.

```text
/backups/
  latest                                    # text pointer -> backup_<id> (what `list` reads)
  manifests/
    backup_20260223-150001.json             # THE index: status + per-component locations/restore
  postgresql/
    backup_20260223-150001/
      pmm-managed.dump                      # pg_dump custom format, one file per database
      grafana.dump
  clickhouse/
    backup_20260223-150001/
      backup_20260223-150001.tar.gz         # in-pod tar of the clickhouse-backup FREEZE
  victoriametrics/
    backup_20260223-150001/
      vmstorage-...-0/vm_backup_<id>/       # vmbackup fs:// output, per pod (+ backup_complete.ignore)
      vmstorage-...-1/vm_backup_<id>/
      vmstorage-...-2/vm_backup_<id>/
  pmm-server/
    backup_20260223-150001/
      pmm-ha-0/srv.tar.gz                   # per pod
      pmm-ha-1/srv.tar.gz
  encryption/
    backup_20260223-150001/
      pg-encryption-key.yaml                # Kubernetes Secret YAML
  logs/                                     # execution logs (backup_<id>.log, restore_<id>.log)
  .logs/                                    # scheduled-run markers/logs (cron-backup.sh)
  .staging/                                 # transient per-run staging, reaped after each run
  .metrics/                                 # Prometheus metrics (postgresql_metrics.prom, …)
```

Locks are **not** on this volume: they are Kubernetes `Lease` objects, because the thing they
protect is a database in the cluster rather than a file on a disk (see §4).

### Listing Backups (`s3` mode)

Most of a backup now lives under one per-run prefix; only ClickHouse keeps its own native
remote layout (its remote path is fixed at deploy time and it names the folder by backup
name, so it is uploaded by clickhouse-backup itself, so its directory contents are tool-managed):

| Component | Object location |
|-----------|-----------------|
| PostgreSQL | `s3://<bucket>/<prefix>/postgresql/<id>/<db>.dump` *(pg_dump per database)* |
| PMM `/srv` | `s3://<bucket>/<prefix>/pmm-server/<id>/<pod>/srv.tar.gz` |
| VictoriaMetrics | `s3://<bucket>/<prefix>/victoriametrics/<id>/<pod>/vm_backup_<id>/` |
| Encryption key | `s3://<bucket>/<prefix>/encryption/<id>/pg-encryption-key.yaml` |
| ClickHouse | `s3://<bucket>/<prefix>/clickhouse/backup_<id>/` *(clickhouse-backup's own layout)* |

To tie them together (and to record where ClickHouse landed), **every run writes one
index**:

```
s3://<bucket>/<prefix>/manifests/<id>.json   # per component: status + how to locate/restore it
s3://<bucket>/<prefix>/latest               # text pointer -> newest backup id
```

**List with the orchestrator** (reads the manifests with the backup-tools pod's own rclone):

```bash
# All backups (newest manifests), '*latest' marks the latest pointer
pmm-backup.sh list --namespace demo --s3-bucket my-bucket --s3-prefix demo/pmm-ha

#   BACKUP ID                      STATUS    COMPONENTS
#   backup_20260610-120000         complete  postgresql,clickhouse,victoriametrics,pmm-server,encryption *latest
#   backup_20260609-120000         partial   postgresql,clickhouse,victoriametrics,pmm-server,encryption
#   * latest -> backup_20260610-120000

# Everything belonging to ONE backup: prints its manifest.json + the objects under <component>/<id>/
pmm-backup.sh list backup_20260610-120000 --namespace demo --s3-bucket my-bucket
```

The single-backup view prints a per-component table (status + location + a ready-to-run
`restore` hint, PostgreSQL and ClickHouse inline) and a size listing of `<component>/<id>/`.
Only ClickHouse lives outside that prefix; the manifest records its name
(`components.clickhouse.name` → `clickhouse-backup restore_remote <name>`). PostgreSQL is
under `postgresql/<id>/` and restores with `pg_restore`.

**List with raw AWS CLI / rclone** (e.g. from a workstation, no sidecar needed):

```bash
# All backup ids + the latest pointer
aws s3 ls s3://my-bucket/<namespace>/pmm-ha/manifests/
aws s3 cp s3://my-bucket/<namespace>/pmm-ha/latest -   # prints the newest id

# One backup: read the manifest, then list its objects
aws s3 cp s3://my-bucket/<namespace>/pmm-ha/manifests/backup_20260610-120000.json -
aws s3 ls --recursive s3://my-bucket/<namespace>/pmm-ha/postgresql/backup_20260610-120000/

# ClickHouse keeps its own layout outside the per-run prefix:
aws s3 ls --recursive s3://my-bucket/<namespace>/pmm-ha/clickhouse/backup_20260610-120000/

# rclone equivalents (remote 's3' configured for the bucket)
rclone cat   s3:my-bucket/<namespace>/pmm-ha/manifests/backup_20260610-120000.json
rclone lsl   s3:my-bucket/<namespace>/pmm-ha/postgresql/backup_20260610-120000/
```

> The manifest is the source of truth for *what belongs to a backup*. Restore should be
> driven by the coordinates it records, not by guessing prefixes.

### Checking Latest Backups (`shared` mode)

`latest` is a small **text file** holding the newest backup id (the same mechanism as s3
mode). Use the `list` command, or read it directly:

```bash
# Newest backup id
cat /backups/latest                                  # -> backup_20260610-120000

# Per-component summary of the latest backup (PG/CH inline with restore commands)
pmm-backup.sh list "$(cat /backups/latest)" --target shared

# Size of the latest backup's PostgreSQL dumps (component first, then the id)
du -sh /backups/postgresql/"$(cat /backups/latest)"/
```

The pointer is overwritten atomically at the end of each successful **full-scope** run (single-component or partial runs never move it — see §4).

### Checking Lock State

Locks are `Lease` objects in the release namespace, not files on the backup volume:

```bash
# List the locks currently held
kubectl get leases -n <namespace> -l app.kubernetes.io/component=pmm-backup-lock

# Who holds one, and when it was last renewed (a live run renews every 60s)
kubectl get lease pmm-backup-victoriametrics -n <namespace> \
  -o jsonpath='{.spec.holderIdentity}{"  renewed: "}{.spec.renewTime}{"  duration: "}{.spec.leaseDurationSeconds}{"\n"}'

# Manually release a stale lock (only if you are sure no backup or restore is running).
# You should rarely need this: a lease whose holder is gone stops being renewed and the next
# run takes it over automatically once it is older than leaseDurationSeconds (900s default).
kubectl delete lease pmm-backup-victoriametrics -n <namespace>
```

If `renewTime` is still advancing, a run really is holding it — do not delete it. If it is
frozen and older than `leaseDurationSeconds`, the next run will take it over on its own.

### Checking Metrics

```bash
# From inside the pod
cat /backups/.metrics/postgresql_metrics.prom

# Via HTTP (netcat server)
wget -qO- http://localhost:9091/

# From another pod in the cluster — backup-tools has NO Service, so target the pod IP directly
# (VMAgent scrapes these the same way, via pod discovery, not a Service DNS name):
POD_IP=$(kubectl get pod -n <namespace> -l app.kubernetes.io/component=backup-tools -o jsonpath='{.items[0].status.podIP}')
wget -qO- "http://${POD_IP}:9091/"
```

### Troubleshooting

**"Cannot connect to Kubernetes cluster"**
- The pre-flight check runs `kubectl get namespace <ns>`. If RBAC is missing the `namespaces` permission, this fails.
- Fix: Ensure the backup Role includes `get` on `namespaces`.

**"Another backup/restore holds the &lt;component&gt; lock"**
- A concurrent run holds that component's `Lease`. Backup and restore share the lock names, so
  this also fires when a restore is running.
- Check whether it is live: `kubectl get lease pmm-backup-<component> -n <ns> -o yaml`. A live
  holder's `renewTime` advances every 60s.
- If it is live, wait. If it is frozen, no action is needed either — the next run takes it over
  once it is older than `leaseDurationSeconds` (900s). Only if you need to proceed immediately:
  `kubectl delete lease pmm-backup-<component> -n <ns>`.

**"...its expiry could not be determined; refusing to steal it"**
- The lease's `renewTime` could not be converted to a time, so the orchestrator cannot tell
  whether the holder is alive — and it will not guess, because stealing a live lock means two
  processes writing one database.
- Inspect the object; if `renewTime` is missing or malformed (only possible if something other
  than this script wrote it), delete the lease.

**PostgreSQL backup fails with "localhost:8080 connection refused"**
- This is a bug in `kubectl exec --request-timeout` (kubectl v1.35.x) when running inside a pod. The `--request-timeout` flag breaks in-cluster API server discovery.
- The script works around this by using the `timeout` command wrapper instead. Ensure the `timeout` binary is available (included in Alpine/BusyBox).

**ClickHouse backup fails with "system.backup_actions table not found"**
- The `clickhouse-backup` sidecar container is not running in the ClickHouse pod.
- Enable it in the Helm chart: `clickhouse.backup.enabled: true`

**Scripts in the pod look outdated after a chart change**
- The scripts are mounted from the `<release>-backup-scripts` ConfigMap with `subPath`
  (no live updates); a checksum annotation rolls the Deployment automatically on
  `helm upgrade`. If in doubt: `kubectl rollout restart deploy/<release>-backup-tools`.

---

## 8. Restore

Restore is the `restore` subcommand of the same tool. It is **manifest-driven** and
supports the same two targets as the backup. Run it via kubectl exec (the pod name is
generated, so target the Deployment):

```bash
kubectl exec -n <namespace> deploy/<release>-backup-tools -- \
  pmm-backup.sh restore --namespace <namespace> --target s3 \
  --s3-bucket <bucket> --s3-region <region> --backup-id latest --dry-run
```

Contents: per-component mechanics, the automated restore flow, cross-namespace / DR
restore, what to expect during a run, and post-restore steps.

---

### 8.1 Per-Component Mechanics and Orchestrated Flow

> **Status:** `pmm-backup.sh restore` (see *Restore subcommand (Automated)* below) is **manifest-driven** and supports **both
> targets** (`--target s3|shared`). It restores PostgreSQL (`pg_restore`), ClickHouse,
> VictoriaMetrics, PMM `/srv`, and the encryption key, discovering each piece from the
> per-run `manifest.json`. The per-component commands below show what it does under the hood
> (and serve ad-hoc single-component restores).

#### PostgreSQL

PostgreSQL is backed up with `pg_dump` (one custom-format file per database), so restore is a
`pg_restore` into the running primary. Scale PMM down first so nothing writes the DBs.

```bash
# shared: the dump is on the central volume (backup-tools mount)
kubectl exec -i -n <namespace> <pg-primary-pod> -c database -- \
  pg_restore --clean --if-exists --no-owner -U postgres -d <db> \
  < /backups/postgresql/backup_<id>/<db>.dump

# s3: stream it from the bucket with the backup-tools pod's own rclone
kubectl exec -n <namespace> deploy/<release>-backup-tools -- \
  rclone cat --s3-no-check-bucket s3:<bucket>/<prefix>/postgresql/<id>/<db>.dump \
  | kubectl exec -i -n <namespace> <pg-primary-pod> -c database -- \
    pg_restore --clean --if-exists --no-owner -U postgres -d <db>
```

Repeat per database (PMM: `pmm-managed`, `grafana`). `--clean --if-exists` drops existing
objects first; the target databases must already exist (operator/chart create them on
deploy), which is exactly why this restores cleanly into a fresh cluster in **any** namespace.
No pgBackRest, stanza, or `PerconaPGRestore` involved.

#### ClickHouse

ClickHouse restores in the live `clickhouse-backup` sidecar (with PMM scaled down):

```bash
# s3: download + restore from the bucket directly. The --env overrides point the tool at
# the SOURCE backup's bucket/prefix — restore_remote has no source-path argument and would
# otherwise only look under the S3_PATH baked into THIS sidecar's env, which is wrong for
# cross-namespace/cross-prefix (DR) restores. The orchestrator always passes them.
kubectl exec -n <namespace> <clickhouse-pod> -c clickhouse-backup -- \
  clickhouse-backup restore_remote \
  --env S3_BUCKET=<source-bucket> --env S3_PATH=<source-prefix>/clickhouse \
  --rm <backup-name>

# shared: untar the archive into the backup dir, then restore
kubectl exec -n <namespace> <clickhouse-pod> -c clickhouse-backup -- sh -c \
  "tar -xzf /central/clickhouse/backup_<id>/<backup-name>.tar.gz -C /var/lib/clickhouse/backup \
   && clickhouse-backup restore --rm <backup-name>"
```

#### VictoriaMetrics

`vmrestore` writes the vmstorage data PVC, so it runs in a temp pod that mounts the PVC while
the cluster is scaled to 0 (the orchestrator does this per pod). The `-src` is the backup's
own location:

```bash
# in a temp pod that mounts vmstorage-db-<pod> at /vmstorage-data:
vmrestore -src=s3://<bucket>/<prefix>/victoriametrics/<id>/<pod>/vm_backup_<id> \
  -storageDataPath=/vmstorage-data          # s3
vmrestore -src=fs:///central/victoriametrics/backup_<id>/<pod>/vm_backup_<id> \
  -storageDataPath=/vmstorage-data          # shared
```

Refer to [VictoriaMetrics vmrestore documentation](https://docs.victoriametrics.com/vmrestore/) for details.

#### Encryption Key

The encryption key is a Kubernetes Secret exported to YAML:

```bash
# Restore the encryption key secret
kubectl apply -f /backups/encryption/backup_<timestamp>/pg-encryption-key.yaml

# Verify
kubectl get secret pg-encryption-key -n <namespace>
```

#### Restore subcommand (Automated)

`pmm-backup.sh restore` automates full restore from central backup storage. It runs in the backup-tools pod (or any host with `kubectl` and read access to the backup directory).

##### Usage

Pass the same `--target` the backup used (`s3` requires `--s3-bucket`; `shared` reads the
central mount). Discovery is from the manifest.

> **Flag-less inside backup-tools.** The chart exports the target and all S3 settings
> (`BACKUP_TARGET`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`, `S3_PROVIDER`, `S3_SECRET_NAME`,
> `S3_SERVICE_ACCOUNT`, …) into the backup-tools pod from your values, so a same-install restore
> needs none of the `--target`/`--s3-*` flags — e.g. `pmm-backup.sh restore --backup-id latest
> --force`. Pass the flags below only to override for a **cross-namespace / cross-prefix** restore
> (point `--s3-prefix` at the source instance) or an S3-compatible endpoint different from the install.
> The examples below show the flags explicitly for clarity.

| Action | Example |
|--------|--------|
| List backups (s3) | `pmm-backup.sh list -n demo --target s3 --s3-bucket my-bucket` |
| List backups (shared) | `pmm-backup.sh list -n demo --target shared` |
| Inspect one backup | `pmm-backup.sh list backup_<id> -n demo --target s3 --s3-bucket my-bucket` |
| Restore latest (s3) | `pmm-backup.sh restore -n demo --target s3 --s3-bucket my-bucket --backup-id latest` |
| Restore specific ID | `pmm-backup.sh restore -n demo --target shared --backup-id 20260224-085602` |
| Restore into another ns | `pmm-backup.sh restore -n demo-dr --target s3 --s3-bucket my-bucket --backup-id latest` |
| Dry run | `pmm-backup.sh restore ... --backup-id latest --dry-run` |
| Skip confirmation | `pmm-backup.sh restore ... --force` |

**Component selection**: `--postgresql`, `--clickhouse`, `--victoriametrics`, `--pmm-server`,
`--encryption-key` (plus `--skip-<component>` to drop components from the default set).
If none are set, every component the manifest marks `success` is restored; explicitly
requesting a component the manifest does NOT mark `success` is a hard error.
PostgreSQL needs no options — databases come from the manifest.

**Orchestration**: `--parallel` (default) or `--sequential`.

##### Restore Flow

1. **Preflight**: namespace exists, `kubectl`, `timeout` and `jq` available (jq parses the
   manifest; auto-installed via `apk` on the Alpine backup-tools image).
2. **S3 access is local to this process** (s3 mode): the orchestrator runs `rclone` itself, in
   the backup-tools pod, with that pod's own S3 credentials. All S3 reads (manifest, ordinal
   mapping, PG dump streaming) go through it. There is no temp S3 client pod any more, and the
   `pmm-backup` sidecar is not used either — it rides on the PMM pods, which this restore
   scales to 0 (and a re-run after a failed restore starts with PMM already down). Every rclone
   call is time-bounded (`RCLONE_TIMEOUT` for reads and deletes, `RCLONE_PURGE_TIMEOUT` for a
   prefix purge, plus rclone's own idle/connect bounds on all of them), so a wedged or
   throttled endpoint fails the operation instead of hanging it.
3. If `list`: enumerate backups from their manifests and exit.
4. **Load manifest**: resolve `--backup-id` (incl. `latest`), validate it is JSON, and read
   each component's status + coordinates (PG databases, CH name, …). Components default to
   whatever the manifest marks `success`; explicitly requesting a component the manifest
   does not carry as `success` is a hard error before anything is touched.
5. If `--dry-run`: print the per-component plan and exit.
6. **Confirm** (unless `--force`; required when there's no TTY).
7. **Encryption key**: fetch from the backup and `kubectl apply` (namespace rewritten to
   the target). Aborts the restore if it fails (data can't be decrypted otherwise).
8. **Scale down PMM** to 0 — nothing may write the DBs during restore, and the
   pmm-storage PVCs must be free for the `/srv` restore.
9. **Restore DB components** (parallel by default): PostgreSQL (`pg_restore --clean
   --if-exists` per database, streamed from the dump; missing/empty dumps and pg_restore
   error lines are hard failures), ClickHouse (s3: `restore_remote --rm` with
   `--env S3_BUCKET/S3_PATH` pointing at the SOURCE `--s3-bucket`/`--s3-prefix`, which
   makes cross-namespace/cross-prefix restores work; shared: untar + `restore --rm`),
   VictoriaMetrics (scale vmstorage+vminsert to 0 — vminsert wait is soft/non-blocking,
   vmstorage wait is strict — then `vmrestore` per ordinal in a temp pod, ordinal-mapped
   to the SOURCE release's directory names, then scale back and bounce vmselect).
   A failed ordinal-map lookup is a hard error (no fallback guessing); partial restores
   (some ordinals failed) fail the component.
10. **PMM `/srv`**: per ordinal, a temp pod mounts the pmm-storage PVC and extracts the
    backup's tarball (`/srv/ha` dropped so the HA raft re-bootstraps). PMM is still at 0.
11. **Verify**: pg_isready, pod presence for ClickHouse/VictoriaMetrics.
12. **Scale up PMM** (LAST, so it boots against fully-restored data): only if all restores
    succeeded; otherwise leave PMM at 0 and exit non-zero with the manual scale-up command.
13. **Metrics**: write `restore_metrics.prom` under `METRICS_DIR` (atomic); served on port 9094, scraped by VMAgent.

Expect ~6 temp pods per full s3 restore (1 vmrestore per vmstorage ordinal +
1 /srv-restore per PMM ordinal; there is no S3 client pod). They are required: the data PVCs are RWO and their owner
pods must be down while data is written, so a short-lived mounter pod per PVC is the only
way in — each is deleted immediately so the real pod can re-attach on scale-up.

##### Restore Metrics

Written to `/backups/.metrics/restore_metrics.prom` and served on port 9094:

- `pmm_ha_restore_in_progress` — 1 while a restore is running
- `pmm_ha_restore_phase` — current phase (encryption_key, scale_down_pmm, postgresql, clickhouse, victoriametrics, verification, scale_up_pmm, idle)
- `pmm_ha_restore_last_success` — 1 if last restore succeeded
- `pmm_ha_restore_last_timestamp_seconds`, `pmm_ha_restore_last_duration_seconds`
- `pmm_ha_restore_component_success{component="postgresql|clickhouse|victoriametrics|pmm_server|encryption_key"}` — 1 per component on success

The backup-tools pod exposes port 9094 and VMAgent has a `backup-restore` scrape job (30s interval) for these metrics.

---

### 8.2 Cross-Namespace / DR Restore

Restore one instance's backup into a DIFFERENT namespace (e.g. production `pmm` into a DR
namespace) on the same cluster. Run the restore in the **target** namespace's backup-tools
pod and point `--s3-prefix` at the **source** instance's prefix — IAM/bucket access is the
same, and the orchestrator passes every tool the full source location (including a
per-invocation `--env S3_BUCKET/S3_PATH` override for `clickhouse-backup`, whose
`restore_remote` otherwise only looks under the target sidecar's own configured path):

```bash
kubectl exec -n <target-ns> deploy/<target-release>-backup-tools -- \
  pmm-backup.sh restore --namespace <target-ns> --target s3 \
  --s3-bucket <bucket> --s3-prefix <SOURCE-prefix> --s3-region <region> \
  --backup-id <backup_id-or-latest> --force
```

Prerequisites for the target namespace: the PMM-HA instance installed (distinct release
name; see the multi-namespace section of the chart README), `pmm-secret` present, and —
for s3 — credentials for the target namespace: with IRSA (AWS), extend the role's trust
policy with the target namespace's ServiceAccounts; with static keys (any S3-compatible
storage), create the credentials Secret in the target namespace and pass `--s3-secret`.

#### S3-compatible storage (MinIO, Ceph RGW, ...)

Add the endpoint (and creds Secret) to every restore invocation — the orchestrator passes
them through to all tools: `-customS3Endpoint` for vmrestore, its own rclone config for the
reads it does itself, and the `RCLONE_CONFIG_S3_*` env it projects into the temp `/srv`
restore pod (there is no separate S3 client pod):

```bash
pmm-backup.sh restore ... \
  --s3-endpoint http://minio.minio.svc:9000 \
  --s3-provider Minio \
  --s3-secret pmm-s3-secret
```

VM and PMM `/srv` restores are **ordinal-mapped**: the source release's directory names
are translated to the target's pods (`vmstorage-<source>-N` → `vmstorage-<target>-N`), so
release names do not need to match. The restored encryption key is rewritten to the
target namespace before being applied.

This REPLACES the target's PG/CH/VM//srv data and encryption key with the source's — the
target becomes a clone of the source's monitoring state.

### 8.3 What To Expect During a Run

A full s3 restore takes minutes even for small data — most of it is pod lifecycle, not
data transfer:

- **~6 temp pods appear and disappear**: one `vm-restore-*` per vmstorage ordinal and
  one `pmm-srv-restore-*` per PMM ordinal (the data PVCs are RWO and their owner pods
  must be down while data is written — a short-lived mounter pod per PVC is the only way
  in; each is deleted immediately so the real pod can re-attach on scale-up). S3 itself
  needs no pod: the orchestrator runs `rclone` in-process, in the backup-tools pod.
- A **soft WARN** if vminsert pods are still terminating after 120s is non-blocking
  (vminsert holds no PVCs; the strict wait is on vmstorage).
- **PMM's final boot back to full replica count is the longest phase** (several minutes).
- On any component failure the run exits non-zero and **PMM is left scaled down** (nothing
  boots against half-restored data); the output includes the manual scale-up command.
  Fix the cause and re-run — a re-run works even with PMM already at 0.

### 8.4 Post-Restore Steps

- **Admin password**: Grafana users live in the restored `grafana` database, so after a
  cross-instance restore the admin password is the SOURCE instance's
  `PMM_ADMIN_PASSWORD`, not the target's secret. Either update the target's `pmm-secret`
  to match, or reset PMM to the target's value:
  ```bash
  kubectl exec -n <ns> <pmm-pod-0> -c pmm-ha -- change-admin-password \
    "$(kubectl get secret pmm-secret -n <ns> -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 -d)"
  ```
- **PG monitoring token**: the target's `pg-pmm-secret` service token was minted in the
  (now overwritten) Grafana DB — re-run the token-init **Job** if PG-side monitoring shows
  401s. It is a regular Job, not a bare pod, so deleting its pods does nothing (a completed
  Job never recreates pods). Delete the Job and let Helm recreate it:
  ```bash
  kubectl delete job -n <ns> <release>-pmm-token-init --ignore-not-found
  helm upgrade <release> charts/pmm-ha -n <ns> --reuse-values --no-hooks
  ```


---

## 9. Known Limitations and Caveats

### kubectl --request-timeout Bug

In kubectl v1.35.x, using `--request-timeout` with `kubectl exec` when running inside a Kubernetes pod breaks in-cluster API server discovery. kubectl falls back to `localhost:8080` instead of using the ServiceAccount token and the cluster API server address. The script works around this by using the `timeout` command from coreutils/BusyBox instead of `--request-timeout`.

### S3 Backup Support

S3 is the **default and recommended target** (`--target s3`), implemented and validated
end-to-end for all components — credentials via static keys (any S3-compatible storage) or
IRSA on AWS, see §1 and §3. ClickHouse,
VictoriaMetrics and PMM `/srv` write directly to the bucket from their own pods
(clickhouse-backup `upload`, vmbackup `-dst=s3://`, and for `/srv` an in-pod
`tar | rclone rcat` in the `pmm-backup` sidecar); PostgreSQL `pg_dump` and the encryption key
are streamed up by the **backup-tools pod's own rclone**, because `pg_dump` cannot write S3 and
the PostgreSQL pod has no rclone (see DN-26). Credentials per
component come from `existingSecret` values (static keys) or the IRSA credential chain
(AWS). Custom endpoints (`endpoint` value / `--s3-endpoint`) reach every tool, including
vmbackup/vmrestore via `-customS3Endpoint`.

### Shared (RWX/NFS) Target

`--target shared` mounts a user-provided RWX volume (`/central`) into the component pods so
each lands its backup with an in-pod write (no API-server streaming for VM/CH/PMM).
PostgreSQL `pg_dump` is streamed through the orchestrator onto the same volume. The chart
mounts `/central` into the PMM StatefulSet, the clickhouse-backup sidecar, and the vmbackup/
vmrestore sidecars; the volume must be `ReadWriteMany`.

### Metrics Persistence

Metrics files are stored on the PVC (`/backups/.metrics/`), so they survive pod restarts. However, after an initial deployment (before any backup has run), the metrics files contain only a placeholder comment (`# Waiting for first backup run`). VMAgent will scrape these without error but no metrics will be available until the first backup completes.

### netcat Serving Limitations

The metrics HTTP server uses BusyBox `nc` (netcat) which handles one connection at a time per port. If VMAgent and a manual `wget` hit the same port simultaneously, one will get a connection refused. This is acceptable given the 60-second scrape interval and the low-traffic nature of backup metrics.
