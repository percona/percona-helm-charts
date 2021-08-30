# pxc-db: A chart for installing Percona XtraDB Operator managed Databases

This chart implements Percona XtraDB Cluster deployment in Kubernets via Custom Resource object. The project itself can be found here:
* <https://github.com/percona/percona-xtradb-cluster-operator>

## Pre-requisites
* [PXC operator](https://hub.helm.sh/charts/percona/pxc-operator) running in you K8S cluster
* Kubernetes 1.16+
* PV support on the underlying infrastructure - only if you are provisioning persistent volume(s).
* Helm v3

## Custom Resource Details
* <https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/>

## StatefulSet Details
* <https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/>

## Chart Details
This chart will:
* deploy a PXC database Pods (Custom Resource -> StatefulSet) for the further XtraDB Cluster creation in K8S.

### Installing the Chart
To install the chart with the `pxc` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-db percona/pxc-db --version 1.9.1 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `pause`                         | Stop PXC Database safely                                                      | `false`                                   |
| `allowUnsafeConfigurations`     | Allows forbidden configurations like even number of PXC cluster pods          | `false`                                   |
| `updateStrategy`                | Regulates the way how PXC Cluster Pods will be updated after setting a new image | `SmartUpdate`                          |
| `upgradeOptions.versionServiceEndpoint` | Endpoint for actual PXC Versions provider                             | `https://check.percona.com/versions`      |
| `upgradeOptions.apply`          | PXC image to apply from version service - `recommended`, `latest`, actual version like `8.0.19-10.1` | `8.0-recommended` |
| `upgradeOptions.schedule`          | Cron formatted time to execute the update | `"0 4 * * *"` |
| `finalizers:delete-pxc-pods-in-order`  | Set this if you want to delete PXC pods in order on cluster deletion |   |
| `finalizers:delete-proxysql-pvc`  | Set this if you want to delete proxysql persistent volumes on cluster deletion |   |
| `finalizers:delete-pxc-pvc`  | Set this if you want to delete database persistent volumes on cluster deletion |   |
| `pxc.size`                                  | PXC Cluster target member (pod) quantity. Can't even if `allowUnsafeConfigurations` is `true`                            | `3`                              |
| `pxc.image.repository`                      | PXC Container image repository                                                                                           | `percona/percona-xtradb-cluster` |
| `pxc.image.tag`                             | PXC Container image tag                                                                                                  | `8.0.23-14.1`                    |
| `pxc.autoRecovery`                          | Enable full cluster crash auto recovery                                                                                  | `true`                           |
| `pxc.expose.enabled`                        | Enable or disable exposing `Percona XtraDB Cluster` nodes with dedicated IP addresses                                    | `true`                           |
| `pxc.expose.type`                           | The Kubernetes Service Type used for exposure                                                                            | `LoadBalancer`                   |
| `pxc.expose.loadBalancerSourceRanges`       | The range of client IP addresses from which the load balancer should be reachable (if not set, there is no limitations)  | `10.0.0.0/8`                     |
| `pxc.expose.annotations`                    | The Kubernetes annotations                                                                                               | `true`                           |
| `pxc.replicationChannels.name`              | Name of the replication channel for cross-site replication                                                               | `pxc1_to_pxc2`                   |
| `pxc.replicationChannels.isSource`          | Should the cluster act as Source (true) or Replica (false) in cross-site replication                                     | `false`                          |
| `pxc.replicationChannels.sourcesList.host`  | For the cross-site replication Replica cluster, this key should contain the hostname or IP address of the Source cluster | `10.95.251.101`                  |
| `pxc.replicationChannels.sourcesList.port`  | For the cross-site replication Replica cluster, this key should contain the Source port number                           | `3306`                           |
| `pxc.replicationChannels.sourcesList.weight`| For the cross-site replication Replica cluster, this key should contain the Source cluster weight                        | `100`                            |
| `pxc.imagePullSecrets`                      | PXC Container pull secret                                                                                                | `[]`                             |
| `pxc.annotations`                           | PXC Pod user-defined annotations                                                                                         | `{}`                             |
| `pxc.priorityClassName`                     | PXC Pod priority Class defined by user                                                                                   |                                  |
| `pxc.labels`                                | PXC Pod user-defined labels                                                                                              | `{}`                             |
| `pxc.readinessDelaySec`                     | PXC Pod delay for readiness probe in seconds                                                                             | `15`                             |
| `pxc.livenessDelaySec`                      | PXC Pod delay for liveness probe in seconds                                                                              | `300`                            |
| `pxc.forceUnsafeBootstrap`                  | Order PXC Pods to override the previous Pod crash                                                                        | `false`                          |
| `pxc.configuration`                         | User defined MySQL options according to MySQL configuration file syntax                                                  | ``                               |
| `pxc.resources.requests`                    | PXC Pods resource requests                                                                                               | `{"memory": "1G", "cpu": "600m"}`|
| `pxc.resources.limits`                      | PXC Pods resource limits                                                                                                 | `{}`                             |
| `pxc.sidecars`                              | PXC Pods sidecars                                                                                                        | `[]`                             |
| `pxc.sidecarResources.requests`             | PXC sidecar resource requests                                                                                            | `{}`                             |
| `pxc.sidecarResources.limits`               | PXC sidecar resource limits                                                                                              | `{}`                             |
| `pxc.nodeSelector`                          | PXC Pods key-value pairs setting for K8S node assingment                                                                 | `{}`                             |
| `pxc.affinity.antiAffinityTopologyKey`      | PXC Pods simple scheduling restriction on/off for host, zone, region                                                     | `"kubernetes.io/hostname"`       |
| `pxc.affinity.advanced`                     | PXC Pods advanced scheduling restriction with match expression engine                                                    | `{}`                             |
| `pxc.tolerations`                           | List of node taints to tolerate for PXC Pods                                                                             | `[]`                             |
| `pxc.gracePeriod`                           | Allowed time for graceful shutdown                                                                                       | `600`                            |
| `pxc.podDisruptionBudget.maxUnavailable`    | Instruct Kubernetes about the failed pods allowed quantity                                                               | `1`                              |
| `pxc.persistence.enabled`                   | Requests a persistent storage (`hostPath` or `storageClass`) from K8S for PXC Pods datadir                               | `true`                           |
| `pxc.persistence.hostPath`                  | Sets datadir path on K8S node for all PXC Pods. Available only when `pxc.persistence.enabled: true`                      |                                  |
| `pxc.persistence.storageClass`              | Sets K8S storageClass name for all PXC Pods PVC. Available only when `pxc.persistence.enabled: true`                     | `-`                              |
| `pxc.persistence.accessMode`                | Sets K8S persistent storage access policy for all PXC Pods                                                               | `ReadWriteOnce`                  |
| `pxc.persistence.size`                      | Sets K8S persistent storage size for all PXC Pods                                                                        | `8Gi`                            |
| `pxc.disableTLS`                            | Disable PXC Pod communication with TLS                                                                                   | `false`                          |
| `pxc.certManager`                           | Enable this option if you want the operator to request certificates from `cert-manager`                                  | `false`                          |
| `pxc.readinessProbes.failureThreshold`      | When a probe fails, Kubernetes will try failureThreshold times before giving up                                          | `5`                              |
| `pxc.readinessProbes.initialDelaySeconds`   | Number of seconds after the container has started before liveness or readiness probes are initiated                      | `15`                             |
| `pxc.readinessProbes.periodSeconds`         | How often (in seconds) to perform the probe                                                                              | `30`                             |
| `pxc.readinessProbes.successThreshold`      | Minimum consecutive successes for the probe to be considered successful after having failed                              | `1`                              |
| `pxc.readinessProbes.timeoutSeconds`        | Number of seconds after which the probe times out                                                                        | `15`                             |
| `pxc.livenessProbes.failureThreshold`       | When a probe fails, Kubernetes will try failureThreshold times before giving up                                          | `3`                              |
| `pxc.livenessProbes.initialDelaySeconds`    | Number of seconds after the container has started before liveness or readiness probes are initiated                      | `300`                            |
| `pxc.livenessProbes.periodSeconds`          | How often (in seconds) to perform the probe                                                                              | `10`                             |
| `pxc.livenessProbes.successThreshold`       | Minimum consecutive successes for the probe to be considered successful after having failed                              | `1`                              |
| `pxc.livenessProbes.timeoutSeconds`         | Number of seconds after which the probe times out                                                                        | `5`                              |
| |
| `haproxy.enabled` | Use HAProxy as TCP proxy for PXC cluster | `true` |
| `haproxy.size`                      | HAProxy target pod quantity. Can't even if `allowUnsafeConfigurations` is `true` | `3` |
| `haproxy.image`              | HAProxy Container image repository                                           | `percona/percona-xtradb-cluster-operator:1.9.0-haproxy`|
| `haproxy.imagePullSecrets`             | HAProxy Container pull secret                                                | `[]`                                      |
| `haproxy.configuration`             | User defined HAProxy options according to HAProxy configuration file syntax       | ``     |
| `haproxy.annotations`             | HAProxy Pod user-defined annotations                                         | `{}` |
| `haproxy.priorityClassName`       | HAProxy Pod priority Class defined by user                                   |  |
| `haproxy.externalTrafficPolicy`   | Desire service to route external traffic to node-local or cluster-wide endpoints  |  |
| `haproxy.loadBalancerSourceRanges` | Limit which client IP's can access the Network Load Balancer                | `[]` |
| `haproxy.serviceType`             | Specify what kind of Service you want                                        | `ClusterIP` |
| `haproxy.serviceAnnotations`      | Specify service annotations                                                  | `{}` |
| `haproxy.labels`                  | HAProxy Pod user-defined labels                                              | `{}` |
| `haproxy.readinessDelaySec`       | HAProxy Pod delay for readiness probe in seconds                             | `15` |
| `haproxy.livenessDelaySec`        | HAProxy Pod delay for liveness probe in seconds                             | `300` |
| `haproxy.forceUnsafeBootstrap`        | Order HAProxy Pods to override the previous Pod crash                             | `false` |
| `haproxy.resources.requests`                     | HAProxy Pods resource requests                                    | `{"memory": "1G", "cpu": "600m"}`                                      |
| `haproxy.resources.limits`                     | HAProxy Pods resource limits                                    | `{}`                                      |
| `haproxy.sidecars`                              | HAProxy Pods sidecars                                                                                                        | `[]`                             |
| `haproxy.sidecarResources.requests`             | HAProxy sidecar resource requests                                                                                            | `{}`                             |
| `haproxy.sidecarResources.limits`               | HAProxy sidecar resource limits                                                                                              | `{}`                             |
| `haproxy.nodeSelector`                  | HAProxy Pods key-value pairs setting for K8S node assingment                 | `{}`                                      |
| `haproxy.affinity.antiAffinityTopologyKey` | HAProxy Pods simple scheduling restriction on/off for host, zone, region         | `"kubernetes.io/hostname"` |
| `haproxy.affinity.advanced` | HAProxy Pods advanced scheduling restriction with match expression engine          | `{}` |
| `haproxy.tolerations`                   | List of node taints to tolerate for HAProxy Pods                       | `[]`                                      |
| `haproxy.gracePeriod`                   | Allowed time for graceful shutdown                       | `600`                                      |
| `haproxy.podDisruptionBudget.maxUnavailable` | Instruct Kubernetes about the failed pods allowed quantity           | `1`                                      |
| `haproxy.readinessProbes.failureThreshold` | When a probe fails, Kubernetes will try failureThreshold times before giving up | `5`                      |
| `haproxy.readinessProbes.initialDelaySeconds` | Number of seconds after the container has started before liveness or readiness probes are initiated | `15`                      |
| `haproxy.readinessProbes.periodSeconds` | How often (in seconds) to perform the probe | `30`                      |
| `haproxy.readinessProbes.successThreshold` | Minimum consecutive successes for the probe to be considered successful after having failed | `1`                      |
| `haproxy.readinessProbes.timeoutSeconds` | Number of seconds after which the probe times out | `15`                      |
| `haproxy.livenessProbes.failureThreshold` | When a probe fails, Kubernetes will try failureThreshold times before giving up | `3`                      |
| `haproxy.livenessProbes.initialDelaySeconds` | Number of seconds after the container has started before liveness or readiness probes are initiated | `300`                      |
| `haproxy.livenessProbes.periodSeconds` | How often (in seconds) to perform the probe | `10`                      |
| `haproxy.livenessProbes.successThreshold` | Minimum consecutive successes for the probe to be considered successful after having failed | `1`                      |
| `haproxy.livenessProbes.timeoutSeconds` | Number of seconds after which the probe times out | `5` |
| |
| `proxysql.enabled` | Use ProxySQL as TCP proxy for PXC cluster | `false` |
| `proxysql.size`                      | ProxySQL target pod quantity. Can't even if `allowUnsafeConfigurations` is `true` | `3` |
| `proxysql.image`              | ProxySQL Container image                                           | `percona/percona-xtradb-cluster-operator:1.9.0-proxysql` |
| `proxysql.imagePullSecrets`             | ProxySQL Container pull secret                                                | `[]`                                      |
| `proxysql.configuration`             | User defined ProxySQL options according to ProxySQL configuration file syntax       | ``     |
| `proxysql.annotations`             | ProxySQL Pod user-defined annotations                                         | `{}` |
| `proxysql.priorityClassName`       | ProxySQL Pod priority Class defined by user                                   |  |
| `proxysql.externalTrafficPolicy`   | Desire service to route external traffic to node-local or cluster-wide endpoints  |  |
| `proxysql.loadBalancerSourceRanges` | Limit which client IP's can access the Network Load Balancer                 | `[]` |
| `proxysql.serviceType`             | Specify what kind of Service you want                                         | `ClusterIP` |
| `proxysql.serviceAnnotations`      | Specify service annotations                                                   | `{}` |
| `proxysql.labels`                  | ProxySQL Pod user-defined labels                                              | `{}` |
| `proxysql.readinessDelaySec`       | ProxySQL Pod delay for readiness probe in seconds                             | `15` |
| `proxysql.livenessDelaySec`        | ProxySQL Pod delay for liveness probe in seconds                             | `300` |
| `proxysql.forceUnsafeBootstrap`        | Order ProxySQL Pods to override the previous Pod crash                             | `false` |
| `proxysql.resources.requests`                     | ProxySQL Pods resource requests                                    | `{"memory": "1G", "cpu": "600m"}`                                      |
| `proxysql.resources.limits`                     | ProxySQL Pods resource limits                                    | `{}`                                      |
| `proxysql.sidecars`                              | ProxySQL Pods sidecars                                                                                                        | `[]`                             |
| `proxysql.sidecarResources.requests`             | ProxySQL sidecar resource requests                                                                                            | `{}`                             |
| `proxysql.sidecarResources.limits`               | ProxySQL sidecar resource limits                                                                                              | `{}`                             |
| `proxysql.nodeSelector`                  | ProxySQL Pods key-value pairs setting for K8S node assingment                 | `{}`                                      |
| `proxysql.affinity.antiAffinityTopologyKey` | ProxySQL Pods simple scheduling restriction on/off for host, zone, region         | `"kubernetes.io/hostname"` |
| `proxysql.affinity.advanced` | ProxySQL Pods advanced scheduling restriction with match expression engine          | `{}` |
| `proxysql.tolerations`                   | List of node taints to tolerate for ProxySQL Pods                       | `[]`                                      |
| `proxysql.gracePeriod`                   | Allowed time for graceful shutdown                       | `600`                                      |
| `proxysql.podDisruptionBudget.maxUnavailable` | Instruct Kubernetes about the failed pods allowed quantity           | `1`                                      |
| `proxysql.persistence.enabled` | Requests a persistent storage (`hostPath` or `storageClass`) from K8S for ProxySQL Pods  | `true`                                      |
| `proxysql.persistence.hostPath` | Sets datadir path on K8S node for all ProxySQL Pods. Available only when `proxysql.persistence.enabled: true` |                             |
| `proxysql.persistence.storageClass` | Sets K8S storageClass name for all ProxySQL Pods PVC. Available only when `proxysql.persistence.enabled: true` | `-`                      |
| `proxysql.persistence.accessMode` | Sets K8S persistent storage access policy for all ProxySQL Pods | `ReadWriteOnce`                      |
| `proxysql.persistence.size` | Sets K8S persistent storage size for all ProxySQL Pods | `8Gi`                      |
| |
| `logcollector.enabled`            | Enable log collector container                                           | `true` |
| `logcollector.image`              | Log collector image repository                                           | `percona/percona-xtradb-cluster-operator:1.9.0-logcollector` |
| `logcollector.configuration`      | User defined configuration for logcollector                              |  ``  |
| `logcollector.resources.requests` | Log collector resource requests                                          | `{}` |
| `logcollector.resources.limits`   | Log collector resource limits                                            | `{}` |
| |
| `pmm.enabled` | Enable integration with [Percona Monitoring and Management software](https://www.percona.com/doc/kubernetes-operator-for-pxc/monitoring.html) | `false` |
| `pmm.image.repository`              | PMM Container image repository                                           | `percona/pmm-client` |
| `pmm.image.tag`                     | PMM Container image tag                                                  | `2.18.0`             |
| `pmm.serverHost`                    | PMM server related K8S service hostname                                  | `monitoring-service` |
| `pmm.serverUser`                    | Username for accessing PXC database internals                            | `admin` |
| `pmm.resources.requests`            | PMM Container resource requests                                          | `{}` |
| `pmm.resources.limits`              | PMM Container resource limits                                            | `{}` |
| |
| `backup.enabled` | Enables backups for PXC cluster | `true` |
| `backup.image`              | Backup Container image                                           | `percona/percona-xtradb-cluster-operator:1.9.0-pxc8.0-backup` |
| `backup.imagePullSecrets`             | Backup Container pull secret                                                | `[]`                                      |
| `backup.pitr.enabled`             | Enable point in time recovery                                                | `false`                                      |
| `backup.pitr.storageName`             | Storage name for PITR                                                | `s3-us-west-binlogs`                                      |
| `backup.pitr.timeBetweenUploads`             | Time between uploads for PITR                                                | `60`                                      |
| `backup.storages.fs-pvc` | Backups storage configuration, where `storages:` is a high-level key for the underlying structure. `fs-pvc` is a user-defined storage name. | |
| `backup.storages.fs-pvc.type`             | Backup storage type                                          | `filysystem` |
| `backup.storages.fs-pvc.volume.persistentVolumeClaim.accessModes`       | Backup PVC access policy                                   | `["ReadWriteOnce"]` |
| `backup.storages.fs-pvc.volume.persistentVolumeClaim.resources`         | Backup Pod resources specification      | `{}` |
| `backup.storages.fs-pvc.volume.persistentVolumeClaim.resources.requests.storage`         | Backup Pod datadir backups size      | `6Gi` |
| `backup.schedule`         | Backup execution timetable      | `[]` |
| `backup.schedule.0.name`         | Backup execution timetable name     | `daily-backup` |
| `backup.schedule.0.schedule`         | Backup execution timetable cron timing     | `0 0 * * *` |
| `backup.schedule.0.keep`         | Backup items to keep     | `0 0 * * *` |
| `backup.schedule.0.storageName`         | Backup target storage     | `fs-pvc` |
| |
| `secrets.passwords.root`         | Default user secret | `insecure-root-password`         |
| `secrets.passwords.xtrabackup`   | Default user secret | `insecure-xtrabackup-password`   |
| `secrets.passwords.monitor`      | Default user secret | `insecure-monitor-password`      |
| `secrets.passwords.clustercheck` | Default user secret | `insecure-clustercheck-password` |
| `secrets.passwords.proxyadmin`   | Default user secret | `insecure-proxyadmin-password`   |
| `secrets.passwords.pmmserver`    | Default user secret | `insecure-pmmserver-password`    |
| `secrets.passwords.operator`     | Default user secret | `insecure-operator-password`     |
| `secrets.passwords.replication`  | Default user secret | `insecure-replication-password`  |
| `secrets.tls`       | Not needed in case if you're using cert-manager. Structure expects keys `ca.crt`, `tls.crt`, `tls.key` and files contents encoded in base64.                             | `{}` |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`

## Examples

### Deploy a Cluster without a MySQL Proxy, no backups, no persistent disks

This is great for a dev cluster as it doesn't require a persistent disk and doesn't bother with a proxy, backups, or TLS.

```bash
$ helm install dev  --namespace pxc . \
    --set proxysql.enabled=false --set pxc.disableTLS=true \
    --set pxc.persistence.enabled=false --set backup-enabled=false
```

### Deploy a cluster with certificates provided by Cert Manager

First you need a working cert-manager installed with appropriate Issuers set up. Check out the [JetStack Helm Chart](https://hub.helm.sh/charts/jetstack/cert-manager) to do that.

By setting `pxc.certManager=true` we're signaling the Helm chart to not create secrets,which will in turn let the operator know to request appropriate `certificate` resources to be filled by cert-manager.

```bash
$ helm install dev  --namespace pxc . --set pxc.certManager=true
```

### Deploy a production grade cluster

The pxc-database chart contains an example production values file that should set you
well on your path to running a production database. It is not fully production grade as
there are some requirements for you to provide your own secrets for passwords and TLS to be truly production ready, but it does provide comments on how to do those parts.

```bash
$ helm install prod --file production-values.yaml --namespace pxc .
```
