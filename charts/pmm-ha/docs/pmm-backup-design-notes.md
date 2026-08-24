# `pmm-backup.sh` — design notes

Why the orchestrator is written the way it is. Each note records a decision and, usually, the
incident that forced it — so a future change can tell a deliberate constraint from an accident.

`files/pmm-backup.sh` references these by id (`# see DN-07`). **Do not delete a note because
the code looks obvious now**: most of these describe a shape that was once "obviously" wrong
and got shipped.

---

## DN-01 — One file, three subcommands

`backup-orchestrator.sh` and `restore-orchestrator.sh` duplicated eleven functions (logging,
locking, S3 primitives, manifest access, list, metrics) plus a sourced `backup-layout.sh` with
an unenforced pre-source contract. The copies drifted: every significant regression in the
retention work came from one copy being updated and its twin forgotten.

One file removes the drift surface and the source-time contract. The cost is size — see the
design review for the standing plan to author this as modules and ship it concatenated.

## DN-02 — The subcommand is mandatory; there is no default operation

The two predecessors disagreed on their default: one defaulted to backup, the other to
**restore**. Every flag in `--backup-id <id> --target s3 --s3-bucket B` is valid for both
operations, so a bare invocation typed from restore muscle memory parsed cleanly as a BACKUP:
it overwrote the backup it was meant to restore, re-pointed `latest`, then ran retention.
Nothing else can catch that. Name the operation.

## DN-03 — `rc != 0` means "could not look", never "it is not there"

The storage layer's contract: rc 0 means the operation happened. Non-zero means "could not do
it", which callers must **not** conflate with "the data is absent". Retention deletes on that
distinction and the pre-restore gate refuses on it.

Consequence: **no function in the storage layer may end in a pipe.** A pipeline reports its
last element's status, so `rclone lsf … | sed` returns sed's success even when rclone failed.
That is how a retention sweep read a failed listing as "no backups", and how a validation gate
reported "your backup is missing" for an unreachable sidecar. Output is captured first, then
transformed, so the original status survives.

## DN-04 — Absence must be positively established before a failed delete is forgiven

A plain existence probe is wrong here: "not found" and "could not look" are indistinguishable
in its exit status, so unreachable storage read as "already deleted", and a sweep that deleted
nothing reported success and then removed the manifest.

`store_absent` therefore requires a listing that **succeeds and does not contain the entry**.
It uses `store_list`, not `store_list_files`: the delete target is a *prefix* for
`store_delete_prefix`, and a files-only listing can never contain a surviving DIRECTORY. That
made every failed purge of `<component>/<id>/` report "provably gone", so retention counted no
component failure and deleted the manifest — leaving component data with no index, invisible
to list, restore and every later sweep.

## DN-05 — Three views of one location

The same location is addressed three ways, and confusing them has already caused a bug (a
check that stat'ed the orchestrator's mount for a file the ClickHouse pod reads through a
different one):

| view | meaning |
|---|---|
| `*_path` | what THIS process passes to rclone / opens directly |
| `*_display` | human-readable, for logs and the manifest (`s3://…`, not `remote:…`) |
| `*_inpod` | what a COMPONENT pod sees — identical on s3; the shared volume is mounted at `SHARED_MOUNT_PATH` in pods and at `BACKUP_DIR` here |

## DN-06 — A backup is a correlation, not a directory

Components live at `<root>/<component>/<id>/`, so nothing in the layout enforces atomicity.
Retention must therefore delete every component path for an id **or none**, and the manifest —
the only record of what the backup held — is deleted **last**. A partial failure keeps the
manifest and reports the id as still present, so the next run retries it instead of leaving
orphaned data behind an absent index.

## DN-07 — Retention parses the id, not object mtimes

Age comes from the timestamp embedded in the backup id. The name is the backup's identity and
never changes, while mtimes shift on any re-upload or copy — and parsing the name makes
retention testable without waiting days, since a backdated id can just be created.

`date` is not used for the conversion at all. `epoch_utc` implements days-from-civil in shell
arithmetic, and both `backup_id_epoch` and `epoch_from_rfc3339` go through it. Three reasons,
each of which had already caused a bug:

1. **There is no portable way to tell `date` that its input is UTC.** BusyBox needs `-D`, GNU
   accepts an ISO-ish string with `-d`, and *both* interpret it in the container's local zone.
   Every timestamp this file writes is UTC, so on any pod with a `TZ` set the value read back
   was off by the offset. For leases that was severe: east of UTC a lease renewed one second
   ago looked expired, so a run took over a lock another run was actively holding and two
   processes wrote one database; west of UTC nothing ever expired, so a genuinely stale lock
   could never be recovered and every later run aborted.
2. **Neither form exists on BSD/macOS.** Both helpers returned empty there, so retention
   skipped every backup ("cannot parse a usable timestamp") and no lock was ever recoverable —
   on the host the runbook tells operators to run DR restores from.
3. **The two implementations disagreed about garbage.** BusyBox `date -D` happily parses
   `20260821-103000-preupgrade` (trailing garbage ignored) while GNU date rejects it, so the
   same bucket got opposite retention decisions depending on which image ran the sweep, and a
   deliberately-named `backup_<ts>-preupgrade` could be DELETED on BusyBox.

The shape is still anchored **before** conversion, and the result is still shape-checked before
it is compared: emptiness alone is not a sufficient check, because an implementation that
prints a diagnostic to stdout yields a non-empty, non-numeric value and `[ "text" -ge N ]`
exits 2 — which an `if` reads as false, classifying the backup EXPIRED.

`TIMESTAMP` is generated with `date -u` for the same reason. A local-time id means a CronJob
pod, an operator's laptop and a DR cluster disagree about how old a backup is by their offset,
in a bucket all three read.

## DN-08 — Retention guardrails

A bug here destroys backups irreversibly (the bucket has no versioning, so there is no undo):

- retention < 1 refuses the sweep;
- the `latest` pointer object is never deleted, and neither is the id it names, even past the
  cutoff — a stale pointer is recoverable, a dangling one is not;
- ids whose timestamp cannot be parsed are skipped and logged, never deleted;
- a sweep that would leave **no kept parseable backup** is refused. The survivor test counts
  only kept *parseable* backups: `skipped` lumps together a stray prefix, an aborted
  `backup_<junk>`, and a real backup with an odd id, so counting it meant one piece of junk
  disarmed the guard entirely;
- deletions are capped per run **and** by wall clock, so a parsing regression can only destroy
  a bounded amount, and an unbounded sweep cannot get the CronJob killed while holding locks;
- the cap counts ATTEMPTS, not successes — counting successes let a systematic partial failure
  issue unlimited destructive calls while the counter never advanced;
- ownership is proven from each manifest's own `namespace` field. Installs can legitimately
  share a prefix (the chart documents pointing a DR target at production's bucket), and
  age-based pruning cannot tell whose backup an id is.

## DN-09 — ClickHouse incremental chains vs. age-based retention

`clickhouse-backup` uploads an incremental as a diff against an earlier **remote** backup
(`upload --diff-from-remote=<base>`), so a newer backup is not independently restorable.
Age-based pruning knows nothing about that: expiring the base breaks every incremental built on
it, and the pre-restore gate does not catch it — that gate only checks the *name* is present in
`list remote`, which it still is. The failure lands mid-restore, with PMM already at 0.

Each backup therefore records `components.clickhouse.base`, and the sweep computes which
ClickHouse names a retained backup still needs, transitively. Not reclaiming disk is
recoverable; breaking a chain is not — but "fail closed" has to mean *narrowly* closed, because
the first version of this made both mistakes that turn a safety property into an outage of
retention itself:

**It failed closed too widely.** Any unreadable or non-JSON manifest anywhere in the catalog —
one stray object under `manifests/`, one transient read error — and any required base whose own
id had already been legitimately purged, deferred every ClickHouse-carrying id on **every
subsequent run**, forever, behind a single WARN, while the sweep logged "0 purged" and success
and the bucket grew without bound. Now:

| Condition | Behaviour |
|---|---|
| Unreadable manifest of a backup being **kept** | Fails closed for the whole sweep (we cannot know which base it needs) — logged at ERROR, naming the id |
| Unreadable manifest of a backup being **purged** | That id alone is deferred; the purge loop refuses it anyway rather than delete on a guess about its contents |
| A required base that no manifest declares | Treated as a chain end, with a WARN. That chain is already broken and deferring cannot repair it — freezing retention forever only adds a second fault |

**It pinned far more than ClickHouse.** Skipping the whole id meant an incremental chain (which
is every night, once `--ch-backup-type incremental` is used, since each night's base is the
previous night) also retained each expired id's PostgreSQL, VictoriaMetrics and `/srv` data —
usually the bulk of the bytes — indefinitely, for data nothing depends on. Retention effectively
stopped for the entire install rather than for the one component the constraint applies to.

A pinned ClickHouse backup now pins only `clickhouse/<id>/` and the manifest. The other
components are purged, and the manifest is then rewritten with those component keys marked
`status: "pruned"` and their `location`/`restore` fields removed. Keeping the keys is what lets
a later sweep finish the job once the chain releases the id; marking them is what stops `list`
and the restore pre-flight from advertising components that are no longer in the bucket. The
rewrite happens **after** the purge on purpose: a manifest that briefly over-reports is
corrected on the next run, whereas one that under-reports would strand those bytes forever.

Incremental note (verified against clickhouse-backup 2.8.0): for regular (non-embedded) backups
the diff happens at UPLOAD time. `create` is always a full local hardlink snapshot, and its
`--diff-from-remote` flag applies only to embedded/object-disk backups — so the flag goes on
`upload`, and flags must precede the positional backup name.

## DN-10 — `location='remote'` is required when picking an incremental base

`system.backup_list` also carries local-only rows, and a failed upload leaves exactly that (the
local copy is deleted only AFTER a successful upload). Without the filter the next incremental
picked that local-only name, clickhouse-backup rejected the base, the upload failed and left
another local-only row — every subsequent incremental broken until someone manually deleted
local backups.

## DN-11 — The ClickHouse action-poll must match only this run's row

The command string is the key used to poll `system.backup_actions`, so it must be
byte-identical between the INSERT and the SELECT — an extra space from an empty variable makes
the poll match nothing and the step time out despite the upload succeeding.

The newest existing action time for that exact command is recorded **before** enqueuing, and
the poll filters on it. Without that, a rerun with the same `--backup-id` (identical command
string) matches a stale `success` row from a prior attempt and reports success without creating
or uploading anything.

## DN-12 — Where ClickHouse data goes is the sidecar's decision, not this script's

The sidecar's own `S3_BUCKET`/`S3_PATH` carry the documented per-component overrides
(`clickhouse.backup.s3.bucket` / `.path`). So the script asks the sidecar where it will write
and only redirects when it is about to write somewhere this run does not own.

Guessing from "was `--s3-prefix` passed?" was wrong: the CronJob always passes it, so a
scheduled run silently overrode a deliberate per-component override while a manual run honoured
it — the same install writing ClickHouse to two different roots depending on how it was
invoked. When the sidecar points elsewhere the script honours it, says so loudly, and records
the real destination in the manifest, because otherwise a "complete" backup has a ClickHouse
half no tooling can locate.

## DN-13 — Concurrent manifest writes are merged under a lock

With `--backup-id`, one process per component (the documented workflow) each writes the SAME
`manifests/<id>.json`. Without a merge the last finisher erases the other components from the
index and restore cannot find them.

The read's STATUS decides what an empty result means. `|| true` conflated "could not read it"
with "there is no manifest yet", so a single timed-out read (a PMM pod being replaced mid-run
was enough) made the last finisher overwrite the shared manifest with only its own component —
erasing its siblings from the restore index while their data sat in the bucket, unreferenced. A
failed read is only forgiven when absence can be positively established (DN-04).

The lock is a `Lease` named `pmm-backup-manifest-<id>`, not a local `mkdir`. It used to be the
`mkdir`, which only serialises writers that share a filesystem — while the writers of one backup
id are separate *processes* by design, and a laptop and the backup-tools pod share nothing. The
lock was therefore absent in exactly the case the merge exists for.

Two details that a Lease makes easy to get wrong, and that both shipped wrong once:

- The lease name must be a legal object name. `--backup-id` accepts `[A-Za-z0-9_-]`, so
  `--backup-id Pre_Upgrade` produced `pmm-backup-manifest-Pre_Upgrade`, which the apiserver
  rejects as **Invalid**, not `AlreadyExists`. With the error discarded, all 60 retries fell
  through to `sleep 1` and the manifest was then written with no merge protection at all — a
  60-second delay and a silent loss of the guarantee. `lease_name` now folds to a DNS-1123
  subdomain, and a create error that is not `AlreadyExists` is logged and breaks the loop
  instead of being retried for a minute.
- Taking over an expired lease needs a precondition. `kubectl patch --type=merge` has no way to
  express one, so it always won: two writers that both judged the lease expired both "took
  over" and serialised nothing. The takeover is a `kubectl replace` carrying the observed
  `resourceVersion`, so exactly one wins and the loser gets a 409.

Best-effort with a bound: if the lease cannot be taken within 60s the manifest is written
unmerged, because the component data is already uploaded and refusing to write the index would
be strictly worse. The positively-established-absence rule above is what actually protects the
siblings' entries.

**Standing idea:** per-component manifest fragments would remove the read-merge-write, and the
lock with it.

## DN-14 — Only a complete, full-scope backup may move `latest`

`latest` is the DR pointer and `--backup-id latest` follows it blindly, so a single-component
run (an ad-hoc ClickHouse incremental, say) must not move it — restoring `latest` would then
silently restore just that one component. The decision is made on the MERGED manifest.

## DN-15 — Validate everything before the point of no return

`scale_down_pmm()` is the point of no return: past it, a missing ClickHouse remote, an absent
`/srv` tarball, a shard-count mismatch or a non-existent ServiceAccount all surface halfway
through a restore with PMM at 0 replicas and no automatic way back.

The gate fails CLOSED, names the `--skip-<component>` flag that would drop each component
deliberately, and does **not** short-circuit: every component is validated so one run reports
every problem instead of making the operator re-run to discover them one at a time.

Each check distinguishes three outcomes, never two: present / genuinely absent / **the check
itself failed**. A fail-closed gate that reports "your data is gone" when the truth is "I could
not look" refuses a good restore mid-incident and sends the operator hunting a backup problem
that does not exist.

## DN-16 — Size, not just non-empty

`size > 0` passes a *truncated* upload — a `pg_dump` that died mid-stream while rclone stored
the partial bytes, or a `/srv` tarball whose upload was cut short. Those failed inside
`pg_restore`/`tar` with PMM already at 0. The manifest therefore records each object's byte
count and the gate compares expected against actual.

Content hashes are deliberately **not** recorded for bulk objects: hashing a multi-GB dump means
downloading every object back on every run, which would dominate the backup's runtime. The
encryption key — the one small object, and the one whose silent corruption is least
recoverable — does get a real sha256, verified before it is applied.

## DN-17 — Bucket-controlled names reach a root shell

`vm_src_subdir_for_ord` / `pmm_src_subdir_for_ord` return directory names read from a **listing
of the backup store**, and on the pmm-server path that name reaches a `sh -c` inside a pod
running as **root** with the data PVC mounted. Same threat model that made `--backup-id`, the
`latest`-resolved id and `MF_CH_NAME` charset-checked; these two resolvers were the gap.

Legitimate values are Kubernetes pod names (DNS-1123), so anything outside `[A-Za-z0-9_.-]` is
refused. Candidates are read **line by line**, never `for x in $(...)`: word-splitting would
turn `harmless name-0` into fragments, and the fragment `name-0` would pass a per-word check
that the whole name must fail. Paths are additionally passed to `sh -c` as positional
arguments, so the script text is a fixed string no value can alter.

## DN-18 — Ordinal mapping, not name splicing

The backup stores per-pod directories named after the SOURCE pods. Restoring into a different
release or namespace gives differently-named TARGET pods, so the target name cannot be spliced
into the path. The backup directory whose trailing `-N` matches the target pod's ordinal is used
instead — which is what makes cross-namespace DR restores work.

There is no silent fallback to the target pod's own name: an empty lookup means the listing
failed or the backup lacks that ordinal, and restoring from a guessed path wasted a full run
once already.

## DN-19 — Temp pods hold RWO data PVCs

`vmrestore` and the `/srv` restore mount a data PVC (`vmstorage-db` / `pmm-storage`) while its
owner is scaled down. Two consequences:

- they carry `karpenter.sh/do-not-disrupt`, because a consolidation eviction mid-restore
  truncates that ordinal's data and fails the run;
- the cleanup trap sweeps them by label. A leaked temp pod holds the RWO PVC and wedges the
  real pod on Multi-Attach at scale-up.

## DN-20 — Signal handlers must exit

`trap release_locks INT TERM` releases the locks in ash/dash and then **resumes** the script —
now running unlocked and effectively unkillable by SIGTERM — so a new run could grab the freed
locks and operate on the same components concurrently. Handlers therefore end in `exit`.
Cleanup is idempotent (pod deletes use `--ignore-not-found`, lock release is ownership-checked),
so the EXIT trap re-running after a signal handler's exit is harmless.

## DN-21 — Partial is failure

A partial dump set cannot restore the cluster, a half-restored vmstorage tier serves
mixed-vintage data, and one PMM replica booting with stale `/srv` while the others got the
restored one is an inconsistent HA cluster. Multi-pod components therefore return 0 on partial
success but only set their success flag on FULL success, and the caller gates on both.

## DN-22 — Shell portability traps that shipped

- `${var:0:16}` is a bash/ash-with-bash-compat extension and a **fatal** "Bad substitution" on
  dash. It aborted a run right after every component had uploaded but before the manifest was
  written, orphaning the data. `sh -n` cannot catch it (it never evaluates expansions), so it
  survived every lint. Use `printf '%.16s'`.
- BusyBox ash expands **every initializer on one `local` line before assigning**, so a variable
  must not be referenced on the same `local` line that sets it.
- `local x=$(cmd)` makes `$?` reflect `local` (always 0), masking the command's real exit code.
  Split declaration from assignment.
- A leading zero makes a value an **octal literal** in arithmetic: retention `"010"` silently
  meant 8 days, and `"08"` aborted the run with "arithmetic syntax error" after the backup had
  already succeeded. Numeric inputs are normalised, not just digit-checked.
- Multi-line string literals whose leading whitespace is YAML **content** must not be
  re-indented with the surrounding shell. Doing so shifted the temp pods' `env:` entries by
  four spaces; every temp restore pod then failed admission with "did not find expected key",
  reported only as "Failed to create restore pod" — with PMM already at 0. Those fragments are
  rendered by functions so their columns are unit-testable.
- A binary being on `PATH` does not mean it runs. Alpine links `jq` against `libjq.so.1` and
  `libonig.so.5`; a `jq` copied without them satisfies `command -v` and exits 127 on every
  call, which the manifest code's `|| true` fallbacks turned into a catalog full of `?` and a
  backup with no index. Presence checks therefore **run** the tool.

## DN-23 — Credentials never on argv

The ClickHouse password is fed through stdin into `CLICKHOUSE_PASSWORD` inside the pod, never on
the `clickhouse-client` argv, so it cannot leak via `ps` in the ClickHouse pod or through the
apiserver's exec audit log — and the query helper runs dozens of times per backup.

## DN-24 — The encryption key is staged, stored, then reaped immediately

The staged plaintext export lives on the (ephemeral) backup-tools pod and must be stored at the
destination, or a DR restore cannot decrypt PostgreSQL. It is written under `umask 077` and the
staged copy is removed as soon as it is stored — **including on failure**, because the key is
always recoverable from the live Secret, and the `.staging` sweep does not run when a backup
fails, so it would otherwise sit readable on a shared volume indefinitely.

`store_write_private` sets the mode **before** the content is written, so there is no window in
which the file exists world-readable. On s3 the object's ACL comes from the bucket.

**Open issue:** the key is stored under the same prefix as the dumps it decrypts, so one bucket
read yields both. The bucket should be SSE-KMS with a key policy distinct from the backup role;
wrapping the key would be better.

## DN-25 — Never `mkdir` a path that might be an rclone remote spec

In s3 mode `comp_path` returns `s3:<bucket>/…`. `mkdir -p` on that created a directory
literally named `s3:<bucket>/…` on the container's writable layer — off-volume and unreaped —
and in one case wrote the plaintext key Secret there. Local scratch uses `staging_dir`, which is
always a real filesystem path.

## DN-26 — S3 access is local, and why it used to not be

The orchestrator had no S3 client of its own and borrowed the rclone sidecar riding on the PMM
pods over `kubectl exec`. That one missing binary produced: a client-pod cache with discovery,
pinning and re-resolve retries; a *dedicated* rclone pod for restores, because the borrowed
sidecars ride on the very PMM pods a restore scales to 0, with its container deliberately named
`pmm-backup` so the exec call sites kept working; an ordering constraint that a restore had to
successfully SCHEDULE A POD before it could read its own manifest, plus a degraded
"checks skipped" path for when it could not; and a 30s exec budget on every catalog read.

All of that was cache coherency for a borrowed binary, not backup logic. The backup-tools
container now installs rclone and jq at start-up and the pod carries its own S3 credentials.

Two things the move *cost*, both since fixed, and both worth stating because they are what
in-processing an external tool tends to lose:

- **The bounds went with the exec.** Every borrowed call was wrapped in
  `timeout ${KUBECTL_STATUS_TIMEOUT}` / `${KUBECTL_EXEC_TIMEOUT}`; the local calls were bare
  `rclone`, so an endpoint that accepts the connection and never answers blocked for rclone's
  own defaults (5m idle x 3 retries). `list` hung, the restore pre-flight that must not "stall
  a --dry-run for ten silent minutes" did exactly that, and `S3_PRUNE_MAX_SECONDS` became
  unenforceable because it is checked only *between* ids. Reads and deletes now carry a wall
  clock (`RCLONE_TIMEOUT`, `RCLONE_PURGE_TIMEOUT`); every call, streams included, carries
  rclone's own `--timeout`/`--contimeout`. `rcat` deliberately gets no wall clock — it streams
  multi-gigabyte `pg_dump` output, and a wall clock there kills healthy backups of large
  databases.
- **The install became a single point of failure for DR.** `apk add jq rclone || exit 1` as the
  container's main command CrashLooped the whole Deployment wherever apk cannot reach a
  repository — an air-gapped cluster, an egress policy, or a `tools.image` override that already
  ships both tools but has no working apk (which `values.yaml` documents for exactly those
  mirrors). Since this pod is the restore path, that took DR out with it, and a CrashLooping pod
  cannot be exec'd into to run a restore by hand. It now probes first, installs only what is
  missing, never exits non-zero, and lets the readinessProbe report the pod as unusable.

Two things deliberately did **not** move: component payloads still go pod → S3 directly
(`vmbackup`, `clickhouse-backup`, and the in-pod `tar | rclone rcat` for `/srv`), because bytes
must never stream through this process. What is local is control-plane I/O — the manifest, the
`latest` pointer, catalog listings, size probes, retention deletes — plus `pg_dump`/`pg_restore`,
which had to pass through here anyway and now make one hop instead of two.

## DN-27 — `--request-timeout` breaks in-cluster discovery

The `timeout` command wraps kubectl instead of using its `--request-timeout` flag: that flag
breaks kubectl's in-cluster API server discovery when running inside a pod (kubectl falls back
to `localhost:8080` instead of using the ServiceAccount token). Discovered on kubectl v1.35.

## DN-28 — vmbackup/vmrestore need the endpoint as a flag

They do not read S3 endpoint environment variables; a custom endpoint must be passed as
`-customS3Endpoint` (which expands to nothing for AWS S3).

## DN-29 — vmselect must be bounced after a VM restore

vmstorage comes back with new pod IPs while vmselect holds persistent connections to the old
ones, which black-hole queries afterwards ("cannot flush labelName to conn" / partial results in
the UI). vmselect is deleted so it re-resolves. The scale-back is also health-checked: masking
it let a run report success with the VM tier left at 0 replicas.

## DN-30 — `/srv` archives exclude the mount point itself

Each top-level entry of `/srv` is archived as its own member (`cd /srv; tar … $(ls -A …)`), not
`/srv` itself and not the `./` entry, and `lost+found` is skipped. If the archive contains a
directory entry for the `/srv` mount point, restore makes tar chmod/utime that root-owned mount
point as a non-root user → "Operation not permitted" → tar exit 2.

On restore, `/srv/ha` is dropped so PMM re-bootstraps its memberlist cleanly: the backed-up raft
state names the SOURCE members, which do not exist in the target cluster.

## DN-31 — A benign rclone error on every purge

`ERROR : ... Failed to read versioning status, assuming unversioned: ... AccessDenied` — rclone
probes bucket versioning to pick a delete strategy, the backup credentials intentionally do not
grant `s3:GetBucketVersioning`, so the probe 403s, rclone falls back to unversioned deletes and
the purge succeeds. Do not "fix" it by widening the IAM policy.

## DN-32 — Metrics must never fail the run

The metrics writers are called as plain statements under `set -e`, after every component, the
manifest and retention have already succeeded. An unguarded `mkdir`/`cat`/`mv` turned a full,
restorable backup into a run that died with no summary and a non-zero exit — a read-only or
full metrics volume is enough, and `METRICS_DIR` is not derived from `--backup-dir` so it can be
absent on an ad-hoc run. Reporting a good backup as failed is far worse than losing a gauge.

## DN-33 — Cross-namespace restore specifics

- The exported Secret carries the SOURCE namespace in its metadata, so it is rewritten to the
  target namespace before `kubectl apply` (handles JSON and YAML).
- `clickhouse-backup restore_remote <name>` looks the name up under the `S3_BUCKET`/`S3_PATH`
  baked into the sidecar's env at pod start, which for a DR restore point at the TARGET
  instance's prefix. They are overridden via the tool's own `--env` flags (verified on 2.8.0:
  trailing flags after the positional `remote` are parsed and honoured).
- A namespaced Role yields 403 — not 404 — for an object that exists in another namespace, so
  object-existence checks distinguish Forbidden from NotFound by kubectl's stderr text.

## DN-34 — `pg_restore` exits non-zero on warnings

`--clean --if-exists` on a fresh database produces "does not exist, skipping" warnings and a
non-zero exit. A non-zero exit **with `error:` lines** is a real failure (empty input, corrupt
dump, permissions) and must fail the restore; warnings alone must not.

## DN-35 — The `latest` pointer is bucket-controlled input

`--backup-id latest` resolves to an id read from an object any writer to the prefix can create,
and that id flows into single-quoted `sh -c` strings run inside component pods and a
root-privileged temp pod. The charset check is therefore applied **after** resolution, not only
to what the operator typed.

## DN-36 — There is no cluster-wide point-in-time

PostgreSQL, ClickHouse, VictoriaMetrics and `/srv` are captured independently, seconds to
minutes apart, and in the documented concurrent workflow by different processes. Each component
is internally consistent — `pg_dump` takes a transaction snapshot, `vmbackup` snapshots,
`clickhouse-backup` freezes — but they are **not consistent with each other**.

This is fine for PMM's data model (metrics and QAN are append-mostly, and the inventory in
PostgreSQL tolerates being slightly ahead or behind), but it must not be discovered during a
post-mortem. The manifest therefore states it as data (`consistency: "per-component"` plus a
note), and `--help` says it too. An RPO figure derived from these backups has to use the id's
timestamp **plus the run duration**, not the timestamp alone.

Making it a true point-in-time would need coordinated snapshots across four engines with
different snapshot primitives — a much bigger design, not a tweak.

## DN-37 — Locks are Leases, and expiry is never guessed

Locks are `coordination.k8s.io` Leases named `pmm-backup-<component>` in the namespace, plus a
short-lived `pmm-backup-manifest-<id>` around the concurrent-manifest merge.

They used to be `mkdir` locks on `BACKUP_DIR` with a `kill -0 <pid>` liveness check. That only
excludes processes sharing a filesystem **and** a PID namespace, while the thing being protected
is a database in the cluster: a restore run from a laptop and the CronJob's backup in the pod
could write the same database concurrently. In shared mode the lock lived on the RWX volume,
where a foreign PID is either a false "held" or a wrongly-stolen live lock.

Four rules, each of which had a first version that did not hold:

- **Creation is the atomic operation.** `kubectl create`, never `apply` — apply would take over
  a live lock.
- **A takeover requires demonstrated expiry.** `lease_expired` returns three states, and
  "cannot tell" (unparseable `renewTime`, missing duration) is **not** expired. Reading it as
  expired is how two runs come to write one database. This is also why the timestamp conversion
  is arithmetic rather than `date`-based: see DN-07 for how a local-time parse turned every
  live lease into an expired one east of UTC, and every stale lease into a permanent one west
  of it.
- **A takeover must be exclusive.** `kubectl patch --type=merge` cannot express a precondition,
  so it *always* succeeded: two runs that both saw the lease expired both took it over, and a
  takeover racing the real holder's renewer silently stole a live lease. The takeover is a
  `kubectl replace` carrying the `resourceVersion` that was observed, and the observation is a
  single `kubectl get` — three separate gets could see three generations of the object, so the
  holder named in the log need not be the holder whose `renewTime` was judged.
- **Held leases are renewed** by a background renewer for as long as the operation runs, so a
  long backup does not outlive its own lease. Crucially the renewer must **not** outlive the
  orchestrator, and "it dies with the process" was simply not true: `cron-backup.sh` detaches
  the run with `setsid` inside the long-lived backup-tools pod, so a SIGKILL or the OOM killer
  never runs the EXIT trap. The renewer then kept patching `renewTime` for the life of the POD,
  the leases never expired, and every later backup and restore aborted on a lock whose holder
  no longer existed — the schedule stayed wedged until someone deleted the Leases by hand. It
  now re-checks that its parent is alive before each renewal, with a `LOCK_RENEWER_MAX_SECONDS`
  backstop for a recycled PID.

Needs `coordination.k8s.io/leases: get,list,create,update,patch,delete` — shipped in the chart's
backup Role.

## DN-38 — Component results are one object

Every component writes its outcome into a single JSON object (`result_set`), and the manifest,
the run summary and the Prometheus metrics all read from it. Before, five near-identical global
families — about thirty variables — were set by the component, read by `write_manifest`, read
again by the summary and again by the metrics writer: a dozen places to touch to add one
component, and the shape that lets a component be handled in one consumer and forgotten in
another.

It is deliberately in memory rather than fragment files on disk: the manifest is the restore
index, and routing it through a filesystem would add a way for a successful component to vanish
from the index that an in-process variable does not have.

One trap found while building it: `printf '%s' "" | jq -R` produces **no output at all** (raw
input reads lines, and there are none), and that empty string then fails `--argjson` — so a
component with no per-object sizes lost its manifest entry entirely instead of being recorded as
failed. Use `jq -n --arg`.

Two consequences of "one object" that the first version got backwards, both of which turn a
failure into something that looks like a success:

- **`result_set` must never return non-zero.** Every call site is a bare statement, so under
  `set -eu` a non-zero status aborts the run — after every component has uploaded and *before*
  `write_manifest`, which orphans the data in the bucket with no restore index. That is the
  precise failure this object was introduced to prevent, and one non-JSON `--argjson` value (the
  `jq -R` trap above, an empty `bytes`) was enough to cause it. It now logs loudly, records the
  component as `failed` rather than dropping it, and always returns 0.
- **An absent entry is not "did not run".** Only components that ran appear in the object, so
  `write_manifest` no longer has to re-derive what was selected — but that makes an absent entry
  indistinguishable from "not selected" everywhere downstream. A component that failed *early*
  returned before its own `result_set`, and therefore printed "⊘ Skipped" in the summary, never
  reached the manifest (so retention never reclaimed whatever bytes it did land), and never had
  its `.prom` rewritten — so the previous run's `pmm_ha_backup_last_success 1` kept being
  scraped and a **total** backup failure looked green in Prometheus. `record_backup_result` is
  the one place every component's outcome passes through, so the fallback entry is created
  there rather than at each of the dozen early returns.

The encryption key is the one component whose entry is not written by the component itself:
`backup_encryption_key` calls `result_set` only on success, so `write_manifest` records the
status it is handed. Without that, a backup whose key export **failed** was byte-for-byte
indistinguishable in the restore index from one taken on an install with no encryption
configured, and the restore gate said `encryption(absent)` instead of `encryption(failed)` —
losing the only signal that that run's PostgreSQL dumps cannot be decrypted after a DR.

## DN-39 — Cluster object names are read, not assumed

The restore mounts data PVCs **by name**: `pmm_storage_pvc_name()` for `/srv`,
`vmstorage_pvc_name()` for each vmstorage shard. A name that does not resolve is not a
mismatch the pod reports — it simply stays `Pending` until the 300s readiness wait gives up,
and it does that *after* `scale_down_pmm()`, on the wrong side of the point of no return
DN-15 is built around.

`PMM_STORAGE_PVC_PREFIX` used to default to `pmm-storage-`. That is not a fact about the
cluster; it is the default of `storage.name`, a documented chart value that names the PMM
StatefulSet's `volumeClaimTemplate`. So the chart and this script each held a copy of one
name, in two languages, with nothing keeping them equal — and any install that set
`storage.name` restored `/srv` by mounting a PVC that had never existed.

The rule is now: **the object that owns a name is the one asked for it.** A StatefulSet names
its per-ordinal PVCs `<volumeClaimTemplate>-<sts>-<ordinal>`, so the template's own name *is*
the prefix, and `pmm_storage_pvc_prefix()` reads it from the live StatefulSet — selecting the
template by the mount path (`${PMM_SRV_PATH}`) rather than by position, because position is an
ordering this file does not own either. The env var survives as an override for a spec that
cannot be read that way; it is no longer the source of truth.

Deriving the name is necessary but not sufficient: a derivation can itself be wrong, and it
would still fail after the scale-down. So the pre-flight gate now proves the PVC **exists**,
per ordinal, for both components, through the same resolver the restore will use — a check the
backup Role already had the `persistentvolumeclaims: get` verb for. Asking the same resolver
twice is deliberate: the gate is proving the object is there, not proving the resolver agrees
with itself.

This applies past PVCs. Container names, labels and image references are equally chart-owned;
where this file must hardcode one, it is a coupling that belongs in this note's ledger, not a
default that quietly disagrees with the chart.

## DN-40 — Retention answers to the catalog, not to the run that called it

Taking a backup and reclaiming old ones are two jobs. They shared an entry point because they
happen to want the same credentials and the same storage layer, and that sharing quietly made
one the other's trigger: `cmd_backup` ran the sweep only `if [ "${all_success}" = "true" ]`.

The intent was sound — do not let an age-based sweep keep deleting good backups while a broken
install produces no new ones. The instrument was not. It made "should anything be deleted?" a
property of *this process's luck* rather than of what the bucket holds, and the two are not the
same question:

1. One component fails every night — a ClickHouse sidecar that was never deployed, a `vmbackup`
   sidecar left disabled, a PG pod that lost its label.
2. `record_backup_result` sets `all_success=false`, correctly: the run is partial.
3. `cleanup_old_backups` is skipped. It is skipped again the next night, and every night after.
4. Nothing else ever called it — there was no other entry point — so retention had stopped
   entirely, for the whole install, over one component.
5. The other three components keep succeeding and keep landing bytes. `list` shows a healthy
   catalog. The only symptom is a bucket that grows without bound, and it is discovered as a
   storage bill or a full RWX volume months later.

Two changes, and they are separable on purpose:

**The guard now states the property directly.** `prune_expired_backups` refuses unless at least
one *retained* backup is `status: complete` — that is the real invariant ("never prune down to
nothing restorable"), where `all_success` was a proxy for it. It is strictly stronger than the
older `kept_parseable` count, which proved only that some object survived, not that anything
restorable did. Because the sweep can now judge for itself, it no longer needs a caller to
judge for it, and `cmd_backup` calls it unconditionally.

**Retention got its own entry point.** `pmm-backup.sh prune` runs the sweep and nothing else, so
it can be scheduled independently of the backup. That also relaxes a coupling the bounds were
paying for: `S3_PRUNE_MAX_PER_RUN` and `S3_PRUNE_MAX_SECONDS` exist largely so the sweep cannot
overrun the backup CronJob's `activeDeadlineSeconds` while holding that run's component locks.
On its own schedule it answers to its own deadline. It takes no component locks — it touches no
database, and the only data it deletes belongs to ids past the cutoff, which no in-flight backup
can be writing.

## DN-41 — The manifest is a versioned on-storage contract

`manifests/<id>.json` is not an internal data structure. It is written into a bucket that
outlives any one install and is read back by whatever version of this script is running at DR
time — which is routinely an **older** one, because a DR cluster is stood up from a chart
release that predates the bucket's newest backups. Version skew here is the normal case, not
the edge case.

It was unversioned, and the compatibility work had already started without it: `restore_encryption_key`
skips the checksum when a manifest records no `sha256`, and `object_size_state` falls back to a
non-empty test when no per-object size was recorded. Both are field-presence probes standing in
for "which version wrote this", and each new one costs another probe while telling a reader
nothing about what it *cannot* see. Retention writes into the manifest too (`retention_note`,
`status: pruned`), so there is more than one writer of the format.

So the manifest carries `schema`, absent meaning 1, and each reader states what it does with a
version it does not understand — the three answers differ because the consequences do:

- **restore refuses.** It acts on what it reads while PMM is at 0 replicas; misreading where a
  component lives means reporting a partial restore as complete.
- **retention defers the id, keeping the manifest.** Purging the components it recognises and
  then deleting the index would strand the rest — the same reasoning that already defers an id
  whose component key it cannot turn into a path.
- **`list` prints it, flagged `vN-too-new`.** It is read-only, and an operator choosing a backup
  mid-incident needs to see that this id exists and that this binary will not restore it.

**Bump only for a change an older reader would mis-handle**: a component whose data moved, a
field whose meaning changed, a component removed. Adding a new optional field is not a bump —
`// empty` already handles it, which is exactly how `sha256` and `files` were added compatibly.
An unreadable `schema` counts as "newer": a version that cannot be read is a format that cannot
be trusted, and every caller here fails toward caution rather than guessing.

## DN-42 — The component is a label, not a file name

Every backup metric already carries `component="postgresql"` and friends. The writer *also*
split them by file — `postgresql_metrics.prom`, `clickhouse_metrics.prom`, … — encoding one
dimension twice, and the second encoding is the expensive one: a file is not a label, it is a
thing something has to serve.

That put the component list into the serving contract, in three more places:

| Adding a component meant editing | Because |
|---|---|
| `write_component_metrics` call site | a new `<component>_metrics.prom` |
| `backup-tools.yaml` | a new `nc` listener + a new `containerPort` |
| `vmagent.yaml` | a new ~30-line scrape job differing only by port |

Four files, no shared definition, and nothing that fails when one is missed. It was missed:
the orchestrator wrote `pmm-server_metrics.prom` for months while no listener served it and no
job scraped it, so a `/srv` backup failing on **every** PMM pod never reached Prometheus. The
`git log` for that fix adds the fifth listener and the fifth job; it does not remove the reason
there had to be a fifth.

Now `write_backup_metrics` emits one `backup_metrics.prom` holding every component, the pod
serves *whatever `.prom` files exist* on one port, and vmagent has one job. Adding a component
changes a label value and nothing else. The two writers keep separate files (backup and
restore have different lifecycles and write at different times) but use disjoint metric
families, so concatenating them still yields one `HELP`/`TYPE` pair per family.

Two things came out of consolidating that the split had been hiding:

- **The encryption key now has a metric.** It was excluded as having "no size or duration worth
  graphing" — true, and beside the point: whether it succeeded is precisely what a DR-readiness
  alert needs. A run whose key export failed, leaving that night's PostgreSQL dumps
  undecryptable, was indistinguishable in Prometheus from a run on an install with no
  encryption configured.
- **Its status is passed in, not read from `RESULTS_JSON`.** `backup_encryption_key` records a
  result only on success, so deriving the list from that object would have dropped the failure
  case — the same trap DN-38 describes for the manifest, which is why `write_manifest` takes
  the status as an argument too.

## DN-43 — A location a human can read is not a location a program can use

DN-12 established that where ClickHouse writes is the **sidecar's** decision: the script asks,
and when the sidecar points somewhere this run does not own, it honours that rather than
silently overriding a deliberate `clickhouse.backup.s3.bucket/.path`. It then recorded the real
destination in the manifest, "because otherwise a 'complete' backup has a ClickHouse half no
tooling can locate."

It recorded it as a **sentence**: `"clickhouse-backup S3 remote: backup_… at s3://other/path"`,
in the `location` field, which is display text. Nothing read it. `restore_clickhouse` and the
pre-flight gate both went on passing `--env S3_PATH=$(clickhouse_remote_key)` — *this run's*
root — so the honoured override produced a backup that:

1. reported `status: success`, because the upload genuinely succeeded;
2. satisfied `_move_latest`, so **`latest` advanced onto it** — and `latest` is the DR pointer
   that `--backup-id latest` follows blindly (DN-14);
3. failed the pre-flight gate at restore time with "remote backup not found", because the gate
   looked under the root the data is not in;
4. did so for every backup taken while the sidecar disagreed — so an install could hold a
   fortnight of green backups and discover at DR that none of their ClickHouse halves resolve.

The rule this cost us: **anything a later run must act on is a field, not prose.** The manifest
now carries `components.clickhouse.s3_bucket` and `.s3_path` as data, written on every run
rather than only when they differ — a reader must never have to infer "no override recorded
means recompute it from my own settings", because that inference is precisely what breaks when
the two disagree. `ch_restore_bucket()` / `ch_restore_path()` are the single resolver both the
restore and the gate call, falling back to this run's root only for a manifest written before
these fields existed. DN-33 already records what it costs when those two look in different
places; one function is cheaper than a comment asking two call sites to stay in step.

Retention is the third reader, and its answer is different on purpose. It reclaims storage
under **this install's root** and nothing else, so ClickHouse data recorded outside it is not
its to delete — but neither may it delete that id's manifest, which is the only record of where
those bytes are. So such an id takes the same path as a chain-pinned one: purge what is ours,
keep `clickhouse/` and the index, and say so. `location` remains, for the human reading `list`.

## DN-44 — Consent and non-interactivity are different questions

`--force` answered both: it confirmed a destructive restore *and* it was the thing that made a
run without a TTY legal. Because every automated restore therefore had to pass it, "honour
`--force` here" and "disable this check for all automation" became the same sentence — so each
safety gate had to write its own carve-out saying it would not be overridden. Two gates had
already written that comment, word for word, and a third would have had to remember to.

A flag that means two things is a flag whose meaning is decided by whoever reads it last, and
the two questions genuinely differ:

| Question | Asked by | Answer |
|---|---|---|
| Do you accept that this destroys data? | the confirmation prompt | `--yes` |
| Is anyone there to be asked? | `[ -t 0 ]` | the TTY test |
| May this run proceed despite failing check X? | one specific gate | that gate's own flag |

So `--yes` (`-y`) now answers only the first, and the TTY test answers the second on its own.
`--force` remains as a deprecated alias — it is the verb people reach for, and this is a tool
someone types under pressure — but it grants nothing extra.

The third row is the point. A safety gate is never lifted by consent; it is lifted by a flag
that names what is being given up, which is why the encryption-key check answers to
`--skip-encryption-key` and to nothing else. The failure that rule prevents is specific: with
`ENCRYPTION_KEY_OK` excluded from `all_ok`, a restore that silently skipped the key printed
"Restore completed successfully" over PostgreSQL data that cannot be decrypted. A gate worth
having is worth an explicit flag; if a gate is not worth a flag of its own, it is not a gate.

## DN-45 — One table drives every per-component loop

Components were enumerated by hand in fourteen places: argument parsing, `--skip` handling,
pre-flight pod discovery, the lock lists (twice), the backup run, the concurrent-mode suffix,
the "Components:" log line, the restore defaults, the explicit-selection gate, the `do_*`
derivation, the restore verdict, the per-component metric samples and two summaries. Each was a
five-line block that named all five components in order.

That shape has one failure mode and it kept recurring: a component handled in the backup arm and
forgotten in the restore arm. The two arms were written months apart, and nothing connected them
— adding a component meant finding a dozen sites, and *missing one was invisible*, because the
missing case simply never fired.

`COMPONENTS` is now the single row-per-component table, and every one of those loops reads it:

```
key : flag : label : BACKUP_* : RESTORE_* : SKIP_* : MF_*_STATUS : *_OK : sel|nosel
```

Adding a component is a row plus its `backup_<key>` / `restore_<key>` functions. The dispatch is
by name — `backup_$(echo "$key" | tr - _)` — so a row with no function is a loud failure rather
than a silent skip.

Two columns exist only because the mapping is not one-to-one, and both were bugs before they were
columns:

* **`key` vs `flag`.** The encryption key is `encryption` in the manifest, in the metric label
  and in the path, but `--encryption-key` on the command line. One name for both is what produced
  `component="encryption_key"` in the restore metrics and `component="encryption"` in the backup
  metrics — one tool, one directory, one scrape, two spellings, nothing able to join them (DN-42).
* **`sel` vs `nosel`.** On the backup side the encryption key is captured *with* PostgreSQL rather
  than selected on its own, so it must not take part in "the first explicit `--<component>` turns
  the others off" — otherwise `--postgresql` would silently drop the key that decrypts it. It
  still has a `BACKUP_*` variable, because `--skip-encryption-key` is exactly how a backup opts
  out.

`CORE_COMPONENTS` is the four that own a `<component>/<id>/` data path. It is what "full scope"
means: `latest` only advances onto a backup holding all four (DN-14), and the retention sweep's
survivor guard tests the same predicate (DN-40). `LOCK_ORDER` is a *separate* list, spelled out
alphabetically, because lock order is what prevents two runs deadlocking on overlapping sets —
reusing `CORE_COMPONENTS`, which is in pipeline order, would silently remove that property.

## DN-46 — Shared primitives for the operations that must not diverge

Three pairs of near-identical code were merged, all of them chosen because a divergence between
the copies is a *correctness* failure rather than an untidiness:

**`lease_try_acquire`** — `acquire_component_lock` and `write_manifest`'s merge lease each had
their own creation, `AlreadyExists` probe, single state read and `resourceVersion`-guarded
takeover, with two Lease heredocs apiece. On a primitive whose whole job is to stop two processes
writing one database, two implementations mean the safety argument only holds for whichever one
you happen to read. It returns four distinct outcomes, and the distinctions are the point:
`0` acquired, `1` not acquired (with `LEASE_STATE` saying `live` / `unknown` / `norv`), `2` the
attempt itself failed, `3` lost the takeover race. Collapsing `2` into `1` is what makes an
unreachable apiserver read as "the lock is free" (DN-03); collapsing `unknown` into `live` is
what makes a lock nobody can age unrecoverable, and the reverse steals a live one.

**`create_temp_restore_pod`** — the vmrestore and `/srv` restore pods differ in six values (label,
container name, mount path, volume name, security context, env block) and shared every other
line: the leftover-pod sweep, the ownership marker, the create, the log plumbing and the readiness
wait. Both hold an RWO data PVC while its owner is scaled to 0, so a fix applied to one and not
the other strands a real volume and wedges the owner on Multi-Attach at scale-up (DN-19).

**`pod_exec`** — the sibling of `pod_sh` for commands that are a binary with flags rather than a
shell snippet (`vmbackup`, `vmrestore`, `clickhouse-backup`). Both exist so the `--dry-run`
preview *is* the command: the text is supplied once and is both what gets logged and what gets
executed. Four call sites previously re-typed their command as `log` lines beside the real
invocation, which is exactly how a preview comes to show flags the run does not use — and
`--dry-run` is the documented review gate for retention, so a preview that does not match is not
a gate.

The same rule produced `ch_run_action` (the `create` and `upload` poll loops were one loop twice),
`store_list_at` (three copies of one listing body), `comp_at` (six path helpers expressing one
two-axis choice), and `resolved_or_override` (the accessor half of the resolve-once pattern,
which must never log because every call site is inside `$( )`).
