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
```

### PostgreSQL Operator

```yaml
pg-operator:
  enabled: true
```

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

