# Percona Distribution for PostgreSQL
This chart deploys Percona Distribution for PostgreSQL on Kubernetes controlled by Percona Operator.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-postgresql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/index.html)

## Pre-requisites
* [Percona Operator for PostgreSQL](https://hub.helm.sh/charts/percona/pg-operator) running in you Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/tree/main/charts/pg-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html).
* Kubernetes 1.22+
* At least `v3.2.3` version of helm

# Installation
This chart will deploy a PostgreSQL cluster in Kubernetes. It will create a Custom Resource, and the Operator will trigger the creation of corresponding Kubernetes primitives: Deployments, Pods, Secrets, etc.
NOTE:
```
The PG Operator v2 is not directly compatible with old v1 so it is advised to always specify `--version`
when installing pg-operator or pg-db charts to not accidentally cause upgrade to v2 if you were using v1
previously.
```

## Installing the Chart
To install the chart with the `pg` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/pg-db --version 2.2.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `crVersion`                     | CR Cluster Manifest version                                                   | `2.2.0`                                  |
| `pause`                         | Stop PostgreSQL Database safely                                               | `false`                                   |
| `unmanaged`                     | Start cluster and don't manage it (cross cluster replication)                 | `false`
| `standby`                         | Switch/start PostgreSQL Database in standby mode                                                    | `false`                                   |
| `defaultUser`                         | Default unprivileged database username                                                    | `pguser`                                   |
| `defaultDatabase`                         | Default user database created from the cluster start                                                    | `pgdb`                                   |
| `targetPort`                         | PostgreSQL port                                                    | `5432`                                   |
| `image.repo`              | PostgreSQL container image repository                                           | `percona/percona-postgresql-operator` |
| `postgresVersion`                     | PostgreSQL container version tag                                       | `14`                              |
| `bucket.key`                     | S3-compatible bucket access key                                        |``|
| `bucket.secret`                     | S3-compatible bucket secret key                                        |``|
| `bucket.json`                     | GCS storage json secret (base64 encoded)                                        |``|
| `bucket.s3ca`                     | Put custom CA certificate for your S3-compatible storage                                        |``|
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false` |
| `pmm.image`              | PMM Container image repository                                           | `percona/pmm-client:2.37.0` |
| `pmm.serverHost`                    | PMM server related K8S service hostname              | `monitoring-service` |
| `pmm.resources.requests.memory`                    | Container resource request for RAM              | `200M` |
| `pmm.resources.requests.cpu`                    | Container resource request for CPU              | `500m` |
| `backup.pgbackrest.image`                     | Set this variable if you need to use a custom pgBackrest image                                        | `percona/percona-postresql-operator:2.2.0-ppg15-pgbackrest`                              |
| `backup.jobs.resources.requests.memory`                     | Container resource request for RAM                                        | `48Mi`                              |
| `backup.repos.repo2.s3.bucket`                     | `Should be stated explicitly` Storage bucket |``|
| `backup.repos.repo2.s3.region`                     | `Should be stated explicitly for S3` S3-compatible storage name |``|
| `backup.repos.repo2.s3.endpoint`              | `Should be stated explicitly for S3` S3-compatible storage endpoint |``|
| `proxy.pgBouncer.image`                     | Set this variable if you need to use a custom pgbouncer image                                        | `percona/percona-postresql-operator:1.4.0-ppg14-pgbouncer`                              |
| `proxy.pgBouncer.replicas`                     | The number of pgbouncer instances                                        | `3`                              |
| `proxy.pgBouncer.resources.requests.cpu`                     | Container resource request for CPU                                        | `1`                              |
| `proxy.pgBouncer.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `proxy.pgBouncer.resources.limits.cpu`                     | Container resource limits for CPU                                        | `2`                              |
| `proxy.pgBouncer.resources.limits.memory`                     | Container resource limits for RAM                                        | `512Mi`                              |
| `proxy.pgBouncer.expose.type`                     | K8S service type for the pgbouncer deployment | `ClusterIP`                              |
| `secrets.name`            | Database secrets object name. Object will be autogenerated if the name is not explicitly specified       |`<cluster_name>-users`|
| `secrets.primaryuser`     | primary user password (in use for replication only)                           |`autogrenerated by operator`|
| `secrets.postgres`        | postges user password (superuser, not accessible via pgbouncer)               |`autogrenerated by operator`|
| `secrets.pgbouncer`       | pgbouncer user password                                                       |`autogrenerated by operator`|
| `secrets.<default_user>`  | Default user password                                                         |`autogrenerated by operator`|

Specify parameters using `--set key=value[,key=value]` argument to `helm install`
Notice that you can use multiple replica sets only with sharding enabled.

## Examples
This is great one for a dev Percona Distribution for PostgreSQL cluster as it doesn't bother with backups.

```bash
$ helm install dev  --namespace pgdb .
NAME: dev
LAST DEPLOYED:
NAMESPACE: pgdb
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
```

You can start up the cluster with only S3 backup storage like this

```bash
$ helm install dev  --namespace pgdb . \
  --set backup.repos.repo1.s3.bucket=my-s3-bucket \
  --set backup.repos.repo1.s3.endpoint='s3.amazonaws.com' \
  --set backup.repos.repo1.s3.region='us-east-1' \
```

GCS and local backup storages:

```bash
$ helm install dev  --namespace pgdb . \
  --set backup.repos.repo2.gcs.bucket=my-gcs-bucket 
```