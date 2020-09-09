# psmdb-db: A chart for installing Percona Server MongoDB Operator managed Databases

This chart implements Percona Server MongoDB deployment in Kubernets via Custom Resource object. The project itself can be found here:
* <https://github.com/percona/percona-server-mongodb-operator>

## Pre-requisites
* [PSMDB operator](https://hub.helm.sh/charts/percona/psmdb-operator) running in you K8S cluster
* Kubernetes 1.11+
* PV support on the underlying infrastructure - only if you are provisioning persistent volume(s).
* At least `v2.4.0` version of helm

## Custom Resource Details
* <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>

## StatefulSet Details
* <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>

## Chart Details
This chart will:
* deploy PSMDB database Pods (Custom Resource -> StatefulSet) for the further MongoDB Cluster creation in K8S.

### Installing the Chart
To install the chart with the `psmdb` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/psmdb-db --version 0.1.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `pause`                         | Stop PSMDB Database safely                                                    | `false`                                   |
| `allowUnsafeConfigurations`     | Allows forbidden configurations like even number of PSMDB cluster pods        | `false`                                   |
| `updateStrategy`                | Regulates the way how PSMDB Cluster Pods will be updated after setting a new image | `SmartUpdate`                          |
| `upgradeOptions.versionServiceEndpoint` | Endpoint for actual PSMDB Versions provider	 | `https://check.percona.com/versions/` |
| `upgradeOptions.apply` | PSMDB image to apply from version service - recommended, latest, actual version like 4.2.8-8 | `recommended` |
| `upgradeOptions.schedule` | Cron formatted time to execute the update | `"0 2 * * *"` |
| `image.repository`              | PSMDB Container image repository                                           | `percona/percona-server-mongodb` |
| `image.tag`                     | PSMDB Container image tag                                       | `4.2.8-8`                              |
| `imagePullSecrets`             | PSMDB Container pull secret                                                | `[]`                                      |
| `runUid`             | Set UserID                                                | `""`                                      |
| `secrets`             | Users secret structure                                                | `{}`                                   |
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/blog/2020/07/23/using-percona-kubernetes-operators-with-percona-monitoring-and-management/) | `false` |
| `pmm.image.repository`              | PMM Container image repository                                           | `percona/percona-server-mongodb-operator` |
| `pmm.image.tag`                     | PMM Container image tag                                       | `1.5.0-pmm`                              |
| `pmm.serverHost`                    | PMM server related K8S service hostname              | `monitoring-service` |
||
| `replset.name`                      | ReplicaSet name              | `rs0` |
| `replset.size`                      | ReplicaSet size (pod quantity)              | `3` |
| `replset.antiAffinityTopologyKey`   | ReplicaSet Pod affinity              | `kubernetes.io/hostname` |
| `replset.priorityClass`   | ReplicaSet Pod priorityClassName              | `""` |
| `replset.annotations`   | ReplicaSet Pod annotations              | `{}` |
| `replset.labels`   | ReplicaSet Pod labels              | `{}` |
| `replset.nodeSelector`   | ReplicaSet Pod nodeSelector labels              | `{}` |
| `replset.livenessProbe`   | ReplicaSet Pod livenessProbe structure              | `{}` |
| `replset.podDisruptionBudget.maxUnavailable`   | ReplicaSet failed Pods maximum quantity               | `1` |
| `replset.expose.enabled`   | Allow access to replicaSet from outside of Kubernetes              | `false` |
| `replset.expose.exposeType`   | Network service access point type              | `LoadBalancer` |
| `replset.arbiter.enabled`   | Create MongoDB arbiter service              | `false` |
| `replset.arbiter.size`   | MongoDB arbiter Pod quantity              | `1` |
| `replset.arbiter.antiAffinityTopologyKey`   | MongoDB arbiter Pod affinity              | `kubernetes.io/hostname` |
| `replset.arbiter.priorityClass`   | MongoDB arbiter priorityClassName              | `""` |
| `replset.arbiter.annotations`   | MongoDB arbiter Pod annotations              | `{}` |
| `replset.arbiter.labels`   | MongoDB arbiter Pod labels              | `{}` |
| `replset.arbiter.nodeSelector`   | MongoDB arbiter Pod nodeSelector labels              | `{}` |
| `replset.arbiter.livenessProbe`   | MongoDB arbiter Pod livenessProbe structure              | `{}` |
| `replset.schedulerName`   | ReplicaSet Pod schedulerName              | `""` |
| `replset.resources`       | ReplicaSet Pods resource requests and limits                          | `{}`                  |
| `replset.volumeSpec`       | ReplicaSet Pods storage resources                          | `{}`                  |
| `replset.volumeSpec.emptyDir`       | ReplicaSet Pods emptyDir K8S storage                          | `{}`                  |
| `replset.volumeSpec.hostPath`       | ReplicaSet Pods hostPath K8S storage                          |                   |
| `replset.volumeSpec.hostPath.path`       | ReplicaSet Pods hostPath K8S storage path                       | `""`                  |
| `replset.volumeSpec.pvc`       | ReplicaSet Pods PVC request parameters                       |                   |
| `replset.volumeSpec.pvc.storageClassName`       | ReplicaSet Pods PVC target storageClass                      | `""` |
| `replset.volumeSpec.pvc.accessModes`       | ReplicaSet Pods PVC access policy                      | `[]` |
| `replset.volumeSpec.pvc.resources.requests.storage`       | ReplicaSet Pods PVC storage size                      | `3Gi` |
| |
| `backup.enabled` | Enable backup PBM agent | `true` |
| `backup.restartOnFailure` | Backup Pods restart policy | `true` |
| `backup.image.repository`              | PBM Container image repository                                           | `percona/percona-server-mongodb-operator` |
| `backup.image.tag`                     | PBM Container image tag                                       | `1.5.0-backup`                              |
| `backup.serviceAccountName`   | Run PBM Container under specified K8S SA   | `percona-server-mongodb-operator` |
| `backup.storages`   | Local/remote backup storages settings   | `{}` |
| `backup.tasks`   | Backup working schedule   | `{}` |
| `users`   | PSMDB essential users   | `{}` |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`

## Examples

### Deploy a Cluster with no MySQL Proxy, no backups, and no persistent volumes

This is great for a dev cluster as it doesn't require a persistent disk and doesn't bother with a proxy, backups, or TLS.

```bash
$ helm install dev  --namespace psmdb . \
    --set runUid=1001 --set replset.volumeSpec.pvc.resources.requests.storage=20Gi \
    --set backup.enabled=false
```
