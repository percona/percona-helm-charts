# Percona Distribution for PostgreSQL

This chart deploys Percona Distribution for PostgreSQL on Kubernetes controlled by Percona Operator.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-postgresql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/index.html)

## Pre-requisites

* [Percona Operator for PostgreSQL](https://hub.helm.sh/charts/percona/pg-operator) running in you Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/tree/main/charts/pg-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html).
* Kubernetes 1.18+
* At least `v3.2.3` version of helm

# Installation

This chart will deploy a PostgreSQL cluster in Kubernetes. It will create a Custom Resource, and the Operator will trigger the creation of corresponding Kubernetes primitives: Deployments, Pods, Secrets, etc.

## Installing the Chart

To install the chart with the `pg` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/pg-db --version 1.3.1 --namespace my-namespace
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
| `keepData`                         | Keep database container PVC intact after the cluster removal                                                    | `true`                                   |
| `keepBackups`                         | Keep backups intact after the cluster removal                                                    | `true`                                   |
| `restoreFrom`                         | Set cluster/backup name as data source for a newly created cluster                                                    | `false`                                   |
| `restoreOpts`                         | Set restore (`pgBackrest`) options for restore action                                                    | `false`                                   |
| `defaultUser`                         | Default unprivileged database username                                                    | `pguser`                                   |
| `defaultDatabase`                         | Default user database created from the cluster start                                                    | `pgdb`                                   |
| `targetPort`                         | PostgreSQL port                                                    | `5432`                                   |
| `image.repo`              | PostgreSQL container image repository                                           | `percona/percona-postgresql-operator` |
| `image.pgver`                     | PostgreSQL container version tag                                       | `ppg14`                              |
| `bucket.key`                     | S3-compatible bucket access key                                        |``|
| `bucket.secret`                     | S3-compatible bucket secret key                                        |``|
| `bucket.json`                     | GCS storage json secret (base64 encoded)                                        |``|
| `bucket.s3ca`                     | Put custom CA certificate for your S3-compatible storage                                        |``|
| `pgPrimary.image`                     | Set this variable if you need to use a custom PostgreSQL image                                        | `percona/percona-postresql-operator:1.3.0-ppg14-postgres-ha`                              |
| `pgPrimary.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `pgPrimary.tolerations`                     | PostgreSQL container deployment tolerations | `[]`                              |
| `pgPrimary.volumeSpec.size`                     | PostgreSQL container PVC size | `1G`                              |
| `pgPrimary.volumeSpec.accessmode`                     | PostgreSQL container PVC accessmode | `ReadWriteOnce`                              |
| `pgPrimary.volumeSpec.storagetype`                     | PostgreSQL container PVC storagetype | `dynamic`                              |
| `pgPrimary.volumeSpec.storageclass`                     | PostgreSQL container PVC storageclass | `standard`                              |
| `pgPrimary.expose.serviceType`                     | K8S service type for the PostgreSQL deployment | `ClusterIP`                              |
| `pgPrimary.expose.loadBalancerSourceRanges`                     | Allow specific IP source ranges for accessing PostgreSQL | `[]`                              |
| `pgPrimary.affinity.antiAffinityType`                     | Pod antiAffinity for PostreSQL db pods `preferred/required/disabled` | `preferred`                              |
| `pgPrimary.affinity.nodeAffinityType`                     | Node antiAffinity for PostreSQL db pods `preferred/required/disabled` | `preferred`                              |
| `pgPrimary.affinity.nodeLabel`                     | Key/value map with node lables specified for nodeAffinity | `key/value`                              |
| `pgPrimary.affinity.advanced`                     | User defined affinity structure to be passed to pods without any processing | `key/value`                              |
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false` |
| `pmm.image.repository`              | PMM Container image repository                                           | `percona/pmm-client` |
| `pmm.image.tag`                     | PMM Container image tag                                       | `2.29.0`                              |
| `pmm.serverHost`                    | PMM server related K8S service hostname              | `monitoring-service` |
| `pmm.resources.requests.memory`                    | Container resource request for RAM              | `200M` |
| `pmm.resources.requests.cpu`                    | Container resource request for CPU              | `500m` |
| `backup.image`                     | Set this variable if you need to use a custom pgBackrest image                                        | `percona/percona-postresql-operator:1.3.0-ppg14-pgbackrest`                              |
| `backup.backrestRepoImage`                     | Set this variable if you need to use a custom pgBackrest repo image                                        | `percona/percona-postresql-operator:1.3.0-ppg14-pgbackrest-repo`                              |
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
| `backup.antiAffinityType`                     | Pod antiAffinity for backup pods `preferred/required/disabled` | `preferred`                              |
| `pgBouncer.image`                     | Set this variable if you need to use a custom pgbouncer image                                        | `percona/percona-postresql-operator:1.3.0-ppg14-pgbouncer`                              |
| `pgBouncer.size`                     | The number of pgbouncer instanses                                        | `3`                              |
| `pgBouncer.resources.requests.cpu`                     | Container resource request for CPU                                        | `1`                              |
| `pgBouncer.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `pgBouncer.resources.limits.cpu`                     | Container resource limits for CPU                                        | `2`                              |
| `pgBouncer.resources.limits.memory`                     | Container resource limits for RAM                                        | `512Mi`                              |
| `pgBouncer.expose.serviceType`                     | K8S service type for the pgbouncer deployment | `ClusterIP`                              |
| `pgBouncer.expose.loadBalancerSourceRanges`                     | Allow specific IP source ranges for accessing pgBouncer | `[]`                              |
| `pgBouncer.exposePostgresUser`                     | Expose root postgres user via pgBouncer | `false`                              |
| `pgBouncer.antiAffinityType`                     | Pod antiAffinity for pgBouncer pods `preferred/required/disabled`| `preferred`                              |
| `replicas.size`                     | The number of PostgreSQL replicas | `2`                              |
| `replicas.resources.requests.cpu`                     | Container resource request for CPU                                        | `1`                              |
| `replicas.resources.requests.memory`                     | Container resource request for RAM                                        | `128Mi`                              |
| `replicas.resources.limits.cpu`                     | Container resource limits for CPU                                        | `1`                              |
| `replicas.resources.limits.memory`                     | Container resource limits for RAM                                        | `128Mi`                              |
| `replicas.volumeSpec.size`                     | PostgreSQL replicas PVC size | `1G`                              |
| `replicas.volumeSpec.accessmode`                     | PostgreSQL replica PVC accessmode | `ReadWriteOnce`                              |
| `replicas.volumeSpec.storagetype`                     | PostgreSQL replica PVC storagetype | `dynamic`                              |
| `replicas.volumeSpec.storageclass`                     | PostgreSQL replica PVC storageclass | `standard`                              |
| `replicas.expose.serviceType`                     | K8S service type for the replica deployments | `ClusterIP`                              |
| `pgBadger.enabled`        | Switch on pgBadger                                                            | `false` |
| `pgBadger.image`          | pgBadger image                                                                | `percona/percona-postgresql-operator:1.3.0-ppg14-pgbadger` |
| `pgBadger.port`           | pgBadger port                                                                 | `10000` |
| `secrets.name`            | Database secrets object name. Object will be autogenerated if the name is not explicitly specified       |`<cluster_name>-users`|
| `secrets.primaryuser`     | primary user password (in use for replication only)                           |`autogrenerated by operator`|
| `secrets.postgres`        | postges user password (superuser, not accessible via pgbouncer)               |`autogrenerated by operator`|
| `secrets.pgbouncer`       | pgbouncer user password                                                       |`autogrenerated by operator`|
| `secrets.<default_user>`  | Default user password                                                         |`autogrenerated by operator`|
| `versionService.url`      | Get availabe product component containers via Version service URL             |`https://check.percona.com`|
| `versionService.apply`    | Filter out available containers from Version service by specified channel     |`disabled`|
| `versionService.schedule` | Cron-like time period for calling Version service                             |`0 4 * * *`|

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

Override all affinity defaults. For instance, user wants the following structure
```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/e2e-az-name
          operator: In
          values:
          - e2e-az1
          - e2e-az2
```
to be put on PostreSQL pods. Here is the corresponding cli call:

```bash
$ helm install dev  --namespace pgdb . \
  --set 'pgPrimary.affinity.advanced.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=kubernetes.io/e2e-az-name' \
  --set 'pgPrimary.affinity.advanced.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=In' \
  --set 'pgPrimary.affinity.advanced.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values={e2e-az1,e2e-az2}'
```