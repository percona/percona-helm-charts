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

> **⚠️ This chart is installed once per cluster and its operators serve every namespace.**
> Uninstalling it stops reconciliation of `PerconaPGCluster`, `ClickHouseInstallation` and
> `VMCluster` resources in **all** namespaces, not just this one — every other `pmm-ha`
> instance on the cluster is affected. Check for other instances first — filter on the chart
> column, not on the release name, since each instance uses a release name of its own:
>
> ```bash
> helm list -A -o json | jq -r '.[] | select(.chart | test("^pmm-ha-[0-9]")) | "\(.namespace)/\(.name)"'
> ```
>
> Reinstalling the chart into a *different* namespace afterwards does **not** recover it: the
> CRDs are kept on uninstall (`helm.sh/resource-policy: keep`) and still carry
> `meta.helm.sh/release-namespace` pointing at the original namespace, so the new install fails
> with `invalid ownership metadata ... release-namespace must equal "<new-namespace>"` and the
> only way out is to hand-patch the annotations on every retained CRD. Reinstall into the
> **same** namespace, or clean up the CRDs deliberately first.

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

Both the ClickHouse and PostgreSQL operators default to watching **all** namespaces
(VictoriaMetrics is already cluster-scoped), so `pmm-ha` custom resources are reconciled no
matter which namespace they live in. Install this dependencies chart **once per cluster**; the
operators then serve every namespace, and you can run a `pmm-ha` instance in each of several
namespaces — for example a disaster-recovery / restore target, or an isolated test instance.

**Run one `pmm-ha` instance per namespace, each with its own Helm release name.** Both halves
of that rule matter:

1. **A separate namespace per instance.** Several of the chart's namespaced objects have fixed
   names that do *not* include the release name — `pmm-ha-haproxy`,
   `pmm-ha-haproxy-init-script`, `monitoring-service`, `pmm-service-account`,
   `haproxy-tls-secret` and `postgresql-init-extensions`. A second instance in the **same**
   namespace collides on those no matter what it is called: the install either aborts on an
   existing resource, or — on an adopt/`--force` path — silently repoints the first instance's
   HAProxy at the second instance's pods.
2. **A distinct release name per instance.** The `pmm-ha` chart's `ClusterRole` and
   `ClusterRoleBinding` are named after `pmm.fullname`, which derives from the release name.
   Those are cluster-scoped, so two instances sharing a release name collide even when they are
   in different namespaces. A distinct release name also flows into the correct pod/peer DNS.

Two per-instance details apply on top of that. Only one instance per cluster can run
`prometheus-node-exporter`, which binds host port 9100, so any additional instance must not
deploy its own. And each namespace needs its own `pmm-secret` **before** you install — see
[Creating PMM Secret Manually](../pmm-ha/README.md#creating-pmm-secret-manually) in the
`pmm-ha` chart README.

> **Note:** each instance runs its own `kube-state-metrics` with cluster-wide read access, so
> every instance ingests and displays object state for the whole cluster, not just for its own
> namespace. Each instance's ServiceAccount likewise holds cluster-wide read/delete on Secrets,
> so instances are not isolated from each other's credentials. Separate namespaces are **not** a
> tenancy boundary here — do not use them as a security boundary between untrusted teams.

### Existing installations: upgrade the operators first

The cluster-wide watch is a **values default**, so an operator release installed before this
version is still namespace-scoped. Upgrade it before installing into a second namespace:

```bash
helm upgrade pmm-ha-operators percona/pmm-ha-dependencies --namespace pmm

# `helm upgrade` runs without --wait, so it returns as soon as the Deployments are patched.
# This change only touches env vars, so it rolls out with an overlap window: a
# `kubectl wait --for=condition=ready pod` would match the still-Ready *pre-upgrade* pod and
# succeed immediately. Wait for the new generation instead.
kubectl rollout status deployment -l app.kubernetes.io/name=pg-operator -n pmm --timeout=300s
kubectl rollout status deployment -l app.kubernetes.io/name=altinity-clickhouse-operator -n pmm --timeout=300s
kubectl rollout status deployment -l app.kubernetes.io/name=victoria-metrics-operator -n pmm --timeout=300s
```

Do **not** reinstall this chart into the new namespace — the VictoriaMetrics operator CRDs are
owned by the first release, and a second install fails with
`invalid ownership metadata ... release-namespace must equal "<new-namespace>"`.

> **⚠️ Order matters — this one is not recoverable by retrying.** If you install `pmm-ha` into
> the second namespace while the operators are still namespace-scoped, the PostgreSQL cluster
> and the ClickHouseInstallation are never reconciled. The PMM pod then parks at `Init:1/2`:
> its `wait-for-clickhouse` init container polls the ClickHouse service in a loop with **no
> timeout**, so the `pmm` container never starts and the StatefulSet never becomes ready. The
> symptom is a pod stuck in `Init`, not an authentication error — check for an unreconciled
> `ClickHouseInstallation` / `PerconaPGCluster` rather than a bad password:
>
> ```bash
> kubectl get chi,pg -n <namespace>          # both should exist and report a status
> kubectl logs <pmm-pod> -n <namespace> -c wait-for-clickhouse
> ```
>
> Upgrade the operators first.

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

