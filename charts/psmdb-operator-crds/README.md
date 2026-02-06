# psmdb-operator-crds

A Helm chart for Percona Server for MongoDB Operator Custom Resource Definitions (CRDs).

## Overview

This chart contains the CRDs required by the Percona Operator for MongoDB:
- `PerconaServerMongoDB` - defines a MongoDB cluster managed by the operator
- `PerconaServerMongoDBBackup` - defines a backup for a MongoDB cluster
- `PerconaServerMongoDBRestore` - defines a restore operation for a MongoDB cluster

## Why a Separate CRD Chart?

Helm has a limitation where CRDs placed in the `crds/` directory of a chart are only installed during `helm install` but are never updated during `helm upgrade`. This is by design to prevent accidental data loss.

This separate CRD chart allows you to:
1. **Install CRDs independently** - Deploy CRDs before installing the operator
2. **Upgrade CRDs** - Use `helm upgrade` to update CRDs when new versions are released
3. **Use with GitOps tools** - Works with ArgoCD, FluxCD, and other GitOps tools that support server-side apply

## Installation

### Option 1: Install CRDs Separately

Install the CRD chart first:

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --create-namespace
```

Then install the operator:

```sh
helm install psmdb-operator percona/psmdb-operator --namespace psmdb
```

### Option 2: Install CRDs as Dependency

Enable the CRD sub-chart when installing the operator:

```sh
helm install psmdb-operator percona/psmdb-operator --namespace psmdb --create-namespace --set crds.enabled=true
```

## Upgrading CRDs

When upgrading to a new version of the operator, upgrade the CRDs first:

```sh
helm repo update
helm upgrade psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb
```

> **Note:** If you're using Helm 3.17.0 or later, you can use the `--take-ownership` flag when upgrading CRDs that were initially installed via the `crds/` directory:
>
> ```sh
> helm upgrade --install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --take-ownership
> ```

Then upgrade the operator:

```sh
helm upgrade psmdb-operator percona/psmdb-operator --namespace psmdb
```

## Taking Ownership of Existing CRDs

If you have CRDs that were previously installed via the `crds/` directory and want to manage them with this chart, you need to add Helm labels and annotations. **This is required because CRDs installed via the `crds/` directory don't have Helm ownership metadata, which prevents the CRD sub-chart from managing them.**

### Important Limitation

If you install the operator with `crds.enabled=true` when CRDs already exist from a previous installation via the `crds/` directory, Helm will fail with an ownership metadata error. This is expected behavior. You have two options:

1. **Install CRDs separately first** (recommended):
   ```sh
   # Install CRD chart first
   helm install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --take-ownership
   
   # Then install operator with CRDs enabled
   helm install psmdb-operator percona/psmdb-operator --namespace psmdb --set crds.enabled=true
   ```

2. **Keep CRDs disabled** and use existing CRDs:
   ```sh
   # Install operator without CRD sub-chart (uses existing CRDs)
   helm install psmdb-operator percona/psmdb-operator --namespace psmdb
   ```

### Taking Ownership Manually

If you want to take ownership of existing CRDs to manage them with this chart:

```sh
CRDS=(perconaservermongodbs.psmdb.percona.com perconaservermongodbbackups.psmdb.percona.com perconaservermongodbrestores.psmdb.percona.com)
kubectl label crds "${CRDS[@]}" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-name=psmdb-operator-crds
kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-namespace=psmdb
```

Or use Helm 3.17.0+ with `--take-ownership`:

```sh
helm upgrade --install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --take-ownership
```

## Troubleshooting

### Error: "invalid ownership metadata" when enabling CRD sub-chart

If you see an error like:
```
Error: invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by"
```

This means CRDs were previously installed via the `crds/` directory and lack Helm ownership metadata. To fix this:

1. **Use `--take-ownership` flag** (Helm 3.17.0+):
   ```sh
   helm install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --take-ownership
   ```

2. **Or manually add ownership metadata** (see [Taking Ownership](#taking-ownership-of-existing-crds) section above)

3. **Or keep CRDs disabled** and use the existing CRDs:
   ```sh
   helm install psmdb-operator percona/psmdb-operator --namespace psmdb
   # Don't set crds.enabled=true if CRDs already exist from crds/ directory
   ```