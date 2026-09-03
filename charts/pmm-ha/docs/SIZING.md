# Sizing PMM HA

The chart's resource defaults target **~100 monitored nodes**. The tables below
are quoted at 30-day retention; the chart ships with 90-day metrics retention, so
read [Retention is the biggest lever](#retention-is-the-biggest-lever) before
sizing the vmstorage volume. This document explains where the numbers come from,
how to scale them, and which knobs move the footprint most.

Ready-made overrides for larger fleets live in
[`examples/values-500-nodes.yaml`](../examples/values-500-nodes.yaml) and
[`examples/values-1000-nodes.yaml`](../examples/values-1000-nodes.yaml).

## The planning unit

One **monitored node** means one host running `node_exporter` plus one database
service with Query Analytics enabled. Cardinality varies enormously by database
and by which collectors are enabled, so pick your row rather than the average:

| What is monitored | Active series per node |
| --- | --- |
| Host only (`node_exporter`) | ~1,400 |
| Host + PostgreSQL | ~5,400 |
| Host + MySQL, default collectors | ~4,000 |
| Host + MySQL with per-table statistics | 8,000 - 15,000 |
| Host + MongoDB with many collections | 8,000 - 15,000 |
| **Planning default used below** | **5,000** |

At PMM's mixed collection resolutions the effective scrape interval works out to
roughly 14 seconds, so 5,000 series is about **360 samples/second per node**.

If your fleet is MySQL with per-table statistics, or MongoDB with a large
collection count, size one tier up. [Disabling table
statistics](https://docs.percona.com/percona-monitoring-and-management/3/install-pmm/install-pmm-client/connect-database/mysql/improve_perf.html)
is the single most effective way to pull that number back down.

## Formulas

```
samples_per_second = nodes × series_per_node / 14

# 0.9 bytes/sample already accounts for replicationFactor 2 and the index.
vm_bytes_per_day   = samples_per_second × 86400 × 0.9

vmstorage_pvc_per_pod = vm_bytes_per_day × metrics_retention_days
                        / victoriaMetrics.vmstorage.replicaCount
                        × 1.3          # merge headroom

# Query Analytics. Every ClickHouse replica holds a FULL copy - QAN is not sharded.
qan_bytes_per_day     = services × 200 rows/min × 1440 × 20 bytes
clickhouse_pvc_per_pod = qan_bytes_per_day × qan_retention_days × 1.7
```

The `0.9 bytes/sample` and `20 bytes/row` constants are conservative planning
figures. Measured values on a running cluster were 0.363 and 19.8 respectively;
the metrics constant carries a 2.5x safety factor because gauge-heavy database
metrics compress less well than the counter-heavy corpus it was measured on.

Percona's [hardware
requirements](https://docs.percona.com/percona-monitoring-and-management/3/install-pmm/plan-pmm-installation/hardware_and_system.html)
page gives a much larger `nodes × retention_weeks × 1 GB` estimate. That figure
predates the move to VictoriaMetrics and is roughly an order of magnitude above
what this chart actually writes. Use it if you want a procurement number with no
risk attached; use the formula above for capacity planning.

## Profiles

Values are `request → limit` for CPU and memory, and PVC size per pod.

| Component | 100 nodes (default) | 500 nodes | 1000 nodes |
| --- | --- | --- | --- |
| **PMM server** ×3 | 2→4 · 4Gi→8Gi · 40Gi | 4→8 · 8Gi→16Gi · 40Gi | 6→12 · 12Gi→24Gi · 40Gi |
| **HAProxy** ×3 | 250m→1 · 128Mi→512Mi | 500m→2 · 256Mi→1Gi | 1→4 · 512Mi→2Gi |
| **vminsert** | ×2 · 200m→1 · 512Mi→2Gi | ×3 · 500m→2 · 1Gi→2Gi | ×3 · 1→4 · 1Gi→4Gi |
| **vmstorage** ×3 | 500m→2 · 2Gi→4Gi · 50Gi | 1→4 · 6Gi→12Gi · 200Gi | 2→8 · 12Gi→24Gi · 400Gi |
| **vmselect** | ×2 · 500m→2 · 1Gi→4Gi | ×2 · 1→4 · 2Gi→8Gi | ×3 · 2→8 · 4Gi→16Gi |
| **vmauth** | ×2 · 100m→500m · 128Mi→512Mi | ×2 · 300m→1 · 256Mi→1Gi | ×3 · 500m→4 · 512Mi→2Gi |
| **vmagent** ×2 | 250m→1 · 512Mi→1Gi | unchanged | unchanged |
| **ClickHouse** ×3 | 1→4 · 4Gi→8Gi · 50Gi | 2→6 · 8Gi→16Gi · 200Gi | 4→8 · 16Gi→32Gi · 400Gi |
| **CH Keeper** ×3 | 250m→1 · 512Mi→1Gi · 5Gi | unchanged · 5Gi | unchanged · 10Gi |
| **PostgreSQL** ×3 | 500m→2 · 1Gi→4Gi · 10Gi | 1→4 · 2Gi→8Gi · 30Gi | 2→4 · 4Gi→16Gi · 50Gi |
| **pgBouncer** ×3 | 100m→500m · 128Mi→512Mi | 250m→1 · 256Mi→1Gi | 500m→2 · 512Mi→1Gi |

PVC sizes above assume **30 days** of retention. The chart ships with 90-day
metrics retention, which needs roughly three times the vmstorage PVC — see the
next section.

| | 100 nodes | 500 nodes | 1000 nodes |
| --- | --- | --- | --- |
| Active series | 500k | 2.5M | 5M |
| Ingest rate | 36k samples/s | 180k samples/s | 360k samples/s |
| Metrics growth (replicationFactor 2) | 2.8 GB/day | 14 GB/day | 28 GB/day |
| QAN growth (per ClickHouse replica) | 0.6 GB/day | 2.9 GB/day | 5.7 GB/day |
| **CPU requests** | ~17 | ~32 | ~58 |
| **Memory requests** | ~40Gi | ~84Gi | ~154Gi |
| **Storage total** | ~465Gi | ~1.6Ti | ~3.2Ti |
| **Minimum workers (3 AZ)** | 3 × 8 vCPU / 32Gi | 3 × 16 vCPU / 64Gi | 3 × 24 vCPU / 96Gi |

## Retention is the biggest lever

Metrics and Query Analytics are retained by two independent mechanisms, and in an
HA deployment neither knows about the other:

| Data | Setting | Enforced by | Default |
| --- | --- | --- | --- |
| Metrics | `victoriaMetrics.vmstorage.retentionPeriod` | VictoriaMetrics operator | `90d` |
| Query Analytics | PMM's own data retention setting | `qan-api2` against ClickHouse | 30 days |

That split is deliberate rather than accidental: the two have very different
storage economics. A metric sample costs well under a byte in VictoriaMetrics at
`replicationFactor: 2`, while a QAN row costs ~20 bytes in ClickHouse and every
one of the three ClickHouse replicas holds a full copy.

`dataRetentionDays` is an optional single value that drives both. Leave it empty
— the default — and the chart does not interfere with either mechanism, which
also leaves retention adjustable from the PMM settings page. Set it and it takes
precedence over `vmstorage.retentionPeriod`, and PMM will refuse to change data
retention from the UI or API for as long as it is set.

Storage scales close to linearly with retention:

| Retention | vmstorage PVC per pod, 100 / 500 / 1000 nodes |
| --- | --- |
| 30 days | 50Gi / 200Gi / 400Gi |
| 90 days (chart default) | 150Gi / 600Gi / 1.2Ti |

### The default PVC does not hold the default retention

`vmstorage.storageSize` defaults to `50Gi`, which holds roughly **30 days** at
100 monitored nodes, not the 90 days `retentionPeriod` asks for. At that point
vmstorage stops accepting writes rather than dropping old data. Pick one:

* set `dataRetentionDays: 30` to bring retention down to what the disk holds, or
* raise `vmstorage.storageSize` to 150Gi (100 nodes) per the table above.

Neither default is changed automatically, because one deletes data and the other
forces a PVC expansion on every existing install.

**Lowering retention on a running install deletes data older than the new window
on the next reconcile.** There is no confirmation step.

## Why limits sit so far above requests

Two facts shape the request/limit ratios in the write path:

1. **Only the leader works.** HAProxy health-checks
   `/v1/server/leaderHealthCheck`, so a single PMM pod serves every UI request,
   every client `remote_write` and all Query Analytics traffic. The other two are
   warm standbys. The limit therefore has to cover the whole fleet while the
   request is paid three times over.
2. **Clients replay after an outage.** Each PMM client buffers up to 1 GB on disk
   when it cannot reach the server and pushes it as fast as it can on reconnect.
   A failover or a rolling upgrade of a 1000-node fleet releases hundreds of
   millions of buffered samples at once, so HAProxy, vminsert, vmauth and
   vmstorage all need burst headroom of three to five times steady state.

vmstorage is the exception: VictoriaMetrics sizes its internal caches from the
cgroup memory limit, so a very wide gap there causes node overcommit and an OOM
kill under load. Keep its request within roughly 2x of its limit.

## Reducing the baseline

The chart's own vmagent scrapes `kubelet`, `cAdvisor`, `kube-apiserver` and
`kube-state-metrics` in addition to the PMM components. On a mid-sized cluster
that is around 165,000 active series before a single database is monitored -
comparable to 30 monitored nodes. If you already collect Kubernetes metrics
elsewhere, disabling those jobs is the cheapest saving available.

ClickHouse's own `system.*` log tables are also worth attention: on a lightly
loaded install they were measured at 17x the size of the actual Query Analytics
data. Setting a TTL on them, or disabling `trace_log` and
`asynchronous_metric_log`, reclaims most of the ClickHouse PVC.

## Prerequisites

- **`allowVolumeExpansion: true`** on the storage class. Every sizing correction
  at this scale is a PVC expansion; without it the only fix is a reinstall.
- **`kubernetes.io/arch: amd64`** for the PMM and ClickHouse pods. Query
  Analytics requires SSE4.2 and PMM Server has no native ARM64 build, so on
  clusters with mixed or auto-provisioned nodes (Karpenter, EKS Auto Mode,
  Graviton pools) these pods must be pinned.

## Measuring your own install

Rather than trusting the constants above, read them off your own cluster once it
has a day of data. Against vmselect:

```promql
# Unique active series (divide by replicationFactor)
sum(vm_cache_entries{type="storage/hour_metric_ids"})

# Ingest rate, samples/second
sum(rate(vm_rows_inserted_total[10m]))

# Actual disk growth per day, replication and index included
sum(vm_data_size_bytes) - sum(vm_data_size_bytes offset 1d)

# Series contributed by a single node
count({node_name="<your-node>"})
```

Dividing the third query by the second gives your real bytes-per-sample. Feed
that back into the formula in place of `0.9` for a number specific to your
workload.

For Query Analytics, against ClickHouse:

```sql
SELECT formatReadableSize(sum(bytes_on_disk)) AS disk,
       sum(rows) AS nrows,
       round(sum(bytes_on_disk) / nullIf(sum(rows), 0), 1) AS bytes_per_row
FROM system.parts
WHERE active AND database = 'pmm' AND table = 'metrics';
```
