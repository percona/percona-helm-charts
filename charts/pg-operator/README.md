# Percona Operator for PostgreSQL

This helm chart deploys the Kubernetes Operator to manage Percona Distribution for PostgreSQL.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-postgresql-operator/)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/index.html)

A job will be created based on `helm` `install`, `upgrade`, or `uninstall`. After the
job has completed the RBAC will be cleaned up.

## Pre-requisites
* Kubernetes 1.19+
* At least `v3.2.3` version of helm

# Installation

This chart will deploy the Operator Pod for the further PostgreSQL creation in Kubernetes.

## Installing the chart
To install the chart with the `pg-operator` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-operator percona/pg-operator --version 1.3.0 --namespace my-namespace --create-namespace
```

## Configuration

The following shows the configurable parameters that are relevant to the Helm
Chart.

| Name | Default | Description |
| ---- | ------- | ----------- |
| fullnameOverride | "" |  |
| rbac.create | true | If false RBAC will not be created. RBAC resources will need to be created manually and bound to `serviceAccount.name` |
| rbac.useClusterAdmin | false | If enabled the ServiceAccount will be given cluster-admin privileges. |
| serviceAccount.create | true | If false a ServiceAccount will not be created. A ServiceAccount must be created manually. |
| serviceAccount.name | "" | Use to override the default ServiceAccount name. If serviceAccount.create is false this ServiceAccount will be used. |
| disable_telemetry | false | Check actual images version at https://check.percona.com. Set `true` for disabling the feature |


## Deploy the database

To deploy Percona Operator for PostgreSQL cluster with disabled telemetry run the following command:

```sh
helm install my-db percona/pg-db --version 1.3.0 --namespace my-namespace --set disable_telemetry="true"
```

See more about Percona Operator for PostgreSQL deployment in its chart [here](https://github.com/percona/percona-helm-charts/tree/main/charts/pg-db) or in the [Helm chart installation guide](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html).
