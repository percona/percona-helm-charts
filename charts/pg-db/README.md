# Percona Distribution for PostgreSQL
This chart deploys Percona Distribution for PostgreSQL on Kubernetes controlled by Percona Operator.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-postgresql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/index.html)

## Pre-requisites
* [Percona Operator for PostgreSQL](https://hub.helm.sh/charts/percona/pg-operator) running in your Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/tree/main/charts/pg-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html).
* Kubernetes 1.27+
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
helm install my-db percona/pg-db --version 2.4.3 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                         | Description                                                                                                                                                                                             | Default                                                      |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `finalizers`                      | Finalizers list                                                                                                                                                                                         | `{}`                                                         |
| `crVersion`                       | CR Cluster Manifest version                                                                                                                                                                             | `2.4.1`                                                      |
| `repository`                      | PostgreSQL container image repository                                                                                                                                                                   | `percona/percona-postgresql-operator`                        |
| `image`                           | Postgres image                                                                                                                                                                                          | `percona/percona-postgresql-operator:2.4.1-ppg16.3-postgres` |
| `imagePullPolicy`                 | image Pull Policy                                                                                                                                                                                       | `Always`                                                     |
| `port`                            | PostgreSQL port                                                                                                                                                                                         | `5432`                                                       |
| `postgresVersion`                 | PostgreSQL container version tag                                                                                                                                                                        | `16`                                                         |
| `pause`                           | Stop PostgreSQL Database safely                                                                                                                                                                         | `false`                                                      |
| `unmanaged`                       | Start cluster and don't manage it (cross cluster replication)                                                                                                                                           | `false`                                                      |
| `standby.enabled`                 | Switch/start PostgreSQL Database in standby mode                                                                                                                                                        | `false`                                                      |
| `standby.host`                    | Host address of the primary cluster this standby cluster connects to                                                                                                                                    | ``                                                           |
| `standby.port`                    | Port number used by a standby copy to connect to the primary cluster                                                                                                                                    | ``                                                           |
| `standby.repoName`                | Name of the pgBackRest repository in the primary cluster this standby cluster connects to                                                                                                               | ``                                                           |
| `customTLSSecret.name`            | A secret with TLS certificate generated for external communications                                                                                                                                     | `""`                                                         |
| `customReplicationTLSSecret.name` | A secret with TLS certificate generated for internal communications                                                                                                                                     | `""`                                                         |
| `openshift`                       | Set to true if the cluster is being deployed on OpenShift, set to false otherwise, or unset it for autodetection                                                                                        | `false`                                                      |
| `users.name`                      | The name of the PostgreSQL user                                                                                                                                                                         | `""`                                                         |
| `users.databases`                 | Databases accessible by a specific PostgreSQL user with rights to create objects in them (the option is ignored for postgres user; also, modifying it can’t be used to revoke the already given access) | `{}`                                                         |
| `users.options`                   | The ALTER ROLE options other than password (the option is ignored for postgres user)                                                                                                                    | `""`                                                         |
| `users.password.type`             | The set of characters used for password generation: can be either ASCII (default) or AlphaNumeric                                                                                                       | `ASCII`                                                      |
| `users.secretName`                | User secret name                                                                                                                                                                                        | `"rhino-credentials"`                                        |
| `databaseInitSQL.key`             | Data key for the Custom configuration options ConfigMap with the init SQL file, which will be executed at cluster creation time                                                                         | `init.sql`                                                   |
| `databaseInitSQL.name`            | Name of the ConfigMap with the init SQL file, which will be executed at cluster creation time                                                                                                           | `cluster1-init-sql`                                          |
| |
| `dataSource.postgresCluster.clusterName`            | Name of an existing cluster to use as the data source when restoring backup to a new cluster                                                             | `""`                 |
| `dataSource.postgresCluster.repoName`               | Name of the pgBackRest repository in the source cluster that contains the backup to be restored to a new cluster                                         | `""`                 |
| `dataSource.postgresCluster.options`                | The pgBackRest command-line options for the pgBackRest restore command                                                                                   | `[]`                 |
| `dataSource.postgresCluster.tolerations.effect`     | The Kubernetes Pod tolerations effect for data migration jobs                                                                                            | `NoSchedule`         |
| `dataSource.postgresCluster.tolerations.key`        | The Kubernetes Pod tolerations key for data migration jobs                                                                                               | `role`               |
| `dataSource.postgresCluster.tolerations.operator`   | The Kubernetes Pod tolerations operator for data migration jobs                                                                                          | `Equal`              |
| `dataSource.postgresCluster.tolerations.value`      | The Kubernetes Pod tolerations value for data migration jobs                                                                                             | `connection-poolers` |
| `dataSource.pgbackrest.stanza`                      | Name of the pgBackRest stanza to use as the data source when restoring backup to a new cluster                                                           | `""`                 |
| `dataSource.pgbackrest.configuration[].secret.name` | Name of the Kubernetes Secret object with custom pgBackRest configuration, which will be added to the pgBackRest configuration generated by the Operator | `""`                 |
| `dataSource.pgbackrest.global.repo1-path`           | Repo path are to be included in the global section of the pgBackRest configuration generated by the Operator                                             | `""`                 |
| `dataSource.pgbackrest.tolerations.effect`          | The Kubernetes Pod tolerations effect for pgBackRest                                                                                                     | `NoSchedule`         |
| `dataSource.pgbackrest.tolerations.key`             | The Kubernetes Pod tolerations key for pgBackRest                                                                                                        | `role`               |
| `dataSource.pgbackrest.tolerations.operator`        | The Kubernetes Pod tolerations operator for pgBackRest                                                                                                   | `Equal`              |
| `dataSource.pgbackrest.tolerations.value`           | The Kubernetes Pod tolerations value for pgBackRest                                                                                                      | `connection-poolers` |
| `dataSource.pgbackrest.repo.name`                   | Name of the pgBackRest repository                                                                                                                        | `""`                 |
| `dataSource.pgbackrest.repo.s3.bucket`              | The Amazon S3 bucket name used for backups	                                                                                                             | `""`                 |
| `dataSource.pgbackrest.repo.s3.endpoint`            | The endpoint URL of the S3-compatible storage to be used for backups (not needed for the original Amazon S3 cloud)                                       | `""`                 |
| `dataSource.pgbackrest.repo.s3.region`              | The AWS region to use for Amazon and all S3-compatible storages                                                                                          | `""`                 |
| `dataSource.volumes.pgDataVolume`                   | Defines the existing pgData volume and directory to use in the current PostgresCluster                                                                   | `{}`                 |
| `dataSource.volumes.pgWALVolume`                    | Defines the existing pg_wal volume and directory to use in the current PostgresCluster                                                                   | `{}`                 |
| `dataSource.volumes.pgBackRestVolume`               | Defines the existing pgBackRest repo volume and directory to use in the current PostgresCluster                                                          | `{}`                 |
| |
| `expose.annotations`                      | The Kubernetes annotations metadata for PostgreSQL                                                                                              | `{}`           |
| `expose.labels`                           | Set labels for the PostgreSQL Service                                                                                                           | `{}`           |
| `expose.type`                             | Specifies the type of Kubernetes Service for PostgreSQL                                                                                         | `LoadBalancer` |
| `expose.loadBalancerSourceRanges`         | The range of client IP addresses from which the load balancer should be reachable (if not set, there is no limitations)                         | `[]`           |
| `exposeReplicas.annotations`              | The Kubernetes annotations metadata for PostgreSQL replicas                                                                                     | `{}`           |
| `exposeReplicas.labels`                   | Set labels for the PostgreSQL Service replicas                                                                                                  | `{}`           |
| `exposeReplicas.type`                     | Specifies the type of Kubernetes Service for PostgreSQL replicas                                                                                | `LoadBalancer` |
| `exposeReplicas.loadBalancerSourceRanges` | The range of client IP addresses from which the load balancer should be reachable (if not set, there is no limitations) for PostgreSQL replicas | `[]`           |
| |
| `instances.name`                                                             | The name of the PostgreSQL instance                                                                                    | `instance1`                                                 |
| `instances.replicas`                                                         | The number of Replicas to create for the PostgreSQL instance                                                           | `3`                                                         |
| `instances.affinity.podAntiAffinity`                                         | Pod anti-affinity, allows setting the standard Kubernetes affinity constraints of any complexity                       | `{}`                                                        |
| `instances.resources.requests.memory`                                        | Kubernetes memory requests for a PostgreSQL instance                                                                   | `""`                                                        |
| `instances.resources.requests.cpu`                                           | Kubernetes CPU requests for a PostgreSQL instance                                                                      | `""`                                                        |
| `instances.resources.limits.memory`                                          | Kubernetes memory limits for a PostgreSQL instance                                                                     | `""`                                                        |
| `instances.resources.limits.cpu`                                             | Kubernetes CPU limits for a PostgreSQL instance                                                                        | `""`                                                        |
| `instances.containers.replicaCertCopy.resources.limits.cpu`                  | Kubernetes CPU limits for replicaCertCopy instance                                                                     | `200m`                                                      |
| `instances.containers.replicaCertCopy.resources.limits.memory`               | Kubernetes memory limits for replicaCertCopy instance                                                                  | `128Mi`                                                     | 
| `instances.sidecars.name`                                                    | Name of the custom sidecar container for PostgreSQL Pods                                                               | `testcontainer`                                             |
| `instances.sidecars.image`                                                   | Image for the custom sidecar container for PostgreSQL Pods                                                             | `mycontainer1:latest`                                       |
| `instances.topologySpreadConstraints.maxSkew`                                | The degree to which Pods may be unevenly distributed under the Kubernetes Pod Topology Spread Constraints              | `1`                                                         |
| `instances.topologySpreadConstraints.topologyKey`                            | The key of node labels for the Kubernetes Pod Topology Spread Constraints                                              | `my-node-label`                                             |
| `instances.topologySpreadConstraints.whenUnsatisfiable`                      | What to do with a Pod if it doesn’t satisfy the Kubernetes Pod Topology Spread Constraints                             | `DoNotSchedule`                                             |
| `instances.topologySpreadConstraints.labelSelector.matchLabels`              | The Label selector for the Kubernetes Pod Topology Spread Constraints                                                  | `postgres-operator.crunchydata.com/instance-set: instance1` |
| `instances.tolerations.effect`                                               | The Kubernetes Pod tolerations effect for the PostgreSQL instance                                                      | `NoSchedule`                                                |
| `instances.tolerations.key`                                                  | The Kubernetes Pod tolerations key for the PostgreSQL instance                                                         | `role`                                                      |
| `instances.tolerations.operator`                                             | The Kubernetes Pod tolerations operator for the PostgreSQL instance                                                    | `Equal`                                                     |
| `instances.tolerations.value`                                                | The Kubernetes Pod tolerations value for the PostgreSQL instance                                                       | `connection-poolers`                                        |
| `instances.priorityClassName`                                                | The Kuberentes Pod priority class for PostgreSQL instance Pods                                                         | `high-priority`                                             |
| `instances.securityContext`                                                  | The Kubernetes Pod security context for the PostgreSQL instance                                                        | `{}`                                                        |
| `instances.walVolumeClaimSpec.accessModes`                                   | The Kubernetes PersistentVolumeClaim access modes for the PostgreSQL Write-ahead Log storage                           | `ReadWriteOnce`                                             |
| `instances.walVolumeClaimSpec.storageClassName`                              | The Kubernetes storageClassName for the Write-ahead Log storage                                                        | `""`                                                        |
| `instances.walVolumeClaimSpec.resources.requests.storage`                    | The Kubernetes storage requests for the PostgreSQL Write-ahead Log use                                                 | `1Gi`                                                       |
| `instances.dataVolumeClaimSpec.accessModes`                                  | The Kubernetes PersistentVolumeClaim access modes for the PostgreSQL data storage                                      | `ReadWriteOnce`                                             |
| `instances.dataVolumeClaimSpec.storageClassName`                             | The Kubernetes storageClassName for the PostgreSQL data storage                                                        | `""`                                                        |
| `instances.dataVolumeClaimSpec.resources.requests.storage`                   | The Kubernetes storage requests for the storage the PostgreSQL instance will use                                       | `1Gi`                                                       |
| `instances.tablespaceVolumes.name`                                           | Name for the custom [tablespace volume](https://docs.percona.com/percona-operator-for-postgresql/2.0/tablespaces.html) | `""`                                                        |
| `instances.tablespaceVolumes.dataVolumeClaimSpec.accessModes`                | The Kubernetes PersistentVolumeClaim access modes for the tablespace volume                                            | `{}`                                                        |
| `instances.tablespaceVolumes.dataVolumeClaimSpec.resources.requests.storage` | The Kubernetes storage requests for the tablespace volume                                                              | `""`                                                        |
| |
| `backups.pgbackrest.metadata.labels`                                               | Set labels for  pgbackrest                                                                                                                               | `test-label:test`                                                    |
| `backups.pgbackrest.configuration`                                                 | Name of the Kubernetes Secret object with custom pgBackRest configuration, which will be added to the pgBackRest configuration generated by the Operator | `[]`                                                                 |
| `backups.pgbackrest.containers.pgbackrest.resources.limits.cpu`                    | Kubernetes CPU limits for pgbackrest instance                                                                                                            | `200m`                                                               |
| `backups.pgbackrest.containers.pgbackrest.resources.limits.memory`                 | Kubernetes memory limits for pgbackrest instance                                                                                                         | `128Mi`                                                              | 
| `backups.pgbackrest.containers.pgbackrestConfig.resources.limits.cpu`              | Kubernetes CPU limits for pgbackrestConfig instance                                                                                                      | `200m`                                                               |
| `backups.pgbackrest.containers.pgbackrestConfig.resources.limits.memory`           | Kubernetes memory limits for pgbackrestConfig instance                                                                                                   | `128Mi`                                                              | 
| `backups.pgbackrest.jobs.priorityClassName`                                        | The Kuberentes Pod priority class for pgBackRest jobs                                                                                                    | `high-priority`                                                      |
| `backups.pgbackrest.jobs.resources.limits.cpu`                                     | Kubernetes CPU limits for a pgBackRest job                                                                                                               | `200m`                                                               |
| `backups.pgbackrest.jobs.resources.limits.memory`                                  | Kubernetes memory limits for a pgBackRest job                                                                                                            | `128Mi`                                                              |
| `backups.pgbackrest.jobs.tolerations.effect`                                       | The Kubernetes Pod tolerations effect for a backup job                                                                                                   | `NoSchedule`                                                         |
| `backups.pgbackrest.jobs.tolerations.key`                                          | The Kubernetes Pod tolerations key for a backup job                                                                                                      | `role`                                                               |
| `backups.pgbackrest.jobs.tolerations.operator`                                     | The Kubernetes Pod tolerations operator for a backup job                                                                                                 | `Equal`                                                              |
| `backups.pgbackrest.jobs.tolerations.value`                                        | The Kubernetes Pod tolerations value for a backup job                                                                                                    | `connection-poolers`                                                 |
| `backups.pgbackrest.jobs.securityContext`                                          | The Kubernetes Pod security context for pgBackRest jobs                                                                                                  | `{}`                                                                 |
| `backups.pgbackrest.global`                                                        | Settings, which are to be included in the global section of the pgBackRest configuration generated by the Operator                                       | `/pgbackrest/postgres-operator/hippo/repo1`                          |
| `backups.pgbackrest.repoHost.topologySpreadConstraints.maxSkew`                    | The degree to which Pods may be unevenly distributed under the Kubernetes Pod Topology Spread Constraints                                                | `1`                                                                  |
| `backups.pgbackrest.repoHost.topologySpreadConstraints.topologyKey`                | The key of node labels for the Kubernetes Pod Topology Spread Constraints                                                                                | `my-node-label`                                                      |
| `backups.pgbackrest.repoHost.topologySpreadConstraints.whenUnsatisfiable`          | What to do with a Pod if it doesn’t satisfy the Kubernetes Pod Topology Spread Constraints                                                               | `DoNotSchedule`                                                      |
| `backups.pgbackrest.repoHost.topologySpreadConstraints.labelSelector.matchLabels`  | The Label selector for the Kubernetes Pod Topology Spread Constraints                                                                                    | `postgres-operator.crunchydata.com/instance-set: instance1`          |
| `backups.pgbackrest.repoHost.priorityClassName`                                    | The Kuberentes Pod priority class for pgBackRest repo                                                                                                    | `high-priority`                                                      |
| `backups.pgbackrest.repoHost.affinity.podAntiAffinity`                             | Pod anti-affinity, allows setting the standard Kubernetes affinity constraints of any complexity                                                         | `{}`                                                                 |
| `backups.pgbackrest.repoHost.tolerations.effect`                                   | The Kubernetes Pod tolerations effect for pgBackRest repo                                                                                                | `NoSchedule`                                                         |
| `backups.pgbackrest.repoHost.tolerations.key`                                      | The Kubernetes Pod tolerations key for pgBackRest repo                                                                                                   | `role`                                                               |
| `backups.pgbackrest.repoHost.tolerations.operator`                                 | The Kubernetes Pod tolerations operator for pgBackRest repo                                                                                              | `Equal`                                                              |
| `backups.pgbackrest.repoHost.tolerations.value`                                    | The Kubernetes Pod tolerations value for pgBackRest repo                                                                                                 | `connection-poolers`                                                 |
| `backups.pgbackrest.repoHost.securityContext`                                      | The Kubernetes Pod security context for pgBackRest repo                                                                                                  | `{}`                                                                 |
| `backups.pgbackrest.manual.repoName`                                               | Name of the pgBackRest repository for on-demand backups                                                                                                  | `repo1`                                                              |
| `backups.pgbackrest.manual.options`                                                | The on-demand backup command-line options which will be passed to pgBackRest for on-demand backups                                                       | `--type=full`                                                        |
| `backups.pgbackrest.repos.repo1.name`                                              | Name of the pgBackRest repository for backups                                                                                                            | `repo1`                                                              |
| `backups.pgbackrest.repos.repo1.schedules.full`                                    | Scheduled time to make a full backup specified in the crontab format                                                                                     | `0 0 \* \* 6`                                                        |
| `backups.pgbackrest.repos.repo1.schedules.differential`                            | Scheduled time to make a differential backup specified in the crontab format                                                                             | `0 0 \* \* 6`                                                        |
| `backups.pgbackrest.repos.repo1.schedules.incremental`                             | Scheduled time to make an incremental backup specified in the crontab format                                                                             | `0 0 \* \* 6`                                                        |
| `backups.pgbackrest.repos.repo1.volume.volumeClaimSpec.accessModes`                | The Kubernetes PersistentVolumeClaim access modes for the pgBackRest Storage                                                                             | `ReadWriteOnce`                                                      |
| `backups.pgbackrest.repos.repo1.volume.volumeClaimSpec.storageClassName`           | The Kubernetes storageClassName for the pgBackRest Storage                                                                                               | `""`                                                                 |
| `backups.pgbackrest.repos.repo1.volume.volumeClaimSpec.resources.requests.storage` | The Kubernetes storage requests for the pgBackRest storage                                                                                               | `1Gi`                                                                |
| `backups.pgbackrest.repos.repo3.gcs.bucket`                                        | The Google Cloud Storage bucket                                                                                                                          | `my-bucket`                                                          |
| `backups.pgbackrest.repos.repo4.azure.container`                                   | Name of the Azure Blob Storage container for backups                                                                                                     | `my-container`                                                       |
| `backups.pgbackrest.restore.tolerations.effect`                                    | The Kubernetes Pod tolerations effect for the backup restore job                                                                                         | `NoSchedule`                                                         |
| `backups.pgbackrest.restore.tolerations.key`                                       | The Kubernetes Pod tolerations key for the backup restore job                                                                                            | `role`                                                               |
| `backups.pgbackrest.restore.tolerations.operator`                                  | The Kubernetes Pod tolerations  operator for the backup restore job                                                                                      | `Equal`                                                              |
| `backups.pgbackrest.restore.tolerations.value`                                     | The Kubernetes Pod tolerations value for the backup restore job                                                                                          | `connection-poolers`                                                 |
| `backups.restore.enabled`                                                          | Enables or disables restoring a previously made backup                                                                                                   | `false`                                                              |
| `backups.restore.repoName`                                                         | Name of the pgBackRest repository that contains the backup to be restored                                                                                | `repo1`                                                              |
| `backups.restore.options`                                                          | The pgBackRest command-line options for the pgBackRest restore command                                                                                   | `--type=time`                                                        |
| `backups.pgbackrest.image`                                                         | Set this variable if you need to use a custom pgBackrest image                                                                                           | `percona/percona-postgresql-operator:2.4.1-ppg16.3-pgbackrest2.51-1` |
| `backups.repos.repo2.s3.bucket`                                                    | Storage bucket                                                                                                                                           | ``                                                                   |
| `backups.repos.repo2.s3.region`                                                    | S3-compatible storage name                                                                                                                               | ``                                                                   |
| `backups.repos.repo2.s3.endpoint`                                                  | S3-compatible storage endpoint                                                                                                                           | ``                                                                   |
| |
| `proxy.pgBouncer.expose.annotations`                                  | The Kubernetes annotations metadata for pgBouncer                                                                       | `pg-cluster-annot: cluster1`                                        |
| `proxy.pgBouncer.expose.labels`                                       | Set labels for the pgBouncer Service                                                                                    | `pg-cluster-label: cluster1`                                        |
| `proxy.pgBouncer.expose.type`                                         | K8S service type for the pgbouncer deployment                                                                           | `ClusterIP`                                                         |
| `proxy.pgBouncer.expose.loadBalancerSourceRanges`                     | The range of client IP addresses from which the load balancer should be reachable (if not set, there is no limitations) | `[]`                                                                |
| `proxy.pgBouncer.sidecars.image`                                      | Image for the custom sidecar container for pgBouncer Pods                                                               | `mycontainer1:latest`                                               |
| `proxy.pgBouncer.sidecars.name`                                       | Name of the custom sidecar container for pgBouncer Pods                                                                 | `testcontainer`                                                     |
| `proxy.pgBouncer.exposeSuperusers`                                    | Allow superusers connect via pgbouncer                                                                                  | `false`                                                             |
| `proxy.pgBouncer.config.global`                                       | Custom configuration options for pgBouncer.                                                                             | `pool_mode: transaction`                                            |
| `proxy.pgBouncer.topologySpreadConstraints.maxSkew`                   | The degree to which Pods may be unevenly distributed under the Kubernetes Pod Topology Spread Constraints               | `1`                                                                 |
| `proxy.pgBouncer.topologySpreadConstraints.topologyKey`               | The key of node labels for the Kubernetes Pod Topology Spread Constraints                                               | `my-node-label`                                                     |
| `proxy.pgBouncer.topologySpreadConstraints.whenUnsatisfiable`         | What to do with a Pod if it doesn’t satisfy the Kubernetes Pod Topology Spread Constraints                              | `DoNotSchedule`                                                     |
| `proxy.pgBouncer.topologySpreadConstraints.labelSelector.matchLabels` | The Label selector for the Kubernetes Pod Topology Spread Constraints                                                   | `postgres-operator.crunchydata.com/instance-set: instance1`         |
| `proxy.pgBouncer.tolerations.effect`                                  | The Kubernetes Pod tolerations effect for the PostgreSQL instance                                                       | `NoSchedule`                                                        |
| `proxy.pgBouncer.tolerations.key`                                     | The Kubernetes Pod tolerations key for the PostgreSQL instance                                                          | `role`                                                              |
| `proxy.pgBouncer.tolerations.operator`                                | The Kubernetes Pod tolerations operator for the PostgreSQL instance                                                     | `Equal`                                                             |
| `proxy.pgBouncer.tolerations.value`                                   | The Kubernetes Pod tolerations value for the PostgreSQL instance                                                        | `connection-poolers`                                                |
| `proxy.pgBouncer.customTLSSecret.name`                                | Custom external TLS secret name                                                                                         | `keycloakdb-pgbouncer.tls`                                          |
| `proxy.pgBouncer.securityContext`                                     | The Kubernetes Pod security context for the pgBouncer instance                                                          | `{}`                                                                |
| `proxy.pgBouncer.affinity.podAntiAffinity`                            | Pod anti-affinity, allows setting the standard Kubernetes affinity constraints of any complexity                        | `{}`                                                                |
| `proxy.pgBouncer.image`                                               | Set this variable if you need to use a custom pgbouncer image                                                           | `percona/percona-postgresql-operator:2.4.1-ppg16.3-pgbouncer1.22.1` |
| `proxy.pgBouncer.replicas`                                            | The number of pgbouncer instances                                                                                       | `3`                                                                 |
| `proxy.pgBouncer.resources.requests.cpu`                              | Container resource request for CPU                                                                                      | `1`                                                                 |
| `proxy.pgBouncer.resources.requests.memory`                           | Container resource request for RAM                                                                                      | `128Mi`                                                             |
| `proxy.pgBouncer.resources.limits.cpu`                                | Container resource limits for CPU                                                                                       | `2`                                                                 |
| `proxy.pgBouncer.resources.limits.memory`                             | Container resource limits for RAM                                                                                       | `512Mi`                                                             |
| `proxy.pgBouncer.containers.pgbouncerConfig.resources.limits.cpu`     | Kubernetes CPU limits for pgbouncerConfig instance                                                                      | `200m`                                                              |
| `proxy.pgBouncer.containers.pgbouncerConfig.resources.limits.memory`  | Kubernetes memory limits for pgbouncerConfig instance                                                                   | `128Mi`                                                             | 
| |
| `pmm.enabled`                   | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false`              |
| `pmm.image.repository`          | PMM Container image repository                                                                                                                                                           | `percona/pmm-client` |
| `pmm.image.tag`                 | PMM Container image tag                                                                                                                                                                  | `2.42.0`             |
| `pmm.serverHost`                | PMM server related K8S service hostname                                                                                                                                                  | `monitoring-service` |
| `pmm.resources.requests.memory` | Container resource request for RAM                                                                                                                                                       | `200M`               |
| `pmm.resources.requests.cpu`    | Container resource request for CPU                                                                                                                                                       | `500m`               |
| |
| `patroni.syncPeriodSeconds`                          | The interval for refreshing the leader lock and applying dynamicConfiguration                                                                                                                                       | `10` |
| `patroni.leaderLeaseDurationSeconds`                 | TTL of the cluster leader lock                                                                                                                                                                                      | `30` |
| `patroni.dynamicConfiguration`                       | Custom PostgreSQL configuration options. Please note that configuration changes are automatically applied to the running instances without validation, so having an invalid config can make the cluster unavailable | `{}` |
| `patroni.dynamicConfiguration.postgresql.parameters` | Custom PostgreSQL configuration options                                                                                                                                                                             | `{}` |
| `patroni.dynamicConfiguration.postgresql.pg_hba`     | PostgreSQL Host-Based Authentication section                                                                                                                                                                        | `{}` |
| `patroni.switchover.enabled`                         | Enables or disables manual change of the cluster primary instance                                                                                                                                                   | `""` |
| `patroni.switchover.targetInstance`                  | The name of the Pod that should be set as the new primary. When not specified, the new primary will be selected randomly                                                                                            | `""` |
| |
| `extensions.image`               | Image for the custom PostgreSQL extension loader sidecar container                                                          | `""`     |
| `extensions.imagePullPolicy`     | Policy for the custom extension sidecar container                                                                           | `Always` |
| `extensions.storage.type`        | The cloud storage type used for backups. Only s3 type is currently supported.                                               | `""`     |
| `extensions.storage.bucket`      | The Amazon S3 bucket name for prepackaged PostgreSQL custom extensions                                                      | `""`     |
| `extensions.storage.region`      | The AWS region to use                                                                                                       | `""`     |
| `extensions.storage.endpoint`    | The S3 endpoint to use.                                                                                                     | `""`     |
| `extensions.storage.secret.name` | The Kubernetes secret for the custom extensions storage. It should contain AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY keys | `""`     |
| `extensions.builtin`             | The key-value pairs which enable or disable Percona Distribution for PostgreSQL builtin extensions                          | `{}`     |
| `extensions.custom`              | Array of name and versions for each PostgreSQL custom extension                                                             | `[]`     |
| |
| `secrets.name`           | Database secrets object name. Object will be autogenerated if the name is not explicitly specified | `<cluster_name>-users`      |
| `secrets.primaryuser`    | primary user password (in use for replication only)                                                | `autogenerated by operator` |
| `secrets.postgres`       | postges user password (superuser, not accessible via pgbouncer)                                    | `autogenerated by operator` |
| `secrets.pgbouncer`      | pgbouncer user password                                                                            | `autogenerated by operator` |
| `secrets.<default_user>` | Default user password                                                                              | `autogenerated by operator` |

Specify parameters using `--set key=value[,key=value]` argument to `helm install`
Notice that you can use multiple replica sets only with sharding enabled.

## Examples

### Deploy for tests - single PostgreSQL node and automated PVCs deletion

Such a setup is good for testing, as it does not require a lot of compute power
and performs and automated clean up of the Persistent Volume Claims (PVCs).
It also deploys just one pgBouncer node, instead of 3.
```bash
$ helm install my-test percona/pg-db \
  --set instances[0].name=test \
  --set instances[0].replicas=1 \
  --set instances[0].dataVolumeClaimSpec.resources.requests.storage=1Gi \
  --set proxy.pgBouncer.replicas=1 \
  --set finalizers={'percona\.com\/delete-pvc,percona\.com\/delete-ssl'}
```

### Expose pgBouncer with a Load Balancer

Expose the cluster's pgBouncer with a LoadBalancer:

```bash
$ helm install my-test percona/pg-db  \
  --set proxy.pgBouncer.expose.type=LoadBalancer
```

### Add a custom user and a database

The following command is going to deploy the cluster with the user `test`
and give it access to the database `mytest`:

```bash
$ helm install my-test percona/pg-db  \
  --set users[0].name=test \
  --set users[0].databases={mytest}
```

Read more about custom users in our [documentation](https://docs.percona.com/percona-operator-for-postgresql/2.0/users.html)
