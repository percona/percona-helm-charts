# postgres-operator: A chart for installing the Percona Kubernetes operator for PostgreSQL

This chart implements Percona PostgreSQL operator deployment. The Operator itself can be found here:
* <https://github.com/percona/percona-postgresql-operator>

A job will be created based on `helm` `install`, `upgrade`, or `uninstall`. After the
job has completed the RBAC will be cleaned up.

## Pre-requisites
* Kubernetes 1.16+
* PV support on the underlying infrastructure - only if you are provisioning persistent volume(s).
* At least `v2.5.0` version of helm

## Deployment Details
* <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>

## Chart Details
This chart will:
* deploy a PG Operator Pod for the further PostgreSQL creation in K8S.

### Installing the Chart
To install the chart with the `postgres-operator` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-operator percona/postgres-operator --version 0.1.0 --namespace my-namespace
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
