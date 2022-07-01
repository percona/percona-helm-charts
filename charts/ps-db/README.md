# Percona Server for MySQL

This chart deploys Percona Server for MySQL Cluster on Kubernetes controlled by Percona Operator for MySQL.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-server-mysql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-mysql/ps/index.html)

## Pre-requisites
* Percona Operator for MySQL running in your Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/blob/main/charts/ps-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-mysql/helm.html).
* Kubernetes 1.20+
* Helm v3

# Chart Details
This chart will deploy Percona Server for MySQL Cluster in Kubernetes. It will create a Custom Resource, and the Operator will trigger the creation of corresponding Kubernetes primitives: StatefulSets, Pods, Secrets, etc.

## Installing the Chart
To install the chart with the `ps` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/ps-db --version 0.2.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `pause`                         | Stop PS Cluster safely                                                        | `false`                                   |
| `allowUnsafeConfigurations`     | Allows forbidden configurations like even number of Orchestrator pods         | `false`                                   |
| `secretsName`                   | Secret name for user passwords                                                | `{}`                                      |
| `sslSecretName`                 | Secret name for ssl certificates                                              | `{}`                                      |
| `mysql.clusterType`             | MySQL Cluster type (async | group-replication)                                | `async`                                   |
| `mysql.image.repository`        | MySQL Container image repository                                              | `percona/percona-server`                  |
| `mysql.image.tag`               | MySQL Container image tag                                                     | `8.0.28`                                  |
| `mysql.imagePullPolicy`         | The policy used to update images                                              | `Always`                                  |
| `mysql.imagePullSecrets`        | MySQL Container pull secret                                                   | `[]`                                      |
| `mysql.size`                    | Number of MySQL pods                                                          | `3`                                       |
| `mysql.sizeSemiSync`            | Number of MySQL pods with enabled semi-sync replication                       | `0`                                       |
| `mysql.primaryServiceType`      | MySQL primary service type                                                    | ``                                        |
| `mysql.replicasServiceType`     | MySQL replicas service type                                                   | ``                                        |
| `mysql.annotations`             | MySQL Pods user-defined annotations                                           | `{}`                                      |
| `mysql.priorityClassName`       | MySQL Pods priority Class defined by user                                     | `""`                                      |
| `mysql.runtimeClassName`        | Name of the Kubernetes Runtime Class for MySQL Pods                           | `""`                                      |
| `mysql.labels`                  | MySQL Pods user-defined labels                                                | `{}`                                      |
| `mysql.schedulerName`           | The Kubernetes Scheduler                                                      | `""`                                      |
| `mysql.resources`               | MySQL Pods resource requests and limits                                       | `{}`                                      |
| `mysql.nodeSelector`            | MySQL Pods key-value pairs setting for K8S node assingment                    | `{}`                                      |
| `mysql.affinity.antiAffinityTopologyKey` | MySQL Pods simple scheduling restriction on/off for host, zone, region | `"kubernetes.io/hostname"`              |
| `mysql.affinity.advanced`       | MySQL Pods advanced scheduling restriction with match expression engine       | `{}`                                      |
| `mysql.tolerations`             | List of node taints to tolerate for MySQL Pods                                | `[]`                                      |
| `mysql.podDisruptionBudget.maxUnavailable`  | Instruct Kubernetes about the failed pods allowed quantity        | `1`                                       |
| `mysql.expose.enabled`          | Allow access to MySQL from outside of Kubernetes                              | `false`                                   |
| `mysql.expose.exposeType`       | Network service access point type                                             | `ClusterIP`                               |
| `mysql.volumeSpec`              | MySQL Pods storage resources                                                  | `{}`                                      |
| `mysql.volumeSpec.pvc`          | MySQL Pods PVC request parameters                                             |                                           |
| `mysql.volumeSpec.pvc.storageClassName`  | MySQL Pods PVC target storageClass                                   | `""`                                      |
| `mysql.volumeSpec.pvc.accessModes`       | MySQL Pods PVC access policy                                         | `[]`                                      |
| `mysql.volumeSpec.pvc.resources.requests.storage`  | MySQL Pods PVC storage size                                | `3G`                                      |
| `mysql.configuration`           | Custom config for MySQL                                                       | `""`                                      |
| `mysql.sidecars`                | MySQL Pod sidecars                                                            | `{}`                                      |
| `mysql.sidecarVolumes`          | MySQL Pod sidecar volumes                                                     | `[]`                                      |
| `mysql.sidecarPVCs`             | MySQL Pod sidecar PVCs                                                        | `[]`                                      |
| `mysql.containerSecurityContext` | A custom Kubernetes Security Context for a Container to be used instead of the default one  | `{}`                       |
| `mysql.podSecurityContext`      | A custom Kubernetes Security Context for a Pod to be used instead of the default one         | `{}`                       |
| `mysql.serviceAccountName`      | A custom service account to be used instead of the default one                | `""`                                      |
||
| `router.image.repository`       | Router Container image repository                                             | `percona/percona-server-mysql-operator`   |
| `router.image.tag`              | Router Container image tag                                                    | `0.2.0-router`                            |
| `router.imagePullPolicy`        | The policy used to update images                                              | `Always`                                  |
| `router.imagePullSecrets`       | Router Container pull secret                                                  | `[]`                                      |
| `router.size`                   | Router size (pod quantity)                                                    | `3`                                       |
| `router.annotations`            | Router Pods user-defined annotations                                          | `{}`                                      |
| `router.priorityClassName`      | Router Pods priority Class defined by user                                    | `""`                                      |
| `router.runtimeClassName`       | Name of the Kubernetes Runtime Class for Router Pods                          | `""`                                      |
| `router.labels`                 | Router Pods user-defined labels                                               | `{}`                                      |
| `router.schedulerName`          | The Kubernetes Scheduler                                                      | `""`                                      |
| `router.nodeSelector`           | Router Pods key-value pairs setting for K8S node assingment                   | `{}`                                      |
| `router.affinity.antiAffinityTopologyKey`  | Router Pods simple scheduling restriction on/off for host, zone, region  | `"kubernetes.io/hostname"`          |
| `router.affinity.advanced`      | Router Pods advanced scheduling restriction with match expression engine      | `{}`                                      |
| `router.tolerations`            | List of node taints to tolerate for Router Pods                               | `[]`                                      |
| `router.podDisruptionBudget.maxUnavailable`  | Instruct Kubernetes about the failed pods allowed quantity       | `1`                                       |
| `router.resources`              | Router Pods resource requests and limits                                      | `{}`                                      |
| `router.containerSecurityContext`  | A custom Kubernetes Security Context for a Container to be used instead of the default one  | `{}`                     |
| `router.podSecurityContext`     | A custom Kubernetes Security Context for a Pod to be used instead of the default one  | `{}`                              |
| `router.serviceAccountName`     | A custom service account to be used instead of the default one                | `""`                                      |
| `router.expose.exposeType`      | Network service access point type                                             | `ClusterIP`                               |
||
| `orchestrator.image.repository` | Orchestrator Container image repository                                       | `percona/percona-server-mysql-operator`   |
| `orchestrator.image.tag`        | Orchestrator Container image tag                                              | `0.2.0-orchestrator`                      |
| `orchestrator.imagePullPolicy`  | The policy used to update images                                              | `Always`                                  |
| `orchestrator.imagePullSecrets` | Orchestrator Container pull secret                                            | `[]`                                      |
| `orchestrator.size`             | Orchestrator size (pod quantity)                                              | `3`                                       |
| `orchestrator.annotations`      | Orchestrator Pods user-defined annotations                                    | `{}`                                      |
| `orchestrator.priorityClassName` | Orchestrator Pods priority Class defined by user                             | `""`                                      |
| `orchestrator.runtimeClassName`  | Name of the Kubernetes Runtime Class for Orchestrator Pods                   | `""`                                      |
| `orchestrator.labels`           | Orchestrator Pods user-defined labels                                         | `{}`                                      |
| `orchestrator.schedulerName`    | The Kubernetes Scheduler                                                      | `""`                                      |
| `orchestrator.nodeSelector`     | Orchestrator Pods key-value pairs setting for K8S node assingment             | `{}`                                      |
| `orchestrator.affinity.antiAffinityTopologyKey` | Orchestrator Pods simple scheduling restriction on/off for host, zone, region | `"kubernetes.io/hostname"` |
| `orchestrator.affinity.advanced`  | Orchestrator Pods advanced scheduling restriction with match expression engine  | `{}`                                  |
| `orchestrator.tolerations`      | List of node taints to tolerate for Orchestrator Pods                         | `[]`                                      |
| `orchestrator.podDisruptionBudget.maxUnavailable`  | Instruct Kubernetes about the failed pods allowed quantity | `1`                                       |
| `orchestrator.resources`        | Orchestrator Pods resource requests and limits                                | `{}`                                      |
| `orchestrator.volumeSpec`       | Orchestrator Pods storage resources                                           | `{}`                                      |
| `orchestrator.volumeSpec.pvc`   | Orchestrator Pods PVC request parameters                                      |                                           |
| `orchestrator.volumeSpec.pvc.storageClassName`  | Orchestrator Pods PVC target storageClass                     | `""`                                      |
| `orchestrator.volumeSpec.pvc.accessModes`       | Orchestrator Pods PVC access policy                           | `[]`                                      |
| `orchestrator.volumeSpec.pvc.resources.requests.storage`  | Orchestrator Pods PVC storage size                  | `1G`                                      |
| `orchestrator.containerSecurityContext` | A custom Kubernetes Security Context for a Container to be used instead of the default one  | `{}`                |
| `orchestrator.podSecurityContext` | A custom Kubernetes Security Context for a Pod to be used instead of the default one       | `{}`                       |
| `orchestrator.serviceAccountName` | A custom service account to be used instead of the default one              | `""`                                      |
||
| `pmm.image.repository`          | PMM Container image repository                                                | `percona/pmm-client`                      |
| `pmm.image.tag`                 | PMM Container image tag                                                       | `2.28.0`                                  |
| `pmm.imagePullPolicy`           | The policy used to update images                                              |  ``                                       |
| `pmm.serverHost`                | PMM server related K8S service hostname                                       | `monitoring-service`                      |
| `pmm.serverUser`                | PMM server user                                                               | `admin`                                   |
| `pmm.resources.requests`        | PMM Container resource requests                                               | `{"memory": "150M", "cpu": "300m"}`       |
| `pmm.resources.limits`          | PMM Container resource limits                                                 | `{}`                                      |
||
| `backup.enabled`                | Enable backups                                                                | `true`                                    |
| `backup.image.repository`       | Backup Container image repository                                             | `percona/percona-server-mysql-operator`   |
| `backup.image.tag`              | Backup Container image tag                                                    | `0.2.0-backup`                            |
| `backup.imagePullPolicy`        | The policy used to update images                                              | `Always`                                  |
| `backup.imagePullSecrets`       | Backup Container pull secret                                                  | `[]`                                      |
| `backup.serviceAccountName`     | Run Backup Container under specified K8S SA                                   | `percona-server-mongodb-operator`         |
| `backup.containerSecurityContext`  | A custom Kubernetes Security Context for a Container to be used instead of the default one  | `{}`                     |
| `backup.resources`              | Backup Pods resource requests and limits                                      | `{}`                                      |
| `backup.storages`               | Local/remote backup storages settings                                         | `{}`                                      |
||
| `secrets.passwords`             | User passwords (used if secretsName not specified)                            | `{}`                                      |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`
Notice that you can use multiple replica sets only with sharding enabled.

## Examples

### Deploy a database cluster with specific storage size

This is starting a cluster with specific PVC size.

```bash
$ helm install dev  --namespace ps . \
    --set "mysql.volumeSpec.pvc.resources.requests.storage=20G"
```
