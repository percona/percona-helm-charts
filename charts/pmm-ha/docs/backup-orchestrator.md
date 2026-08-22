# PMM-HA Backup Orchestrator

Comprehensive documentation for `backup-orchestrator.sh` -- the unified backup script for PMM-HA (Percona Monitoring and Management - High Availability).

---

## 1. Overview

`backup-orchestrator.sh` orchestrates backups across all PMM-HA components using their
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
        │  backup-orchestrator.sh   │   kubectl exec carries COMMANDS only,
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
- **Where stored**: one custom-format file per database under the per-run prefix —
  `s3://<bucket>/<prefix>/postgresql/<id>/<db>.dump` (s3, streamed `pg_dump | rclone
  rcat` via the `pmm-backup` sidecar) or `<central>/backup_<id>/postgresql/<db>.dump`
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
`restore-orchestrator.sh --backup-id latest` just works. Pass `--s3-secret` / `--s3-endpoint` /
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
| `templates/backup-scripts-configmap.yaml` | orchestrator + scheduler scripts (`backup-orchestrator.sh`, `restore-orchestrator.sh`, `cron-backup.sh`) rendered into a ConfigMap, mounted at `/usr/local/bin` |
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
(`centralBackupStorage.tools.image`, default tag pinned in values.yaml). The three scripts
(`backup-orchestrator.sh`, `restore-orchestrator.sh`, and the scheduler's `cron-backup.sh`)
are **shipped by the chart** (`files/*.sh`), rendered into the `<release>-backup-scripts`
ConfigMap and mounted into `/usr/local/bin/` — no manual copying, and a checksum annotation
rolls the pod whenever the scripts change.
On startup the container:

1. Creates the metrics directory (`/backups/.metrics/`)
2. Initializes placeholder `.prom` files for each component
3. Starts four netcat listeners in the background (ports 9091, 9092, 9093, 9094) to serve per-component backup metrics and restore metrics
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
kubectl exec -n <namespace> deploy/<release>-backup-tools -- backup-orchestrator.sh --help
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
    extraArgs: []             # extra backup-orchestrator.sh args
    startingDeadlineSeconds: 600    # skip a run that can't start within N seconds
    activeDeadlineSeconds: 3600     # hard cap on one run (backstop; raise for very large installs)
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

1. Starts `backup-orchestrator.sh` **detached** (`setsid`/`nohup`) so the backup survives the
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

```bash
BACKUP_ID=$(date +%Y%m%d-%H%M%S)
backup-orchestrator.sh --postgresql      --backup-id "$BACKUP_ID" &
backup-orchestrator.sh --clickhouse      --backup-id "$BACKUP_ID" &
backup-orchestrator.sh --victoriametrics --backup-id "$BACKUP_ID" &
wait
```

Without `--backup-id`, each process auto-generates its own timestamp, resulting in separate directories. With `--backup-id`, all three write under the same backup id (e.g. `/backups/postgresql/backup_20260223-150001/`, `/backups/clickhouse/backup_20260223-150001/`, …), and one shared `manifests/backup_20260223-150001.json` records the set. This makes it clear which backups belong together for a coordinated restore.

In concurrent mode (single component with `--backup-id`), each process writes its own
per-component log file (`logs/backup_<id>_postgresql.log`) to avoid conflicts; run status
is consolidated in the shared `manifest.json` via the merge below.

**Manifest merging**: each finishing process performs a read-merge-write of
`manifests/<id>.json` (serialized by a local mkdir-lock on the shared backup-tools
pod): it fetches the manifest written so far, carries over the component entries it does
not own, and recomputes the overall status from the merged set. The last finisher therefore
produces a manifest listing ALL components of the group — no last-writer-wins clobbering.
The merge is jq-based; manifests are plain JSON with no format/indentation contract.

### Per-Component Locking

Each component has its own lock, implemented as an atomic `mkdir` operation:

```
/backups/.backup_clickhouse.lock/pid
/backups/.backup_pmm-server.lock/pid
/backups/.backup_postgresql.lock/pid
/backups/.backup_victoriametrics.lock/pid
```

`mkdir` is atomic at the kernel level -- if two processes attempt it simultaneously on the same path, exactly one succeeds and the other gets `EEXIST`. This is more robust than file-based PID locking.

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
- **Manifest / latest pointer**: written once at the end of a run under a local manifest
  lock (concurrent `--backup-id` processes merge, see §4). The `latest` pointer only moves
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

Each metric includes labels: `component` (postgresql/clickhouse/victoriametrics/pmm-server) and `namespace`. (PMM `/srv` metrics are written to a `.prom` file like the others; a dedicated scrape port for it is not yet wired in the chart.)

### HTTP Serving

The backup-tools pod runs four netcat listeners, each serving one metrics file:

| Port | Component | Served File |
|---|---|---|
| 9091 | PostgreSQL | `postgresql_metrics.prom` |
| 9092 | ClickHouse | `clickhouse_metrics.prom` |
| 9093 | VictoriaMetrics | `victoriametrics_metrics.prom` |
| 9094 | Restore | `restore_metrics.prom` |

### VMAgent Scrape Configuration

Four scrape jobs are defined in `vmagent.yaml` (conditionally enabled when `centralBackupStorage.enabled`):

- `backup-postgresql` -- scrapes port 9091
- `backup-clickhouse` -- scrapes port 9092
- `backup-victoriametrics` -- scrapes port 9093
- `backup-restore` -- scrapes port 9094 (restore metrics)

All use `kubernetes_sd_configs` with `role: pod`, filtering on label `app.kubernetes.io/component: backup-tools` and the corresponding container port number. The three backup jobs scrape every 60s; the `backup-restore` job (port 9094) scrapes every 30s.

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
backup-orchestrator.sh [COMMAND] [OPTIONS]
```

Commands:

| Command | Description |
|---|---|
| `backup` *(default)* | Back up the selected components. |
| `list [BACKUP_ID]` | List backups, or — given a `BACKUP_ID` — show every file/location belonging to that one backup (read from its `manifest.json`). Reuses the same `--s3-bucket` / `--s3-prefix` / `--namespace` flags. |

With no component flags, all four components are backed up (PostgreSQL, ClickHouse, VictoriaMetrics, PMM server `/srv`). Specifying any `--postgresql`, `--clickhouse`, `--victoriametrics`, or `--pmm-server` flag switches to selective mode (only specified components run).

See [Listing Backups](#listing-backups-s3-mode) for the manifest/catalog details.

### Flags

> **Flag-less by default.** Inside the backup-tools pod the chart pre-populates the target and
> every S3 setting from `values.yaml` as env (see *Environment Variables* below), so
> `backup-orchestrator.sh` runs with **no `--s3-*`/`--target` flags** — they default to the
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
| `--s3-prefix PREFIX` | Key namespace under the bucket | pmm-ha |
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
consumed by **restore-orchestrator.sh** (its temp pods), so a restore inside the pod needs no flags:

| Variable | Description | Default |
|---|---|---|
| `S3_PROVIDER` | rclone provider profile (`AWS`/`Minio`/`Ceph`/`Other`) for the restore temp client pod | AWS |
| `S3_SECRET_NAME` | Static-key Secret name injected into restore temp pods (empty ⇒ IRSA / SA credential chain) | |
| `S3_SECRET_ACCESS_KEY_KEY` / `S3_SECRET_SECRET_KEY_KEY` | Keys within that Secret | access-key / secret-key |
| `S3_SERVICE_ACCOUNT` | ServiceAccount for restore temp pods (IRSA SA, or one carrying imagePullSecrets) | pmm-ha-backup-s3 |

### Examples

```bash
# Full backup of all components
backup-orchestrator.sh --namespace demo

# PostgreSQL only
backup-orchestrator.sh --namespace demo --postgresql

# PostgreSQL and ClickHouse together
backup-orchestrator.sh --namespace demo --postgresql --clickhouse

# Run all three concurrently, grouped into the same backup directory
BACKUP_ID=$(date +%Y%m%d-%H%M%S)
backup-orchestrator.sh --namespace demo --postgresql      --backup-id "$BACKUP_ID" &
backup-orchestrator.sh --namespace demo --clickhouse      --backup-id "$BACKUP_ID" &
backup-orchestrator.sh --namespace demo --victoriametrics --backup-id "$BACKUP_ID" &
wait

# Skip VictoriaMetrics (faster backup)
backup-orchestrator.sh --namespace demo --skip-victoriametrics

# Custom retention and verbose output
backup-orchestrator.sh --namespace demo --retention 14 --verbose

# List all backups in the bucket
backup-orchestrator.sh list --namespace demo --s3-bucket my-bucket --s3-prefix pmm-ha

# Show all files belonging to one backup (manifest + objects)
backup-orchestrator.sh list backup_20260610-120000 --namespace demo --s3-bucket my-bucket
```

---

## 7. Operations Guide

### Running a Backup

**From inside the backup-tools pod** (via K9s shell or `kubectl exec`):

```bash
# Shell into the pod (Deployment — the pod name is generated)
kubectl exec -it -n <namespace> deploy/<release>-backup-tools -- sh

# Run backup
backup-orchestrator.sh --namespace <namespace>
```

**Remotely via kubectl exec**:

```bash
kubectl exec -n <namespace> deploy/<release>-backup-tools -- \
  backup-orchestrator.sh --namespace <namespace>
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
backup-tools — same volume) contains, **all under one per-run dir**:

```
/backups/
  latest                              # text pointer -> backup_<id> (what `list` reads)
  backup_20260223-150001/
    manifest.json                     # per-run index (status + per-component locations/restore)
    postgresql/
      pmm-managed.dump                # pg_dump custom format, one file per database
      grafana.dump
    clickhouse/
      backup_20260223-150001.tar.gz   # in-pod tar of the clickhouse-backup FREEZE
    victoriametrics/
      vmstorage-...-0/vm_backup_<id>/ # vmbackup fs:// output, per pod (+ backup_complete.ignore)
      vmstorage-...-1/vm_backup_<id>/
      vmstorage-...-2/vm_backup_<id>/
    pmm-server/
      pmm-ha-0/srv.tar.gz             # per pod
      pmm-ha-1/srv.tar.gz
    encryption/
      pg-encryption-key.yaml          # Kubernetes Secret YAML
  logs/                               # execution logs (backup_<id>.log, restore_<id>.log)
  .metrics/                           # Prometheus metrics (postgresql_metrics.prom, …)
  .backup_postgresql.lock/            # active lock (directory, exists only during a run)
```

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

**List with the orchestrator** (reads the manifests via the `pmm-backup` sidecar's rclone):

```bash
# All backups (newest manifests), '*latest' marks the latest pointer
./backup-orchestrator.sh list --namespace demo --s3-bucket my-bucket --s3-prefix pmm-ha

#   BACKUP ID                      STATUS    COMPONENTS
#   backup_20260610-120000         complete  postgresql,clickhouse,victoriametrics,pmm-server,encryption *latest
#   backup_20260609-120000         partial   postgresql,clickhouse,victoriametrics,pmm-server,encryption
#   * latest -> backup_20260610-120000

# Everything belonging to ONE backup: prints its manifest.json + the objects under <component>/<id>/
./backup-orchestrator.sh list backup_20260610-120000 --namespace demo --s3-bucket my-bucket
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
./backup-orchestrator.sh list "$(cat /backups/latest)" --target shared

# Size of the latest backup's PostgreSQL dumps
du -sh /backups/"$(cat /backups/latest)"/postgresql/
```

The pointer is overwritten atomically at the end of each successful **full-scope** run (single-component or partial runs never move it — see §4).

### Checking Lock State

```bash
# List active locks
ls -la /backups/.backup_*.lock/

# See which PID holds a lock
cat /backups/.backup_victoriametrics.lock/pid

# Manually remove a stale lock (only if you're sure no backup is running)
rm -rf /backups/.backup_victoriametrics.lock
```

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

**"Another <component> backup is already running (PID: ...)"**
- A concurrent run is already backing up this component.
- Wait for it to finish, or if it's stale (process died without cleanup), remove the lock: `rm -rf /backups/.backup_<component>.lock`

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

## 8. Restore Procedures

Restore is documented separately: see [restore-orchestrator.md](restore-orchestrator.md)
(same-namespace restore, cross-namespace / DR restore, what to expect during a run,
and post-restore steps).

---

## 9. Known Limitations and Caveats

### kubectl --request-timeout Bug

In kubectl v1.35.x, using `--request-timeout` with `kubectl exec` when running inside a Kubernetes pod breaks in-cluster API server discovery. kubectl falls back to `localhost:8080` instead of using the ServiceAccount token and the cluster API server address. The script works around this by using the `timeout` command from coreutils/BusyBox instead of `--request-timeout`.

### S3 Backup Support

S3 is the **default and recommended target** (`--target s3`), implemented and validated
end-to-end for all components — credentials via static keys (any S3-compatible storage) or
IRSA on AWS, see §1 and §3. ClickHouse,
VictoriaMetrics and PMM `/srv` write directly to the bucket (clickhouse-backup `upload`,
vmbackup `-dst=s3://`, the `pmm-backup` rclone sidecar); PostgreSQL `pg_dump` and the
encryption key are streamed up through that same rclone sidecar. Credentials per
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
