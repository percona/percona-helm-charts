# Percona Server for MongoDB

This chart deploys Percona Server for MongoDB Cluster on Kubernetes controlled by Percona Operator for MongoDB.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-server-mongodb-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/index.html)

## Pre-requisites
* Percona Operator for MongoDB running in your Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/blob/main/charts/psmdb-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/helm.html).
* Kubernetes 1.19+
* Helm v3

# Chart Details
This chart will deploy Percona Server for MongoDB Cluster in Kubernetes. It will create a Custom Resource, and the Operator will trigger the creation of corresponding Kubernetes primitives: StatefulSets, Pods, Secrets, etc.

## Installing the Chart
To install the chart with the `psmdb` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/psmdb-db --version 1.12.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `pause`                         | Stop PSMDB Database safely                                                    | `false`                                   |
| `unmanaged`                     | Start cluster and don't manage it (cross cluster replication)                 | `false`                                   |
| `allowUnsafeConfigurations`     | Allows forbidden configurations like even number of PSMDB cluster pods        | `false`                                   |
| `clusterServiceDNSSuffix`       | The (non-standard) cluster domain to be used as a suffix of the Service name  | `""`                                      |
| `clusterServiceDNSMode`         | Mode for the cluster service dns (Internal/ServiceMesh)                       | `""`                                      |
| `multiCluster.enabled`          | Enable Multi Cluster Services (MCS) cluster mode                              | `false`                                   |
| `multiCluster.DNSSuffix`        | The cluster domain to be used as a suffix for multi-cluster Services used by Kubernetes | `""`                            |
| `updateStrategy`                | Regulates the way how PSMDB Cluster Pods will be updated after setting a new image | `SmartUpdate`                        |
| `upgradeOptions.versionServiceEndpoint` | Endpoint for actual PSMDB Versions provider	 | `https://check.percona.com/versions/` |
| `upgradeOptions.apply` | PSMDB image to apply from version service - recommended, latest, actual version like 4.4.2-4 | `5.0-recommended` |
| `upgradeOptions.schedule` | Cron formatted time to execute the update | `"0 2 * * *"` |
| `upgradeOptions.setFCV` | Set feature compatibility version on major upgrade | `false` |
| `finalizers:delete-psmdb-pvc`  | Set this if you want to delete database persistent volumes on cluster deletion | `[]` |
| `finalizers:delete-psmdb-pods-in-order` | Set this if you want to delete PSMDB pods in order (primary last)     | `[]` |
| `image.repository`             | PSMDB Container image repository                                               | `percona/percona-server-mongodb`          |
| `image.tag`                    | PSMDB Container image tag                                                      | `5.0.7-6`                                 |
| `imagePullPolicy`              | The policy used to update images                                               | `Always`                                  |
| `imagePullSecrets`             | PSMDB Container pull secret                                                    | `[]`                                      |
| `tls.certValidityDuration`     | The validity duration of the external certificate for cert manager             | `""`                                      |
| `secrets`             | Operator secrets section                                 | `{}`                                      |
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false` |
| `pmm.image.repository`              | PMM Container image repository                                           | `percona/pmm-client` |
| `pmm.image.tag`                     | PMM Container image tag                                       | `2.27.0`                              |
| `pmm.serverHost`                    | PMM server related K8S service hostname              | `monitoring-service` |
||
| `replsets[0].name`                      | ReplicaSet name              | `rs0` |
| `replsets[0].size`                      | ReplicaSet size (pod quantity)              | `3` |
| `replsets[0].externalNodes`             | ReplicaSet external nodes (cross cluster replication)           | `[]` |
| `replsets[0].configuration`             | Custom config for mongod in replica set     | `""` |
| `replsets[0].antiAffinityTopologyKey`   | ReplicaSet Pod affinity              | `kubernetes.io/hostname` |
| `replsets[0].tolerations`     | ReplicaSet Pod tolerations                    | `[]` |
| `replsets[0].priorityClass`   | ReplicaSet Pod priorityClassName              | `""` |
| `replsets[0].annotations`   | ReplicaSet Pod annotations              | `{}` |
| `replsets[0].labels`   | ReplicaSet Pod labels              | `{}` |
| `replsets[0].nodeSelector`   | ReplicaSet Pod nodeSelector labels              | `{}` |
| `replsets[0].livenessProbe`   | ReplicaSet Pod livenessProbe structure              | `{}` |
| `replsets[0].readinessProbe`  | ReplicaSet Pod readinessProbe structure             | `{}` |
| `replsets[0].storage`         | Set cacheSizeRatio or other custom MongoDB storage options | `{}` |
| `replsets[0].podSecurityContext` | Set the security context for a Pod               | `{}` |
| `replsets[0].containerSecurityContext` | Set the security context for a Container   | `{}` |
| `replsets[0].runtimeClass`   | ReplicaSet Pod runtimeClassName              | `""` |
| `replsets[0].sidecars`   | ReplicaSet Pod sidecars                          | `{}` |
| `replsets[0].sidecarVolumes`   | ReplicaSet Pod sidecar volumes             | `[]` |
| `replsets[0].sidecarPVCs`      | ReplicaSet Pod sidecar PVCs                | `[]` |
| `replsets[0].podDisruptionBudget.maxUnavailable`   | ReplicaSet failed Pods maximum quantity               | `1` |
| `replsets[0].expose.enabled`   | Allow access to replicaSet from outside of Kubernetes              | `false` |
| `replsets[0].expose.exposeType`   | Network service access point type              | `ClusterIP` |
| `replsets[0].nonvoting.enabled`        | Add MongoDB nonvoting Pods                | `false` |
| `replsets[0].nonvoting.podSecurityContext` | Set the security context for a Pod               | `{}` |
| `replsets[0].nonvoting.containerSecurityContext` | Set the security context for a Container   | `{}` |
| `replsets[0].nonvoting.size`           | Number of nonvoting Pods                  | `1` |
| `replsets[0].nonvoting.configuration`  | Custom config for mongod nonvoting member | `""` |
| `replsets[0].nonvoting.antiAffinityTopologyKey`   | Nonvoting Pods affinity        | `kubernetes.io/hostname` |
| `replsets[0].nonvoting.tolerations`    | Nonvoting Pod tolerations                 | `[]` |
| `replsets[0].nonvoting.priorityClass`  | Nonvoting Pod priorityClassName           | `""` |
| `replsets[0].nonvoting.annotations`    | Nonvoting Pod annotations                 | `{}` |
| `replsets[0].nonvoting.labels`         | Nonvoting Pod labels                      | `{}` |
| `replsets[0].nonvoting.nodeSelector`   | Nonvoting Pod nodeSelector labels         | `{}` |
| `replsets[0].nonvoting.podDisruptionBudget.maxUnavailable`   | Nonvoting failed Pods maximum quantity    | `1` |
| `replsets[0].nonvoting.resources`      | Nonvoting Pods resource requests and limits                     | `{}` |
| `replsets[0].nonvoting.volumeSpec`     | Nonvoting Pods storage resources                                | `{}` |
| `replsets[0].nonvoting.volumeSpec.emptyDir`       | Nonvoting Pods emptyDir K8S storage                  | `{}` |
| `replsets[0].nonvoting.volumeSpec.hostPath`       | Nonvoting Pods hostPath K8S storage                  |      |
| `replsets[0].nonvoting.volumeSpec.hostPath.path`  | Nonvoting Pods hostPath K8S storage path             | `""` |
| `replsets[0].nonvoting.volumeSpec.pvc`            | Nonvoting Pods PVC request parameters                |      |
| `replsets[0].nonvoting.volumeSpec.pvc.storageClassName`  | Nonvoting Pods PVC target storageClass        | `""` |
| `replsets[0].nonvoting.volumeSpec.pvc.accessModes`       | Nonvoting Pods PVC access policy              | `[]` |
| `replsets[0].nonvoting.volumeSpec.pvc.resources.requests.storage`    | Nonvoting Pods PVC storage size   | `3Gi` |
| `replsets[0].arbiter.enabled`   | Create MongoDB arbiter service              | `false` |
| `replsets[0].arbiter.size`   | MongoDB arbiter Pod quantity              | `1` |
| `replsets[0].arbiter.antiAffinityTopologyKey`   | MongoDB arbiter Pod affinity              | `kubernetes.io/hostname` |
| `replsets[0].arbiter.tolerations`     | MongoDB arbiter Pod tolerations                | `[]` |
| `replsets[0].arbiter.priorityClass`   | MongoDB arbiter priorityClassName              | `""` |
| `replsets[0].arbiter.annotations`   | MongoDB arbiter Pod annotations              | `{}` |
| `replsets[0].arbiter.labels`   | MongoDB arbiter Pod labels              | `{}` |
| `replsets[0].arbiter.nodeSelector`   | MongoDB arbiter Pod nodeSelector labels              | `{}` |
| `replsets[0].schedulerName`   | ReplicaSet Pod schedulerName              | `""` |
| `replsets[0].resources`       | ReplicaSet Pods resource requests and limits                          | `{}`                  |
| `replsets[0].volumeSpec`       | ReplicaSet Pods storage resources                          | `{}`                  |
| `replsets[0].volumeSpec.emptyDir`       | ReplicaSet Pods emptyDir K8S storage                          | `{}`                  |
| `replsets[0].volumeSpec.hostPath`       | ReplicaSet Pods hostPath K8S storage                          |                   |
| `replsets[0].volumeSpec.hostPath.path`       | ReplicaSet Pods hostPath K8S storage path                       | `""`                  |
| `replsets[0].volumeSpec.pvc`       | ReplicaSet Pods PVC request parameters                       |                   |
| `replsets[0].volumeSpec.pvc.storageClassName`       | ReplicaSet Pods PVC target storageClass                      | `""` |
| `replsets[0].volumeSpec.pvc.accessModes`       | ReplicaSet Pods PVC access policy                      | `[]` |
| `replsets[0].volumeSpec.pvc.resources.requests.storage`       | ReplicaSet Pods PVC storage size                      | `3Gi` |
| |
| `sharding.enabled`                             | Enable sharding setup | `true` |
| `sharding.configrs.size`                       | Config ReplicaSet size (pod quantity) | `3` |
| `sharding.configrs.externalNodes`              | Config ReplicaSet external nodes (cross cluster replication)         | `[]` |
| `sharding.configrs.configuration`              | Custom config for mongod in config replica set | `""` |
| `sharding.configrs.antiAffinityTopologyKey`    | Config ReplicaSet Pod affinity | `kubernetes.io/hostname` |
| `sharding.configrs.tolerations`                | Config ReplicaSet Pod tolerations       | `[]` |
| `sharding.configrs.priorityClass`              | Config ReplicaSet Pod priorityClassName | `""` |
| `sharding.configrs.annotations`                | Config ReplicaSet Pod annotations | `{}` |
| `sharding.configrs.labels`                     | Config ReplicaSet Pod labels | `{}` |
| `sharding.configrs.nodeSelector`               | Config ReplicaSet Pod nodeSelector labels | `{}` |
| `sharding.configrs.livenessProbe`              | Config ReplicaSet Pod livenessProbe structure | `{}` |
| `sharding.configrs.readinessProbe`             | Config ReplicaSet Pod readinessProbe structure | `{}` |
| `sharding.configrs.storage`                    | Set cacheSizeRatio or other custom MongoDB storage options | `{}` |
| `sharding.configrs.podSecurityContext`         | Set the security context for a Pod             | `{}` |
| `sharding.configrs.containerSecurityContext`   | Set the security context for a Container       | `{}` |
| `sharding.configrs.runtimeClass`     | Config ReplicaSet Pod runtimeClassName            | `""` |
| `sharding.configrs.sidecars`         | Config ReplicaSet Pod sidecars                    | `{}` |
| `sharding.configrs.sidecarVolumes`   | Config ReplicaSet Pod sidecar volumes             | `[]` |
| `sharding.configrs.sidecarPVCs`      | Config ReplicaSet Pod sidecar PVCs                | `[]` |
| `sharding.configrs.podDisruptionBudget.maxUnavailable` | Config ReplicaSet failed Pods maximum quantity | `1` |
| `sharding.configrs.expose.enabled`             | Allow access to cfg replica from outside of Kubernetes       | `false` |
| `sharding.configrs.expose.exposeType`          | Network service access point type              | `ClusterIP` |
| `sharding.configrs.resources.limits.cpu`       | Config ReplicaSet resource limits CPU | `300m` |
| `sharding.configrs.resources.limits.memory`    | Config ReplicaSet resource limits memory | `0.5G` |
| `sharding.configrs.resources.requests.cpu`     | Config ReplicaSet resource requests CPU | `300m` |
| `sharding.configrs.resources.requests.memory`  | Config ReplicaSet resource requests memory | `0.5G` |
| `sharding.configrs.volumeSpec.hostPath`        | Config ReplicaSet hostPath K8S storage | |
| `sharding.configrs.volumeSpec.hostPath.path`   | Config ReplicaSet hostPath K8S storage path | `""` |
| `sharding.configrs.volumeSpec.emptyDir`        | Config ReplicaSet Pods emptyDir K8S storage | |
| `sharding.configrs.volumeSpec.pvc`             | Config ReplicaSet Pods PVC request parameters | |
| `sharding.configrs.volumeSpec.pvc.storageClassName` | Config ReplicaSet Pods PVC storageClass | `""` |
| `sharding.configrs.volumeSpec.pvc.accessModes` | Config ReplicaSet Pods PVC access policy | `[]` |
| `sharding.configrs.volumeSpec.pvc.resources.requests.storage` | Config ReplicaSet Pods PVC storage size | `3Gi` |
| `sharding.mongos.size`                         | Mongos size (pod quantity) | `3` |
| `sharding.mongos.configuration`                | Custom config for mongos   | `""` |
| `sharding.mongos.antiAffinityTopologyKey`      | Mongos Pods affinity | `kubernetes.io/hostname` |
| `sharding.mongos.tolerations`                  | Mongos Pods tolerations       | `[]` |
| `sharding.mongos.priorityClass`                | Mongos Pods priorityClassName | `""` |
| `sharding.mongos.annotations`                  | Mongos Pods annotations | `{}` |
| `sharding.mongos.labels`                       | Mongos Pods labels | `{}` |
| `sharding.mongos.nodeSelector`                 | Mongos Pods nodeSelector labels | `{}` |
| `sharding.mongos.livenessProbe`                | Mongos Pod livenessProbe structure | `{}` |
| `sharding.mongos.readinessProbe`               | Mongos Pod readinessProbe structure | `{}` |
| `sharding.mongos.podSecurityContext`           | Set the security context for a Pod  | `{}` |
| `sharding.mongos.containerSecurityContext`     | Set the security context for a Container | `{}` |
| `sharding.mongos.runtimeClass`                 | Mongos Pod runtimeClassName         | `""` |
| `sharding.mongos.sidecars`                     | Mongos Pod sidecars                 | `{}` |
| `sharding.mongos.sidecarVolumes`               | Mongos Pod sidecar volumes          | `[]` |
| `sharding.mongos.sidecarPVCs`                  | Mongos Pod sidecar PVCs             | `[]` |
| `sharding.mongos.podDisruptionBudget.maxUnavailable` | Mongos failed Pods maximum quantity | `1` |
| `sharding.mongos.resources.limits.cpu`         | Mongos Pods resource limits CPU | `300m` |
| `sharding.mongos.resources.limits.memory`      | Mongos Pods resource limits memory | `0.5G` |
| `sharding.mongos.resources.requests.cpu`       | Mongos Pods resource requests CPU | `300m` |
| `sharding.mongos.resources.requests.memory`    | Mongos Pods resource requests memory | `0.5G` |
| `sharding.mongos.expose.exposeType`            | Mongos service exposeType | `ClusterIP` |
| `sharding.mongos.expose.servicePerPod`         | Create a separate ClusterIP Service for each mongos instance | `false` |
| `sharding.mongos.expose.loadBalancerSourceRanges`   | Limit client IP's access to Load Balancer | `{}` |
| `sharding.mongos.expose.serviceAnnotations`    | Mongos service annotations | `{}` |
| |
| `backup.enabled`            | Enable backup PBM agent                  | `true` |
| `backup.annotations`        | Backup job annotations                   | `{}`   |
| `backup.restartOnFailure`   | Backup Pods restart policy               | `true` |
| `backup.image.repository`   | PBM Container image repository           | `percona/percona-backup-mongodb` |
| `backup.image.tag`          | PBM Container image tag                  | `1.7.0` |
| `backup.serviceAccountName` | Run PBM Container under specified K8S SA | `percona-server-mongodb-operator` |
| `backup.storages`           | Local/remote backup storages settings    | `{}` |
| `backup.pitr.enabled`       | Enable point in time recovery for backup | `false` |
| `backup.pitr.oplogSpanMin`  | Number of minutes between the uploads of oplogs | `10` |
| `backup.pitr.compressionType`  | The point-in-time-recovery chunks compression format | `""` |
| `backup.pitr.compressionLevel` | The point-in-time-recovery chunks compression level | `""` |
| `backup.tasks`              | Backup working schedule                  | `{}` |
| `users`                     | PSMDB essential users                    | `{}` |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`
Notice that you can use multiple replica sets only with sharding enabled.

## Examples

### Deploy a replica set with disabled backups and no mongos pods

This is great for a dev PSMDB/MongoDB cluster as it doesn't bother with backups and sharding setup.

```bash
$ helm install dev  --namespace psmdb . \
    --set runUid=1001 --set "replsets[0].volumeSpec.pvc.resources.requests.storage=20Gi" \
    --set backup.enabled=false --set sharding.enabled=false
```
