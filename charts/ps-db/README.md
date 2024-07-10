# Percona Server for MySQL

This chart deploys Percona Server for MySQL Cluster on Kubernetes controlled by Percona Operator for MySQL.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-server-mysql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-mysql/ps/index.html)

## Pre-requisites
* Percona Operator for MySQL running in your Kubernetes cluster. See installation details [here](https://github.com/percona/percona-helm-charts/blob/main/charts/ps-operator) or in the [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-mysql/helm.html).
* Kubernetes 1.27+
* Helm v3

# Chart Details
This chart will deploy Percona Server for MySQL Cluster in Kubernetes. It will create a Custom Resource, and the Operator will trigger the creation of corresponding Kubernetes primitives: StatefulSets, Pods, Secrets, etc.

## Installing the Chart
To install the chart with the `ps` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/ps-db --version 0.8.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                                           | Description                                                                                                | Default                     |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | --------------------------- |
| `crVersion`                                         | CR Cluster Manifest version                                                                                | `0.8.0`                     |
| `finalizers:percona.com/delete-mysql-pods-in-order` | Set this if you want to delete MySQL pods in order on cluster deletion                                     | `[]`                        |
| `finalizers:percona.com/delete-ssl`                 | Deletes objects created for SSL (Secret, certificate, and issuer) after the cluster deletion               | `[]`                        |
| `pause`                                             | Stop PS Cluster safely                                                                                     | `false`                     |
| `unsafeFlags`                                       |                                                                                                            | `{}`                        |
| `initImage`                                         | An alternative image for the initial Operator installation                                                 | `""`                        |
| `updateStrategy`                                    | Strategy for updating pods in a cluster (SmartUpdate, OnDelete, RollingUpdate)                             | `SmartUpdate`               |
| `upgradeOptions.versionServiceEndpoint`             | Endpoint for actual PS Versions provider                                                                   | `https://check.percona.com` |
| `upgradeOptions.apply`                              | PS image to apply from version service - `recommended`, `latest`, actual version like `8.0.35-30`          | `disabled`                  |
| `secretsName`                                       | Secret name for user passwords                                                                             | `<cluster_name>-secrets`    |
| `sslSecretName`                                     | Secret name for ssl certificates                                                                           | `{}`                        |
| `ignoreAnnotations`                                 | Mark annotations which will be ignored by the operator                                                     | `[]`                        |
| `ignoreLabels`                                      | Mark labels which will be ignored by the operator                                                          | `[]`                        |
| `tls.SANs`                                          | Additional domains (SAN) to be added to the TLS certificate within the extended cert-manager configuration | `[]`                        |
| `tls.issuerConf.name`                               | A cert-manager issuer name                                                                                 | `""`                        |
| `tls.issuerConf.kind`                               | A cert-manager issuer type                                                                                 | `""`                        |
| `tls.issuerConf.group`                              | A cert-manager issuer group                                                                                | `""`                        |
||
| `mysql.clusterType`                               | MySQL Cluster type (`async` or `group-replication`)                                                                                                           | `group-replication`        |
| `mysql.autoRecovery`                              | Enable/Disable auto recovery from full cluster crash                                                                                                          | `true`                     |
| `mysql.image.repository`                          | MySQL Container image repository                                                                                                                              | `percona/percona-server`   |
| `mysql.image.tag`                                 | MySQL Container image tag                                                                                                                                     | `8.0.36-28`                |
| `mysql.imagePullPolicy`                           | The policy used to update images                                                                                                                              | `Always`                   |
| `mysql.imagePullSecrets`                          | MySQL Container pull secret                                                                                                                                   | `[]`                       |
| `mysql.initImage`                                 | An alternative image for the initial mysql setup                                                                                                              | `""`                       |
| `mysql.size`                                      | Number of MySQL pods                                                                                                                                          | `3`                        |
| `mysql.annotations`                               | MySQL Pods user-defined annotations                                                                                                                           | `{}`                       |
| `mysql.priorityClassName`                         | MySQL Pods priority Class defined by user                                                                                                                     | `""`                       |
| `mysql.runtimeClassName`                          | Name of the Kubernetes Runtime Class for MySQL Pods                                                                                                           | `""`                       |
| `mysql.labels`                                    | MySQL Pods user-defined labels                                                                                                                                | `{}`                       |
| `mysql.schedulerName`                             | The Kubernetes Scheduler                                                                                                                                      | `""`                       |
| `mysql.resources.requests`                        | MySQL Pods resource requests                                                                                                                                  | `memory: 512M`             |
| `mysql.resources.limits`                          | MySQL Pods resource limits                                                                                                                                    | `memory: 1G`               |
| `mysql.livenessProbe`                             | MySQL Pods livenessProbe structure                                                                                                                            | `{}`                       |
| `mysql.readinessProbe`                            | MySQL Pods readinessProbe structure                                                                                                                           | `{}`                       |
| `mysql.nodeSelector`                              | MySQL Pods key-value pairs setting for K8S node assignment                                                                                                    | `{}`                       |
| `mysql.affinity.antiAffinityTopologyKey`          | MySQL Pods simple scheduling restriction on/off for host, zone, region                                                                                        | `"kubernetes.io/hostname"` |
| `mysql.affinity.advanced`                         | MySQL Pods advanced scheduling restriction with match expression engine                                                                                       | `{}`                       |
| `mysql.topologySpreadConstraints`                 | The Label selector for the [Kubernetes Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) | `[]`                       |
| `mysql.tolerations`                               | List of node taints to tolerate for MySQL Pods                                                                                                                | `[]`                       |
| `mysql.expose.enabled`                            | Allow access to MySQL from outside of Kubernetes                                                                                                              | `false`                    |
| `mysql.expose.type`                               | Network service access point type                                                                                                                             | `ClusterIP`                |
| `mysql.expose.annotations`                        | Network service annotations                                                                                                                                   | `{}`                       |
| `mysql.expose.externalTrafficPolicy`              | Network service externalTrafficPolicy                                                                                                                         | ``                         |
| `mysql.expose.internalTrafficPolicy`              | Network service internalTrafficPolicy                                                                                                                         | ``                         |
| `mysql.expose.labels`                             | Network service labels                                                                                                                                        | `{}`                       |
| `mysql.expose.loadBalancerIP`                     | The static IP-address for the load balancer                                                                                                                   | `""`                       |
| `mysql.expose.loadBalancerSourceRanges`           | The range of client IP addresses from which the load balancer should be reachable                                                                             | `[]`                       |
| `mysql.volumeSpec`                                | MySQL Pods storage resources                                                                                                                                  | `{}`                       |
| `mysql.volumeSpec.pvc`                            | MySQL Pods PVC request parameters                                                                                                                             |                            |
| `mysql.volumeSpec.pvc.storageClassName`           | MySQL Pods PVC target storageClass                                                                                                                            | `""`                       |
| `mysql.volumeSpec.pvc.accessModes`                | MySQL Pods PVC access policy                                                                                                                                  | `[]`                       |
| `mysql.volumeSpec.pvc.resources.requests.storage` | MySQL Pods PVC storage size                                                                                                                                   | `3G`                       |
| `mysql.configuration`                             | Custom config for MySQL                                                                                                                                       | `""`                       |
| `mysql.sidecars`                                  | MySQL Pod sidecars                                                                                                                                            | `{}`                       |
| `mysql.sidecarVolumes`                            | MySQL Pod sidecar volumes                                                                                                                                     | `[]`                       |
| `mysql.sidecarPVCs`                               | MySQL Pod sidecar PVCs                                                                                                                                        | `[]`                       |
| `mysql.containerSecurityContext`                  | A custom Kubernetes Security Context for a Container to be used instead of the default one                                                                    | `{}`                       |
| `mysql.podSecurityContext`                        | A custom Kubernetes Security Context for a Pod to be used instead of the default one                                                                          | `{}`                       |
| `mysql.serviceAccountName`                        | A custom service account to be used instead of the default one                                                                                                | `""`                       |
||
| `proxy.haproxy.enabled`                          | Enable/Disable HAProxy pods                                                                                                                                   | `true`                     |
| `proxy.haproxy.image.repository`                 | HAProxy Container image repository                                                                                                                            | `percona/haproxy`          |
| `proxy.haproxy.image.tag`                        | HAProxy Container image tag                                                                                                                                   | `2.8.5`                    |
| `proxy.haproxy.imagePullPolicy`                  | The policy used to update images                                                                                                                              | `Always`                   |
| `proxy.haproxy.imagePullSecrets`                 | HAProxy Container pull secret                                                                                                                                 | `[]`                       |
| `proxy.haproxy.initImage`                        | An alternative image for the initial haproxy setup                                                                                                            | `""`                       |
| `proxy.haproxy.size`                             | HAProxy size (pod quantity)                                                                                                                                   | `3`                        |
| `proxy.haproxy.annotations`                      | HAProxy Pods user-defined annotations                                                                                                                         | `{}`                       |
| `proxy.haproxy.priorityClassName`                | HAProxy Pods priority Class defined by user                                                                                                                   | `""`                       |
| `proxy.haproxy.runtimeClassName`                 | Name of the Kubernetes Runtime Class for HAProxy Pods                                                                                                         | `""`                       |
| `proxy.haproxy.labels`                           | HAProxy Pods user-defined labels                                                                                                                              | `{}`                       |
| `proxy.haproxy.schedulerName`                    | The Kubernetes Scheduler                                                                                                                                      | `""`                       |
| `proxy.haproxy.nodeSelector`                     | HAProxy Pods key-value pairs setting for K8S node assignment                                                                                                  | `{}`                       |
| `proxy.haproxy.affinity.antiAffinityTopologyKey` | HAProxy Pods simple scheduling restriction on/off for host, zone, region                                                                                      | `"kubernetes.io/hostname"` |
| `proxy.haproxy.affinity.advanced`                | HAProxy Pods advanced scheduling restriction with match expression engine                                                                                     | `{}`                       |
| `proxy.haproxy.topologySpreadConstraints`        | The Label selector for the [Kubernetes Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) | `[]`                       |
| `proxy.haproxy.tolerations`                      | List of node taints to tolerate for HAProxy Pods                                                                                                              | `[]`                       |
| `proxy.haproxy.resources.requests`               | HAProxy Pods resource requests                                                                                                                                | `memory: 1G cpu: 600m`     |
| `proxy.haproxy.resources.limits`                 | HAProxy Pods resource limits                                                                                                                                  | `{}`                       |
| `proxy.haproxy.env`                              | HAProxy Pods set env variable                                                                                                                                 | `[]`                       |
| `proxy.haproxy.envFrom`                          | HAProxy Pods set env variable from secret                                                                                                                     | `[]`                       |
| `proxy.haproxy.livenessProbe`                    | HAProxy Pods livenessProbe structure                                                                                                                          | `{}`                       |
| `proxy.haproxy.readinessProbe`                   | HAProxy Pods readinessProbe structure                                                                                                                         | `{}`                       |
| `proxy.haproxy.configuration`                    | Custom config for HAProxy                                                                                                                                     | `""`                       |
| `proxy.haproxy.containerSecurityContext`         | A custom Kubernetes Security Context for a Container to be used instead of the default one                                                                    | `{}`                       |
| `proxy.haproxy.podSecurityContext`               | A custom Kubernetes Security Context for a Pod to be used instead of the default one                                                                          | `{}`                       |
| `proxy.haproxy.serviceAccountName`               | A custom service account to be used instead of the default one                                                                                                | `""`                       |
| `proxy.haproxy.expose.type`                      | Network service access point type                                                                                                                             | `""`                       |
| `proxy.haproxy.expose.annotations`               | Network service annotations                                                                                                                                   | `{}`                       |
| `proxy.haproxy.expose.externalTrafficPolicy`     | Network service externalTrafficPolicy                                                                                                                         | ``                         |
| `proxy.haproxy.expose.internalTrafficPolicy`     | Network service internalTrafficPolicy                                                                                                                         | ``                         |
| `proxy.haproxy.expose.labels`                    | Network service labels                                                                                                                                        | `{}`                       |
| `proxy.haproxy.expose.loadBalancerIP`            | The static IP-address for the load balancer                                                                                                                   | `""`                       |
| `proxy.haproxy.expose.loadBalancerSourceRanges`  | The range of client IP addresses from which the load balancer should be reachable                                                                             | `[]`                       |
||
| `proxy.router.enabled`                          | Enable/Disable Router pods in group replication                                                                                                               | `false`                        |
| `proxy.router.image.repository`                 | Router Container image repository                                                                                                                             | `percona/percona-mysql-router` |
| `proxy.router.image.tag`                        | Router Container image tag                                                                                                                                    | `8.0.36`                       |
| `proxy.router.imagePullPolicy`                  | The policy used to update images                                                                                                                              | `Always`                       |
| `proxy.router.imagePullSecrets`                 | Router Container pull secret                                                                                                                                  | `[]`                           |
| `proxy.router.initImage`                        | An alternative image for the initial router setup                                                                                                             | `""`                           |
| `proxy.router.size`                             | Router size (pod quantity)                                                                                                                                    | `3`                            |
| `proxy.router.annotations`                      | Router Pods user-defined annotations                                                                                                                          | `{}`                           |
| `proxy.router.priorityClassName`                | Router Pods priority Class defined by user                                                                                                                    | `""`                           |
| `proxy.router.runtimeClassName`                 | Name of the Kubernetes Runtime Class for Router Pods                                                                                                          | `""`                           |
| `proxy.router.labels`                           | Router Pods user-defined labels                                                                                                                               | `{}`                           |
| `proxy.router.schedulerName`                    | The Kubernetes Scheduler                                                                                                                                      | `""`                           |
| `proxy.router.nodeSelector`                     | Router Pods key-value pairs setting for K8S node assignment                                                                                                   | `{}`                           |
| `proxy.router.affinity.antiAffinityTopologyKey` | Router Pods simple scheduling restriction on/off for host, zone, region                                                                                       | `"kubernetes.io/hostname"`     |
| `proxy.router.affinity.advanced`                | Router Pods advanced scheduling restriction with match expression engine                                                                                      | `{}`                           |
| `proxy.router.topologySpreadConstraints`        | The Label selector for the [Kubernetes Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) | `[]`                           |
| `proxy.router.configuration`                    | User defined Router options according to Router configuration file syntax                                                                                     | ``                             |
| `proxy.router.tolerations`                      | List of node taints to tolerate for Router Pods                                                                                                               | `[]`                           |
| `proxy.router.resources.requests`               | Router Pods resource requests                                                                                                                                 | `memory: 256M`                 |
| `proxy.router.resources.limits`                 | Router Pods resource limits                                                                                                                                   | `memory: 256M`                 |
| `proxy.router.containerSecurityContext`         | A custom Kubernetes Security Context for a Container to be used instead of the default one                                                                    | `{}`                           |
| `proxy.router.podSecurityContext`               | A custom Kubernetes Security Context for a Pod to be used instead of the default one                                                                          | `{}`                           |
| `proxy.router.serviceAccountName`               | A custom service account to be used instead of the default one                                                                                                | `""`                           |
| `proxy.router.expose.type`                      | Network service access point type                                                                                                                             | `""`                           |
| `proxy.router.expose.annotations`               | Network service annotations                                                                                                                                   | `{}`                           |
| `proxy.router.expose.externalTrafficPolicy`     | Network service externalTrafficPolicy                                                                                                                         | ``                             |
| `proxy.router.expose.internalTrafficPolicy`     | Network service internalTrafficPolicy                                                                                                                         | ``                             |
| `proxy.router.expose.labels`                    | Network service labels                                                                                                                                        | `{}`                           |
| `proxy.router.expose.loadBalancerIP`            | The static IP-address for the load balancer                                                                                                                   | `""`                           |
| `proxy.router.expose.loadBalancerSourceRanges`  | The range of client IP addresses from which the load balancer should be reachable                                                                             | `[]`                           |
||
| `orchestrator.enabled`                                   | Enable/Disable orchestrator pods in async replication                                                                                                         | `true`                         |
| `orchestrator.image.repository`                          | Orchestrator Container image repository                                                                                                                       | `percona/percona-orchestrator` |
| `orchestrator.image.tag`                                 | Orchestrator Container image tag                                                                                                                              | `3.2.6-12`                     |
| `orchestrator.imagePullPolicy`                           | The policy used to update images                                                                                                                              | `Always`                       |
| `orchestrator.imagePullSecrets`                          | Orchestrator Container pull secret                                                                                                                            | `[]`                           |
| `orchestrator.serviceAccountName`                        | A custom service account to be used instead of the default one                                                                                                | `""`                           |
| `orchestrator.initImage`                                 | An alternative image for the initial orchestrator setup                                                                                                       | `""`                           |
| `orchestrator.size`                                      | Orchestrator size (pod quantity)                                                                                                                              | `3`                            |
| `orchestrator.annotations`                               | Orchestrator Pods user-defined annotations                                                                                                                    | `{}`                           |
| `orchestrator.priorityClassName`                         | Orchestrator Pods priority Class defined by user                                                                                                              | `""`                           |
| `orchestrator.runtimeClassName`                          | Name of the Kubernetes Runtime Class for Orchestrator Pods                                                                                                    | `""`                           |
| `orchestrator.labels`                                    | Orchestrator Pods user-defined labels                                                                                                                         | `{}`                           |
| `orchestrator.schedulerName`                             | The Kubernetes Scheduler                                                                                                                                      | `""`                           |
| `orchestrator.nodeSelector`                              | Orchestrator Pods key-value pairs setting for K8S node assignment                                                                                             | `{}`                           |
| `orchestrator.affinity.antiAffinityTopologyKey`          | Orchestrator Pods simple scheduling restriction on/off for host, zone, region                                                                                 | `"kubernetes.io/hostname"`     |
| `orchestrator.affinity.advanced`                         | Orchestrator Pods advanced scheduling restriction with match expression engine                                                                                | `{}`                           |
| `orchestrator.topologySpreadConstraints`                 | The Label selector for the [Kubernetes Pod Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/) | `[]`                           |
| `orchestrator.tolerations`                               | List of node taints to tolerate for Orchestrator Pods                                                                                                         | `[]`                           |
| `orchestrator.resources.requests`                        | Orchestrator Pods resource requests                                                                                                                           | `memory: 128M`                 |
| `orchestrator.resources.limits`                          | Orchestrator Pods resource limits                                                                                                                             | `memory: 256M`                 |
| `orchestrator.volumeSpec`                                | Orchestrator Pods storage resources                                                                                                                           | `{}`                           |
| `orchestrator.volumeSpec.pvc`                            | Orchestrator Pods PVC request parameters                                                                                                                      |                                |
| `orchestrator.volumeSpec.pvc.storageClassName`           | Orchestrator Pods PVC target storageClass                                                                                                                     | `""`                           |
| `orchestrator.volumeSpec.pvc.accessModes`                | Orchestrator Pods PVC access policy                                                                                                                           | `[]`                           |
| `orchestrator.volumeSpec.pvc.resources.requests.storage` | Orchestrator Pods PVC storage size                                                                                                                            | `1G`                           |
| `orchestrator.containerSecurityContext`                  | A custom Kubernetes Security Context for a Container to be used instead of the default one                                                                    | `{}`                           |
| `orchestrator.podSecurityContext`                        | A custom Kubernetes Security Context for a Pod to be used instead of the default one                                                                          | `{}`                           |
| `orchestrator.expose.type`                               | Network service access point type                                                                                                                             | `""`                           |
| `orchestrator.expose.annotations`                        | Network service annotations                                                                                                                                   | `{}`                           |
| `orchestrator.expose.externalTrafficPolicy`              | Network service externalTrafficPolicy                                                                                                                         | ``                             |
| `orchestrator.expose.internalTrafficPolicy`              | Network service internalTrafficPolicy                                                                                                                         | ``                             |
| `orchestrator.expose.labels`                             | Network service labels                                                                                                                                        | `{}`                           |
| `orchestrator.expose.loadBalancerIP`                     | The static IP-address for the load balancer                                                                                                                   | `""`                           |
| `orchestrator.expose.loadBalancerSourceRanges`           | The range of client IP addresses from which the load balancer should be reachable                                                                             | `[]`                           |
||
| `pmm.image.repository`   | PMM Container image repository          | `percona/pmm-client`                |
| `pmm.image.tag`          | PMM Container image tag                 | `2.42.0`                            |
| `pmm.imagePullPolicy`    | The policy used to update images        | ``                                  |
| `pmm.serverHost`         | PMM server related K8S service hostname | `monitoring-service`                |
| `pmm.serverUser`         | PMM server user                         | `admin`                             |
| `pmm.resources.requests` | PMM Container resource requests         | `{"memory": "150M", "cpu": "300m"}` |
| `pmm.resources.limits`   | PMM Container resource limits           | `{}`                                |
||
| `toolkit.image.repository`   | Percona Toolkit Container image repository | `percona/percona-toolkit` |
| `toolkit.image.tag`          | Percona Toolkit Container image tag        | `3.6.0`                   |
| `toolkit.imagePullPolicy`    | The policy used to update images           | ``                        |
| `toolkit.resources.requests` | Toolkit Container resource requests        | `{}`                      |
| `toolkit.resources.limits`   | Toolkit Container resource limits          | `{}`                      |
||
| `backup.enabled`                  | Enable backups                                                                              | `true`                       |
| `backup.image.repository`         | Backup Container image repository                                                           | `percona/percona-xtrabackup` |
| `backup.image.tag`                | Backup Container image tag                                                                  | `8.0.35-31`                  |
| `backup.backoffLimit`             | The number of retries to make a backup                                                      | ``                           |
| `backup.imagePullPolicy`          | The policy used to update images                                                            | `Always`                     |
| `backup.imagePullSecrets`         | Backup Container pull secret                                                                | `[]`                         |
| `backup.initImage`                | An alternative image for the backup setup                                                   | `""`                         |
| `backup.serviceAccountName`       | Run Backup Container under specified K8S SA                                                 | `""`                         |
| `backup.containerSecurityContext` | A custom Kubernetes Security Context for a Container to be used instead of the default one  | `{}`                         |
| `backup.resources`                | Backup Pods resource requests and limits                                                    | `{}`                         |
| `backup.storages`                 | Local/remote backup storages settings                                                       | `{}`                         |
||
| `passwords` | Cluster user passwords (by default generated by operator) | `{}` |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`
Notice that you can use multiple replica sets only with sharding enabled.

## Examples

### Deploy a database cluster with specific storage size

This is starting a cluster with specific PVC size.

```bash
$ helm install dev  --namespace ps . \
    --set "mysql.volumeSpec.pvc.resources.requests.storage=20G"
```
