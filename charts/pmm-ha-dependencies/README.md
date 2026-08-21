# PMM HA Dependencies

This Helm chart installs the Kubernetes operators required for deploying Percona Monitoring and Management (PMM) in High Availability mode.

## Overview

This chart is a **prerequisite** for the `pmm-ha` chart. It installs the following operators:

- **VictoriaMetrics Operator** - Manages VictoriaMetrics resources for metrics storage
- **Altinity ClickHouse Operator** - Manages ClickHouse clusters for PMM data storage
- **PostgreSQL Operator** - Manages PostgreSQL clusters for PMM metadata

## Installation Order

**IMPORTANT**: You must install this chart **before** installing `pmm-ha`:

```bash
# Step 1: Install the operators (this chart)
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
helm install pmm-ha-operators percona/pmm-ha-dependencies --namespace pmm --create-namespace

# Step 2: Wait for operators to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-metrics-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=altinity-clickhouse-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=pg-operator -n pmm --timeout=300s

# Step 3: Install PMM HA
helm install pmm-ha percona/pmm-ha --namespace pmm
```

## Uninstallation Order

When uninstalling, follow the **reverse order**:

```bash
# Step 1: Uninstall PMM HA first
helm uninstall pmm-ha --namespace pmm

# Step 2: Wait for PMM resources to be fully removed
kubectl wait --for=delete vmcluster -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s
kubectl wait --for=delete postgrescluster -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s
kubectl wait --for=delete clickhouseinstallation -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s

# Step 3: Uninstall the operators
helm uninstall pmm-ha-operators --namespace pmm
```

## Configuration

### VictoriaMetrics Operator

```yaml
victoria-metrics-operator:
  enabled: true
  crds:
    enabled: true
  admissionWebhooks:
    enabled: true
```

### Altinity ClickHouse Operator

```yaml
altinity-clickhouse-operator:
  enabled: true
  # Watch every namespace so ClickHouseInstallations created outside the operator's own
  # namespace are reconciled. See the note below on why a regexp is used instead of an
  # empty or single-namespace watch list.
  operator:
    env:
      - name: WATCH_NAMESPACES
        value: ".*"
  # Mirror the setting on the metrics-exporter sidecar (it reads its own env).
  metrics:
    env:
      - name: WATCH_NAMESPACES
        value: ".*"
```

### PostgreSQL Operator

```yaml
pg-operator:
  enabled: true
  # Watch every namespace. This also switches the operator's RBAC from a namespaced
  # Role/RoleBinding to a cluster-scoped ClusterRole/ClusterRoleBinding.
  watchAllNamespaces: true
```

> **Privileges — applies to every install, not just multi-namespace ones.** With these
> defaults both operators reconcile custom resources cluster-wide, so installing this chart
> requires permission to create cluster-scoped RBAC (ClusterRole/ClusterRoleBinding) and
> cluster-wide list/watch. On clusters where you cannot create cluster-scoped RBAC (common on
> restricted OpenShift projects) the install will fail. See [Permission issues](#permission-issues).
>
> **Single-namespace users who want least privilege** can scope the PostgreSQL operator back
> down — this keeps its RBAC as a namespaced `Role`/`RoleBinding`:
>
> ```yaml
> pg-operator:
>   watchAllNamespaces: false
> ```
>
> The ClickHouse operator does **not** support scoping to a single extra namespace — a
> one-entry watch list scopes it to that namespace *only* and breaks the primary install.
> See the inline notes in `values.yaml`.

## Multi-namespace support

Both the ClickHouse and PostgreSQL operators default to watching **all** namespaces (VictoriaMetrics is already cluster-scoped), so `pmm-ha` custom resources are reconciled no matter which namespace they live in. You install this dependencies chart **once** per cluster; the operators then serve every namespace, and you can run more than one `pmm-ha` instance in separate namespaces of the same cluster.

**A second `pmm-ha` install must use a different Helm release name.** The `pmm-ha` chart creates cluster-scoped objects — its `ClusterRole` and `ClusterRoleBinding` are named after `pmm.fullname` (derived from the release name). A second install with the same release name collides with the first on those two objects, even when the two installs are in different namespaces. Use a distinct release name (which also flows into the correct pod/peer DNS), for example:

```bash
# First instance
helm install pmm-ha percona/pmm-ha --namespace pmm

# Second instance in another namespace, different release name
helm install pmm-2 percona/pmm-ha --namespace pmm-2 --create-namespace
```

### Existing installations: upgrade the operators first

The cluster-wide watch is a **values default**, so an operator release installed before this
version is still namespace-scoped. Upgrade it before installing into a second namespace:

```bash
helm upgrade pmm-ha-operators percona/pmm-ha-dependencies --namespace pmm
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=pg-operator -n pmm --timeout=180s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=altinity-clickhouse-operator -n pmm --timeout=180s
```

Do **not** reinstall this chart into the new namespace — the VictoriaMetrics operator CRDs are
owned by the first release, and a second install fails with
`invalid ownership metadata ... release-namespace must equal "<new-namespace>"`.

> **⚠️ Order matters — this one is not recoverable by retrying.** If you install `pmm-ha` into
> the second namespace while the operators are still namespace-scoped, the PostgreSQL cluster
> and the ClickHouseInstallation are never reconciled. PMM then boots with no PostgreSQL, and
> Grafana initializes with the **default `admin` password** — `PMM_ADMIN_PASSWORD` from
> `pmm-secret` is only applied at first initialization, so it stays that way and the
> `pmm-token-init` job loops on 401. Upgrade the operators first.

## Requirements

- Kubernetes 1.24+
- Helm 3.8+
- PV provisioner support in the underlying infrastructure (for operator storage)

## Chart Dependencies

This chart includes the following dependencies:

| Repository | Name | Version |
|------------|------|---------|
| https://victoriametrics.github.io/helm-charts/ | victoria-metrics-operator | 0.56.4 |
| https://helm.altinity.com | altinity-clickhouse-operator | 0.25.4 |
| https://percona.github.io/percona-helm-charts/ | pg-operator | 2.8.0 |

## Important Notes

### CRD Retention After Uninstall

**By design, Custom Resource Definitions (CRDs) are NOT deleted when you uninstall this chart.** This is standard Helm 3 behavior to prevent accidental data loss.

When you run `helm uninstall pmm-ha-operators`:

- **VictoriaMetrics CRDs**: Will display a message: "These resources were kept due to the resource policy"
- **ClickHouse CRDs**: Will be kept silently (no message)
- **PostgreSQL CRDs**: Will be kept silently (no message)

**All three operators keep their CRDs** - VictoriaMetrics just makes it explicit.

#### Why CRDs are Retained

Deleting CRDs automatically deletes ALL custom resources using those CRDs, which could result in:
- Loss of VictoriaMetrics metrics data
- Loss of ClickHouse data
- Loss of PostgreSQL clusters

This safety mechanism ensures you don't accidentally delete production data.

#### Manual CRD Cleanup

**WARNING**: This will remove CRDs cluster-wide and delete ALL custom resources of these types in ALL namespaces! This action will cause permanent data loss.

Only do this if you're completely removing the operators and have no other deployments using them:

```bash
# Remove VictoriaMetrics CRDs
kubectl delete crds $(kubectl get crds -o name | grep victoriametrics)

# Remove ClickHouse CRDs
kubectl delete crds $(kubectl get crds -o name | grep clickhouse)

# Remove PostgreSQL Operator CRDs
kubectl delete crds $(kubectl get crds -o name | grep -E "(postgres-operator|perconapg)")
```

## Troubleshooting

### Operators not starting

Check the operator pods:

```bash
kubectl get pods -n pmm
kubectl logs -l app.kubernetes.io/name=victoria-metrics-operator -n pmm
```

### CRDs not installed

Verify the Custom Resource Definitions are present:

```bash
kubectl get crds | grep -E "victoriametrics|clickhouse|postgres-operator"
```

### Permission issues

Ensure your Kubernetes user has cluster-admin privileges to install cluster-scoped resources (CRDs, ClusterRoles, etc.).

## Support

For issues and questions:
- GitHub Issues: https://github.com/percona/percona-helm-charts/issues
- Percona Forums: https://forums.percona.com/
- Documentation: https://docs.percona.com/percona-monitoring-and-management/

