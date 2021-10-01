# pg-db: A chart for installing Percona Distribution for PostgreSQL Operator managed Databases

This chart implements Percona Distribution for PostgreSQL deployment on Kubernets via a Custom Resource object. The project itself can be found here:

* <https://github.com/percona/percona-postgresql-operator>

## Pre-requisites

* [Percona Distribution for PostgreSQL Operator](https://hub.helm.sh/charts/percona/pg-operator) running in you K8S cluster
* Kubernetes 1.18+
* PV support on the underlying infrastructure - only if you are provisioning persistent volume(s).
* At least `v3.2.3` version of helm

## Custom Resource Details

* <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>

## StatefulSet Details

* <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>

## Chart Details

This chart will:

* deploy PG database Pods (Custom Resource -> Deployments) for the further Percona Distribution for PostgreSQL Cluster creation in K8S.

### Installing the Chart

To install the chart with the `pg` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/pg-db --version 1.0.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `pause`                         | Stop PostgreSQL Database safely                                               | `false`                                   |
| `tlsOnly`                       | Force PostgreSQL accept only tls connections                                  | `false`                                   |
| `sslCA`                         | Secret name with CA certificate for PostgreSQL                                | ``                                        |
| `sslSecretName`                 | Secret name with server certificate and key for PostgreSQL                    | ``                                        |
| `sslReplicationSecretName`      | Secret name with server certificate and key for PostgreSQL replication paries | ``                                        |
| `standby`                         | Switch/start PostgreSQL Database in standby mode                                                    | `false`                                   |
| `disableAutofail`                         | Disables the high availability capabilities of a PostgreSQL cluster                                                    | `false`                                   |
| `keepData`                         | Keep database container PVC intact after the cluster removal                                                    | `false`                                   |
| `keepBackups`                         | Keep backups intact after the cluster removal                                                    | `false`                                   |
| `restoreFrom`                         | Set cluster/backup name as data source for a newly created cluster                                                    | `false`                                   |
| `restoreOpts`                         | Set restore (`pgBackrest`) options for restore action                                                    | `false`                                   |
| `defaultUser`                         | Default unprivileged database username                                                    | `pguser`                                   |
| `defaultDatabase`                         | Default user database created from the cluster start                                                    | `pgdb`                                   |
| `targetPort`                         | PostgreSQL port                                                    | `5432`                                   |
| `image.repo`              | PostgreSQL container image repository                                           | `percona/percona-postgresql-operator` |
| `image.pgver`                     | PostgreSQL container version tag                                       | `ppg13`                              |
| `bucket.key`                     | S3-compatible bucket access key                                        |``|
| `bucket.secret`                     | S3-compatible bucket secret key                                        |``|
| `bucket.json`                     | GCS storage json secret (base64 encoded)                                        |``|
| `bucket.s3ca`                     | Put custom CA certificate for your S3-compatible storage                                        |``|
| `pgPrimary.image`                     | Set this variable if you need to use a custom PostgreSQL image                                        | `percona/percona-postresql-operator:1.0.0-ppg13-postgres-ha`                              |
| `pgPrimary.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `pgPrimary.tolerations`                     | PostgreSQL container deployment tolerations | `[]`                              |
| `pgPrimary.volumeSpec.size`                     | PostgreSQL container PVC size | `1G`                              |
| `pgPrimary.volumeSpec.accessmode`                     | PostgreSQL container PVC accessmode | `ReadWriteOnce`                              |
| `pgPrimary.volumeSpec.storagetype`                     | PostgreSQL container PVC storagetype | `dynamic`                              |
| `pgPrimary.volumeSpec.storageclass`                     | PostgreSQL container PVC storageclass | `standard`                              |
| `pgPrimary.expose.serviceType`                     | K8S service type for the PostgreSQL deployment | `ClusterIP`                              |
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false` |
| `pmm.image.repository`              | PMM Container image repository                                           | `percona/pmm-client` |
| `pmm.image.tag`                     | PMM Container image tag                                       | `2.18.0`                              |
| `pmm.serverHost`                    | PMM server related K8S service hostname              | `monitoring-service` |
| `pmm.resources.requests.memory`                    | Container resource request for RAM              | `200M` |
| `pmm.resources.requests.cpu`                    | Container resource request for CPU              | `500m` |
| `backup.image`                     | Set this variable if you need to use a custom pgBackrest image                                        | `percona/percona-postresql-operator:1.0.0-ppg13-pgbackrest`                              |
| `backup.backrestRepoImage`                     | Set this variable if you need to use a custom pgBackrest repo image                                        | `percona/percona-postresql-operator:1.0.0-ppg13-pgbackrest-repo`                              |
| `backup.resources.requests.memory`                     | Container resource request for RAM                                        | `48Mi`                              |
| `backup.volumeSpec.size`                     | PostgreSQL pgBackrest container PVC size | `1G`                              |
| `backup.volumeSpec.accessmode`                     | PostgreSQL pgBackrest container PVC accessmode | `ReadWriteOnce`                              |
| `backup.volumeSpec.storagetype`                     | PostgreSQL pgBackrest container PVC storagetype | `dynamic`                              |
| `backup.volumeSpec.storageclass`                     | PostgreSQL pgBackrest container PVC storageclass | `standard`                              |
| `backup.schedule[0].name`                     | Backup schedule name |``|
| `backup.schedule[0].schedule`                 | Backup `cron` like schedule |``|
| `backup.schedule[0].keep`                     | Keep specified number of backups |``|
| `backup.schedule[0].type`                     | PgBackrest backup type `full/incr/diff` |``|
| `backup.schedule[0].storage`                  | Backup storage name `local/gcs/s3` |``|
| `backup.storages.storage0.bucket`                     | `Should be stated explicitly` Storage bucket |``|
| `backup.storages.storage0.name`                     | `Should be stated explicitly for S3` S3-compatible storage name |``|
| `backup.storages.storage0.type`                     | `Should be stated explicitly for S3` S3-compatible storage type |`s3`|
| `backup.storages.storage0.endpointUrl`              | `Should be stated explicitly for S3` S3-compatible storage endpoint |``|
| `backup.storages.storage0.region`                     | `Should be stated explicitly for S3` S3-compatible storage region |``|
| `backup.storages.storage0.uriStyle`                     | (Optional) S3-compatible storage URI style |`path`|
| `backup.storages.storage0.verifyTLS`                     | (Optional) S3-compatible storage URI style |`true`|
| `pgBouncer.image`                     | Set this variable if you need to use a custom pgbouncer image                                        | `percona/percona-postresql-operator:1.0.0-ppg13-pgbouncer`                              |
| `pgBouncer.size`                     | The number of pgbouncer instanses                                        | `1`                              |
| `pgBouncer.resources.requests.cpu`                     | Container resource request for CPU                                        | `1`                              |
| `pgBouncer.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `pgBouncer.resources.limits.cpu`                     | Container resource limits for CPU                                        | `2`                              |
| `pgBouncer.resources.limits.memory`                     | Container resource limits for RAM                                        | `512Mi`                              |
| `pgBouncer.expose.serviceType`                     | K8S service type for the pgbouncer deployment | `ClusterIP`                              |
| `replicas.size`                     | The number of PostgreSQL replicas | `0`                              |
| `replicas.resources.requests.cpu`                     | Container resource request for CPU                                        | `1`                              |
| `replicas.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `replicas.resources.limits.cpu`                     | Container resource limits for CPU                                        | `1`                              |
| `replicas.resources.limits.memory`                     | Container resource limits for RAM                                        | `128Mi`                              |
| `replicas.volumeSpec.size`                     | PostgreSQL replicas PVC size | `1G`                              |
| `replicas.volumeSpec.accessmode`                     | PostgreSQL replica PVC accessmode | `ReadWriteOnce`                              |
| `replicas.volumeSpec.storagetype`                     | PostgreSQL replica PVC storagetype | `dynamic`                              |
| `replicas.volumeSpec.storageclass`                     | PostgreSQL replica PVC storageclass | `standard`                              |
| `replicas.expose.serviceType`                     | K8S service type for the replica deployments | `ClusterIP`                              |
| `pgBadger.enabled` | Switch on pgBadger | `false` |
| `pgBadger.image`              | pgBadger image                                            | `percona/percona-postgresql-operator:1.0.0-ppg13-pgbadger` |
| `pgBadger.port`                     | pgBadger port                                       | `10000` |
| `secrets.primaryuser`                     | primary user password (in use for replication only)                                       |`autogrenerated by operator`|
| `secrets.postgres`                     | postges user password (superuser, not accessible via pgbouncer)                                       |`autogrenerated by operator`|
| `secrets.pgbouncer`                     | pgbouncer user password                                        |`autogrenerated by operator`|
| `secrets.<default_user>`                     | Default user password                                        |`autogrenerated by operator`|

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
  --set backup.storages.my-s3.bucket=my-s3-bucket \
  --set backup.storages.my-s3.type=s3 \
  --set backup.storages.my-s3.name=my-s3 \
  --set backup.storages.my-s3.endpointUrl='s3.amazonaws.com' \
  --set backup.storages.my-s3.region='us-east-1' \
  --set bucket.key=<AWS-S3-ACCESS-KEY> \
  --set bucket.secret=<AWS-S3-SECRET-KEY>
```

S3 backup and local storages could be set up as follwing

```bash
$ helm install dev  --namespace pgdb . \
  --set bucket.key=<AWS-S3-ACCESS-KEY> \
  --set bucket.secret=<AWS-S3-SECRET-KEY> \
  --set backup.storages.my-s3.type=s3 \
  --set backup.storages.my-s3.name=my-s3 \
  --set backup.storages.my-s3.endpointUrl='s3.amazonaws.com' \
  --set backup.storages.my-s3.region='us-east-1' \
  --set backup.storages.my-s3.bucket=my-s3-bucket \
  --set backup.storages.my-local.type=local
```

GCS and local backup storages:

```bash
$ helm install dev  --namespace pgdb . \
  --set bucket.json=$(cat /path/to/gcs-credentials.json | base64 ) \
  --set backup.storages.my-gcs.type=gcs \
  --set backup.storages.my-gcs.name=my-gcs \
  --set backup.storages.my-gcs.bucket=my-gcs-bucket \
  --set backup.storages.my-local.type=local
```

Set backup schedule as following:

```bash
$ helm install dev  --namespace pgdb . \
  --set "backup.schedule[0].name=sat-night-backup" \
  --set "backup.schedule[0].schedule=0 0 * * 6" \
  --set "backup.schedule[0].keep=3" \
  --set "backup.schedule[0].type=full" \
  --set "backup.schedule[0].storage=local"
```
