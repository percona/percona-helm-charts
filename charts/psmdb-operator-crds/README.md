# psmdb-operator-crds

A Helm chart for Percona Server for MongoDB Operator Custom Resource Definitions (CRDs).

## Overview

This chart contains the CRDs required by the Percona Operator for MongoDB:
- `PerconaServerMongoDB` - defines a MongoDB cluster managed by the operator
- `PerconaServerMongoDBBackup` - defines a backup for a MongoDB cluster
- `PerconaServerMongoDBClusterSync` - defines a Percona ClusterSync for MongoDB (PCSM) replication job for migrating data into an operator-managed cluster
- `PerconaServerMongoDBRestore` - defines a restore operation for a MongoDB cluster

## Why a Separate CRD Chart?

Helm has a limitation where CRDs placed in the `crds/` directory of a chart are only installed during `helm install` but are never updated during `helm upgrade`. This is by design to prevent accidental data loss.

This separate CRD chart allows you to:
1. **Install CRDs independently** - Deploy CRDs before installing the operator
2. **Upgrade CRDs** - Use `helm upgrade` to update CRDs when new versions are released

## Installation

Install the CRD chart first:

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --create-namespace
```

> **Note:** Deleting CRD chart will trigger deletion of all the custom resources created using the CRDs thus deleting all clusters.
>  Uninstalling percona/psmdb-operator-crds chart should be approached with caution. By default the chart protects against this
>  (`preserveCrds: true`, see [Protecting CRDs from Deletion](#protecting-crds-from-deletion)).

Then install the operator:

```sh
helm install psmdb-operator percona/psmdb-operator --namespace psmdb
```

## Protecting CRDs from Deletion

Deleting these CRDs deletes every custom resource stored under them, i.e. all your
MongoDB clusters. A GitOps tool (Flux, Argo CD, etc.) can trigger this accidentally
by pruning or reinstalling the chart.

To guard against that, the chart sets `preserveCrds: true` by default, which adds the
[`helm.sh/resource-policy: keep`](https://helm.sh/docs/howto/charts_tips_and_tricks/#tell-helm-not-to-uninstall-a-resource)
annotation to the CRDs. Helm then leaves the CRDs in place on `helm uninstall`
instead of deleting them.

If you deliberately want `helm uninstall` to remove the CRDs (for example, in an
ephemeral test cluster), opt out with `preserveCrds: false`:

```sh
helm install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --create-namespace --set preserveCrds=false
```

| Value          | Default | Description                                                                 |
| -------------- | ------- | --------------------------------------------------------------------------- |
| `preserveCrds` | `true`  | Add `helm.sh/resource-policy: keep` to the CRDs so they survive `helm uninstall`. Set to `false` to let uninstall remove them. |

> **Note:** With the default `preserveCrds: true` the CRDs are intentionally left behind on
> uninstall and must be removed manually (`kubectl delete crd ...`) if you truly want them gone.

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

If you have CRDs that were previously installed via the `crds/` directory and want to manage them with this chart, you need to add Helm labels and annotations. **This is required because CRDs installed via the `crds/` directory don't have Helm ownership metadata, which prevents this chart from managing them.**

### Taking Ownership Manually

If you want to take ownership of existing CRDs to manage them with this chart:

```sh
CRDS=(perconaservermongodbs.psmdb.percona.com perconaservermongodbbackups.psmdb.percona.com perconaservermongodbclustersyncs.psmdb.percona.com perconaservermongodbrestores.psmdb.percona.com)
kubectl label crds "${CRDS[@]}" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-name=psmdb-operator-crds
kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-namespace=psmdb
```

Or use Helm 3.17.0+ with `--take-ownership`:

```sh
helm upgrade --install psmdb-operator-crds percona/psmdb-operator-crds --namespace psmdb --take-ownership
```

## Troubleshooting

### Error: "invalid ownership metadata" when installing CRD chart

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