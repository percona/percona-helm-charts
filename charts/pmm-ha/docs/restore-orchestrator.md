# PMM-HA Restore Orchestrator

Documentation for `restore-orchestrator.sh` — the unified restore counterpart of
[backup-orchestrator.md](backup-orchestrator.md). The script ships with the chart
(`files/restore-orchestrator.sh`) and is mounted into the backup-tools Deployment; run it
via kubectl exec (the pod name is generated, so target the Deployment):

```bash
kubectl exec -n <namespace> deploy/<release>-backup-tools -- \
  restore-orchestrator.sh --namespace <namespace> --target s3 \
  --s3-bucket <bucket> --s3-region <region> --backup-id latest --dry-run
```

Contents: per-component mechanics, the automated orchestrator flow, cross-namespace / DR
restore, what to expect during a run, and post-restore steps.

---

## 1. Per-Component Mechanics and Orchestrated Flow

> **Status:** `restore-orchestrator.sh` (see *Restore Orchestrator (Automated)* below) is **manifest-driven** and supports **both
> targets** (`--target s3|shared`). It restores PostgreSQL (`pg_restore`), ClickHouse,
> VictoriaMetrics, PMM `/srv`, and the encryption key, discovering each piece from the
> per-run `manifest.json`. The per-component commands below show what it does under the hood
> (and serve ad-hoc single-component restores).

### PostgreSQL

PostgreSQL is backed up with `pg_dump` (one custom-format file per database), so restore is a
`pg_restore` into the running primary. Scale PMM down first so nothing writes the DBs.

```bash
# shared: the dump is on the central volume (backup-tools mount)
kubectl exec -i -n <namespace> <pg-primary-pod> -c database -- \
  pg_restore --clean --if-exists --no-owner -U postgres -d <db> \
  < /backups/backup_<id>/postgresql/<db>.dump

# s3: stream it from the bucket through the pmm-backup sidecar's rclone
kubectl exec -n <namespace> <pmm-pod> -c pmm-backup -- \
  rclone cat --s3-no-check-bucket s3:<bucket>/<prefix>/backups/<id>/postgresql/<db>.dump \
  | kubectl exec -i -n <namespace> <pg-primary-pod> -c database -- \
    pg_restore --clean --if-exists --no-owner -U postgres -d <db>
```

Repeat per database (PMM: `pmm-managed`, `grafana`). `--clean --if-exists` drops existing
objects first; the target databases must already exist (operator/chart create them on
deploy), which is exactly why this restores cleanly into a fresh cluster in **any** namespace.
No pgBackRest, stanza, or `PerconaPGRestore` involved.

### ClickHouse

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
  "tar -xzf /central/backup_<id>/clickhouse/<backup-name>.tar.gz -C /var/lib/clickhouse/backup \
   && clickhouse-backup restore --rm <backup-name>"
```

### VictoriaMetrics

`vmrestore` writes the vmstorage data PVC, so it runs in a temp pod that mounts the PVC while
the cluster is scaled to 0 (the orchestrator does this per pod). The `-src` is the backup's
own location:

```bash
# in a temp pod that mounts vmstorage-db-<pod> at /vmstorage-data:
vmrestore -src=s3://<bucket>/<prefix>/backups/<id>/victoriametrics/<pod>/vm_backup_<id> \
  -storageDataPath=/vmstorage-data          # s3
vmrestore -src=fs:///central/backup_<id>/victoriametrics/<pod>/vm_backup_<id> \
  -storageDataPath=/vmstorage-data          # shared
```

Refer to [VictoriaMetrics vmrestore documentation](https://docs.victoriametrics.com/vmrestore/) for details.

### Encryption Key

The encryption key is a Kubernetes Secret exported to YAML:

```bash
# Restore the encryption key secret
kubectl apply -f /backups/backup_<timestamp>/encryption/pg-encryption-key.yaml

# Verify
kubectl get secret pg-encryption-key -n <namespace>
```

### Restore Orchestrator (Automated)

The **restore-orchestrator.sh** script automates full restore from central backup storage. It runs in the backup-tools pod (or any host with `kubectl` and read access to the backup directory).

#### Usage

Pass the same `--target` the backup used (`s3` requires `--s3-bucket`; `shared` reads the
central mount). Discovery is from the manifest.

> **Flag-less inside backup-tools.** The chart exports the target and all S3 settings
> (`BACKUP_TARGET`, `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`, `S3_PROVIDER`, `S3_SECRET_NAME`,
> `S3_SERVICE_ACCOUNT`, …) into the backup-tools pod from your values, so a same-install restore
> needs none of the `--target`/`--s3-*` flags — e.g. `restore-orchestrator.sh --backup-id latest
> --force`. Pass the flags below only to override for a **cross-namespace / cross-prefix** restore
> (point `--s3-prefix` at the source instance) or an S3-compatible endpoint different from the install.
> The examples below show the flags explicitly for clarity.

| Action | Example |
|--------|--------|
| List backups (s3) | `restore-orchestrator.sh list -n demo --target s3 --s3-bucket my-bucket` |
| List backups (shared) | `restore-orchestrator.sh list -n demo --target shared` |
| Inspect one backup | `restore-orchestrator.sh list backup_<id> -n demo --target s3 --s3-bucket my-bucket` |
| Restore latest (s3) | `restore-orchestrator.sh -n demo --target s3 --s3-bucket my-bucket --backup-id latest` |
| Restore specific ID | `restore-orchestrator.sh -n demo --target shared --backup-id 20260224-085602` |
| Restore into another ns | `restore-orchestrator.sh -n demo-dr --target s3 --s3-bucket my-bucket --backup-id latest` |
| Dry run | `restore-orchestrator.sh ... --backup-id latest --dry-run` |
| Skip confirmation | `restore-orchestrator.sh ... --force` |

**Component selection**: `--postgresql`, `--clickhouse`, `--victoriametrics`, `--pmm-server`,
`--encryption-key` (plus `--skip-<component>` to drop components from the default set).
If none are set, every component the manifest marks `success` is restored; explicitly
requesting a component the manifest does NOT mark `success` is a hard error.
PostgreSQL needs no options — databases come from the manifest.

**Orchestration**: `--parallel` (default) or `--sequential`.

#### Restore Flow

1. **Preflight**: namespace exists, `kubectl`, `timeout` and `jq` available (jq parses the
   manifest; auto-installed via `apk` on the Alpine backup-tools image).
2. **Temp S3 client pod** (s3 mode): start `restore-s3-client-<pid>` (rclone image, backup
   SA — plus static creds from `--s3-secret` when set — `karpenter.sh/do-not-disrupt`). All S3 reads (manifest, ordinal mapping, PG dump
   streaming) go through it — the `pmm-backup` sidecar cannot be used because it rides on
   the PMM pods, which this restore scales to 0 (and a re-run after a failed restore
   starts with PMM already down). Deleted on exit via trap.
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

Expect ~7 temp pods per full s3 restore (1 S3 client + 1 vmrestore per vmstorage ordinal +
1 /srv-restore per PMM ordinal). They are required: the data PVCs are RWO and their owner
pods must be down while data is written, so a short-lived mounter pod per PVC is the only
way in — each is deleted immediately so the real pod can re-attach on scale-up.

#### Restore Metrics

Written to `/backups/.metrics/restore_metrics.prom` and served on port 9094:

- `pmm_ha_restore_in_progress` — 1 while a restore is running
- `pmm_ha_restore_phase` — current phase (encryption_key, scale_down_pmm, postgresql, clickhouse, victoriametrics, verification, scale_up_pmm, idle)
- `pmm_ha_restore_last_success` — 1 if last restore succeeded
- `pmm_ha_restore_last_timestamp_seconds`, `pmm_ha_restore_last_duration_seconds`
- `pmm_ha_restore_component_success{component="postgresql|clickhouse|victoriametrics|pmm_server|encryption_key"}` — 1 per component on success

The backup-tools pod exposes port 9094 and VMAgent has a `backup-restore` scrape job (30s interval) for these metrics.

---

## 2. Cross-Namespace / DR Restore

Restore one instance's backup into a DIFFERENT namespace (e.g. production `pmm` into a DR
namespace) on the same cluster. Run the restore in the **target** namespace's backup-tools
pod and point `--s3-prefix` at the **source** instance's prefix — IAM/bucket access is the
same, and the orchestrator passes every tool the full source location (including a
per-invocation `--env S3_BUCKET/S3_PATH` override for `clickhouse-backup`, whose
`restore_remote` otherwise only looks under the target sidecar's own configured path):

```bash
kubectl exec -n <target-ns> deploy/<target-release>-backup-tools -- \
  restore-orchestrator.sh --namespace <target-ns> --target s3 \
  --s3-bucket <bucket> --s3-prefix <SOURCE-prefix> --s3-region <region> \
  --backup-id <backup_id-or-latest> --force
```

Prerequisites for the target namespace: the PMM-HA instance installed (distinct release
name; see the multi-namespace section of the chart README), `pmm-secret` present, and —
for s3 — credentials for the target namespace: with IRSA (AWS), extend the role's trust
policy with the target namespace's ServiceAccounts; with static keys (any S3-compatible
storage), create the credentials Secret in the target namespace and pass `--s3-secret`.

### S3-compatible storage (MinIO, Ceph RGW, ...)

Add the endpoint (and creds Secret) to every restore invocation — the orchestrator passes
them through to all tools, including `-customS3Endpoint` for vmrestore and the rclone
config of its temp S3 client pod:

```bash
restore-orchestrator.sh ... \
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

## 3. What To Expect During a Run

A full s3 restore takes minutes even for small data — most of it is pod lifecycle, not
data transfer:

- **~7 temp pods appear and disappear**: one `restore-s3-client-*` (rclone; lives for the
  whole run — the pmm-backup sidecar rides on the PMM pods, which the restore scales to
  0, so a standalone S3 client is required), one `vm-restore-*` per vmstorage ordinal and
  one `pmm-srv-restore-*` per PMM ordinal (the data PVCs are RWO and their owner pods
  must be down while data is written — a short-lived mounter pod per PVC is the only way
  in; each is deleted immediately so the real pod can re-attach on scale-up).
- A **soft WARN** if vminsert pods are still terminating after 120s is non-blocking
  (vminsert holds no PVCs; the strict wait is on vmstorage).
- **PMM's final boot back to full replica count is the longest phase** (several minutes).
- On any component failure the run exits non-zero and **PMM is left scaled down** (nothing
  boots against half-restored data); the output includes the manual scale-up command.
  Fix the cause and re-run — a re-run works even with PMM already at 0.

## 4. Post-Restore Steps

- **Admin password**: Grafana users live in the restored `grafana` database, so after a
  cross-instance restore the admin password is the SOURCE instance's
  `PMM_ADMIN_PASSWORD`, not the target's secret. Either update the target's `pmm-secret`
  to match, or reset PMM to the target's value:
  ```bash
  kubectl exec -n <ns> <pmm-pod-0> -c pmm-ha -- change-admin-password \
    "$(kubectl get secret pmm-secret -n <ns> -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 -d)"
  ```
- **PG monitoring token**: the target's `pg-pmm-secret` service token was minted in the
  (now overwritten) Grafana DB — re-run the token-init job if PG-side monitoring shows
  401s:
  ```bash
  kubectl delete pod -n <ns> -l job-name=<release>-pmm-token-init
  ```
