# Percona Monitoring and Management (PMM) High Availability

## Introduction

PMM HA is a high availability deployment of Percona Monitoring and Management (PMM), an open source database monitoring, observability and management tool. This chart provides a production-ready, scalable, and fault-tolerant PMM deployment with multiple replicas, load balancing, and external database backends.

Check more info here: https://docs.percona.com/percona-monitoring-and-management/index.html

## High Availability Features

This PMM HA chart provides the following high availability features:

- **Multiple PMM Server Replicas**: Deploy 3 PMM server instances for redundancy
- **HAProxy Load Balancing**: 3 HAProxy replicas with anti-affinity for traffic distribution
- **External ClickHouse Cluster**: Dedicated ClickHouse cluster with 3 replicas and ClickHouse Keeper
- **External VictoriaMetrics Cluster**: Distributed metrics storage with multiple replicas
- **External PostgreSQL Database**: HA PostgreSQL cluster for Grafana metadata
- **Pod Anti-Affinity**: Ensures components are distributed across different nodes
- **Health Checks**: Comprehensive readiness and liveness probes
- **TLS/SSL Support**: Secure communication with configurable certificates

## Prerequisites

- Kubernetes 1.22+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure
- **For HA Setup**: Minimum 3 worker nodes recommended for proper anti-affinity distribution
- **Storage Requirements**: Sufficient persistent storage for all components (PMM, ClickHouse, VictoriaMetrics, PostgreSQL)
- **Resource Requirements**: Adequate CPU and memory resources for multiple replicas
- **Network Requirements**: Proper network policies and ingress configuration for external access

## Installing the Chart

To install the PMM HA chart with the release name `pmm-ha`:

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install pmm-ha percona/pmm-ha
```

The command deploys PMM HA on the Kubernetes cluster with the default high availability configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm list`

> **Important**: For production deployments, you must create the `pmm-secret` manually before installation since `secret.create` is set to `false` by default. See the [Creating PMM Secret Manually](#creating-pmm-secret-manually) section for detailed examples.

## Uninstalling the Chart

To uninstall `pmm-ha` deployment:

```sh
helm uninstall pmm-ha
```

This command takes a release name and uninstalls the release.

It removes all of the resources associated with the last release of the chart as well as the release history.

> **Warning**: This will remove all PMM data, including metrics, dashboards, and configuration. Make sure to backup any important data before uninstalling.

## Parameters

### Percona Monitoring and Management (PMM) parameters

| Name                                 | Description                                                                                                                                                                                                                                   | Value                |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |----------------------|
| `image.repository`                   | PMM image repository                                                                                                                                                                                                                          | `percona/pmm-server` |
| `image.pullPolicy`                   | PMM image pull policy                                                                                                                                                                                                                         | `IfNotPresent`       |
| `image.tag`                          | PMM image tag (immutable tags are recommended)                                                                                                                                                                                                | `2.44.0`             |
| `image.imagePullSecrets`             | Global Docker registry secret names as an array                                                                                                                                                                                               | `[]`                 |
| `pmmEnv.DISABLE_UPDATES`             | Disables a periodic check for new PMM versions as well as ability to apply upgrades using the UI (need to be disabled in k8s environment as updates rolled with helm/container update)                                                        | `1`                  |
| `pmmResources`                       | optional [Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) requested for [PMM container](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/index.html#set-up-pmm-server) | `{}`                 |
| `readyProbeConf.initialDelaySeconds` | Number of seconds after the container has started before readiness probes is initiated                                                                                                                                                        | `1`                  |
| `readyProbeConf.periodSeconds`       | How often (in seconds) to perform the probe                                                                                                                                                                                                   | `5`                  |
| `readyProbeConf.failureThreshold`    | When a probe fails, Kubernetes will try failureThreshold times before giving up                                                                                                                                                               | `6`                  |


### PMM secrets

| Name                  | Description                                                                                                                                                                        | Value        |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `secret.name`         | Defines the name of the k8s secret that holds passwords and other secrets                                                                                                          | `pmm-secret` |
| `secret.annotations`  | Defines the annotations of the k8s secret that holds passwords and other secrets                                                                                                   | `{}`         |
| `secret.create`       | If true then secret will be generated by Helm chart. Otherwise it is expected to be created by user and all of its keys will be mounted as env vars.                                                                               | `false`       |
| `secret.pmm_password` | Initial PMM password - it changes only on the first deployment, ignored if PMM was already provisioned and just restarted. If PMM admin password is not set, it will be generated. | `""`         |
| `certs`               | Optional certificates, if not provided PMM would use generated self-signed certificates,                                                                                           | `{}`         |


### PMM network configuration

| Name                              | Description                                                                                                                                    | Value                 |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `service.name`                    | Service name that is dns name monitoring services would send data to. `monitoring-service` used by default by pmm-client in Percona operators. | `monitoring-service`  |
| `service.type`                    | Kubernetes Service type                                                                                                                        | `ClusterIP`            |
| `service.ports[0].port`           | https port number                                                                                                                              | `8443`                 |
| `service.ports[0].targetPort`     | target port to map for statefulset and ingress                                                                                                 | `https`               |
| `service.ports[0].protocol`       | protocol for https                                                                                                                             | `TCP`                 |
| `service.ports[0].name`           | port name                                                                                                                                      | `https`               |
| `service.ports[1].port`           | http port number                                                                                                                               | `8080`                  |
| `service.ports[1].targetPort`     | target port to map for statefulset and ingress                                                                                                 | `http`                |
| `service.ports[1].protocol`       | protocol for http                                                                                                                              | `TCP`                 |
| `service.ports[1].name`           | port name                                                                                                                                      | `http`                |
| `ingress.enabled`                 | -- Enable ingress controller resource                                                                                                          | `false`               |
| `ingress.nginxInc`                | -- Using ingress controller from NGINX Inc                                                                                                     | `false`               |
| `ingress.annotations`             | -- Ingress annotations configuration                                                                                                           | `{}`                  |
| `ingress.community.annotations`   | -- Ingress annotations configuration for community managed ingress (nginxInc = false)                                                          | `{}`                  |
| `ingress.ingressClassName`        | -- Sets the ingress controller class name to use.                                                                                              | `""`                  |
| `ingress.hosts[0].host`           | hostname                                                                                                                                       | `chart-example.local` |
| `ingress.hosts[0].paths`          | path mapping                                                                                                                                   | `[]`                  |
| `ingress.pathType`                | -- How ingress paths should be treated.                                                                                                        | `Prefix`              |
| `ingress.tls`                     | -- Ingress TLS configuration                                                                                                                   | `[]`                  |


### PMM storage configuration

| Name                       | Description                                                                                                                                                                             | Value         |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- |
| `storage.name`             | name of PVC                                                                                                                                                                             | `pmm-storage` |
| `storage.storageClassName` | optional PMM data Persistent Volume Storage Class                                                                                                                                       | `""`          |
| `storage.size`             | size of storage [depends](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/index.html#set-up-pmm-server) on number of monitored services and data retention | `10Gi`        |
| `storage.dataSource`       | VolumeSnapshot to start from                                                                                                                                                            | `{}`          |
| `storage.selector`         | select existing PersistentVolume                                                                                                                                                        | `{}`          |


### PMM kubernetes configurations

| Name                         | Description                                                                                                         | Value                 |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `nameOverride`               | String to partially override common.names.fullname template with a string (will prepend the release name)           | `""`                  |
| `extraLabels`                | Labels to add to all deployed objects                                                                               | `{}`                  |
| `serviceAccount.create`      | Specifies whether a ServiceAccount should be created                                                                | `true`                |
| `serviceAccount.annotations` | Annotations for service account. Evaluated as a template. Only used if `create` is `true`.                          | `{}`                  |
| `serviceAccount.name`        | Name of the service account to use. If not set and create is true, a name is generated using the fullname template. | `pmm-service-account` |
| `podAnnotations`             | Pod annotations                                                                                                     | `{}`                  |
| `podSecurityContext`         | Configure Pods Security Context                                                                                     | `{}`                  |
| `securityContext`            | Configure Container Security Context                                                                                | `{}`                  |
| `nodeSelector`               | Node labels for pod assignment                                                                                      | `{}`                  |
| `tolerations`                | Tolerations for pod assignment                                                                                      | `[]`                  |
| `affinity`                   | Affinity for pod assignment                                                                                         | `{}`                  |


Specify each parameter using the `--set key=value[,key=value]` or `--set-string key=value[,key=value]` arguments to `helm install`. For example,

```sh
helm install pmm-ha percona/pmm-ha
```

The above command installs PMM HA 3 replicas for PMM Servers

> NOTE: Once this chart is deployed, it is impossible to change the application's access credentials, such as password, using Helm. To change these application credentials after deployment, delete any persistent volumes (PVs) used by the chart and re-deploy it, or use the application's built-in administrative tools if available.

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example:

```sh
helm install pmm-ha -f values.yaml percona/pmm-ha
```

> **Tip**: You can use the default [values.yaml](values.yaml) or get them from chart definition: `helm show values percona/pmm-ha > values.yaml`

## Configuration and installation details

### High Availability Architecture

The PMM HA chart deploys the following components:

1. **PMM Server Cluster**: 3 PMM server replicas with built-in HA clustering
2. **HAProxy Load Balancer**: 3 HAProxy replicas for traffic distribution and failover
3. **ClickHouse Cluster**: 3 ClickHouse replicas with ClickHouse Keeper for coordination
4. **VictoriaMetrics Cluster**: Distributed metrics storage with multiple replicas
5. **PostgreSQL Cluster**: HA PostgreSQL cluster for Grafana metadata storage

All components are configured with pod anti-affinity to ensure distribution across different nodes for maximum resilience.

### [Image tags](https://kubernetes.io/docs/concepts/containers/images/#updating-images)

It is strongly recommended to use immutable tags in a production environment. This ensures your deployment does not change automatically if the same tag is updated with a different image.

Percona will release a new chart updating its containers if a new version of the main container is available, there are any significant changes, or critical vulnerabilities exist.

### PMM admin password

PMM admin password would be set only on the first deployment. That setting is ignored if PMM was already provisioned and just restarted and/or updated. In real-life situations it is recommended to create the `pmm-secret` secret manually before the release and set `secret.create` to false. The chart then won't overwrite secret during install or upgrade and values.yaml won't contain any secret.

If PMM admin password is not set explicitly (default), it will be generated.

To get admin password execute:

```sh
kubectl get secret pmm-secret -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 --decode
```

### Creating PMM Secret Manually

Since `secret.create` is set to `false` by default, you need to create the `pmm-secret` manually before installing the chart. Here are examples of how to create it:

#### Option 1: Create Secret with kubectl

```sh
# Create the pmm-secret with all required credentials
kubectl create secret generic pmm-secret \
  --from-literal=PMM_ADMIN_PASSWORD="your-secure-password" \
  --from-literal=PMM_CLICKHOUSE_USER="clickhouse_pmm" \
  --from-literal=PMM_CLICKHOUSE_PASSWORD="your-clickhouse-password" \
  --from-literal=VMAGENT_remoteWrite_basicAuth_username="victoriametrics_pmm" \
  --from-literal=VMAGENT_remoteWrite_basicAuth_password="your-victoriametrics-password" \
  --from-literal=GF_DATABASE_PASSWORD="your-grafana-db-password" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="your-grafana-admin-password" \
  --namespace=your-namespace
```

#### Option 2: Create Secret from YAML

Create a file named `pmm-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pmm-secret
  namespace: your-namespace
type: Opaque
data:
  PMM_ADMIN_PASSWORD: <base64-encoded-password>
  PMM_CLICKHOUSE_USER: <base64-encoded-username>
  PMM_CLICKHOUSE_PASSWORD: <base64-encoded-password>
  VMAGENT_remoteWrite_basicAuth_username: <base64-encoded-username>
  VMAGENT_remoteWrite_basicAuth_password: <base64-encoded-password>
  GF_DATABASE_PASSWORD: <base64-encoded-password>
  GF_SECURITY_ADMIN_PASSWORD: <base64-encoded-password>
```

Then apply it:

```sh
kubectl apply -f pmm-secret.yaml
```

#### Retrieving Credentials After Deployment

After the PMM HA deployment is complete, you can retrieve the credentials using these commands:

```sh
# Get PMM admin password
kubectl get secret pmm-secret -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 --decode && echo

# Get ClickHouse credentials
kubectl get secret pmm-secret -o jsonpath='{.data.PMM_CLICKHOUSE_USER}' | base64 --decode && echo
kubectl get secret pmm-secret -o jsonpath='{.data.PMM_CLICKHOUSE_PASSWORD}' | base64 --decode && echo

# Get VictoriaMetrics credentials
kubectl get secret pmm-secret -o jsonpath='{.data.VMAGENT_remoteWrite_basicAuth_username}' | base64 --decode && echo
kubectl get secret pmm-secret -o jsonpath='{.data.VMAGENT_remoteWrite_basicAuth_password}' | base64 --decode && echo

# Get Grafana database password
kubectl get secret pmm-secret -o jsonpath='{.data.GF_DATABASE_PASSWORD}' | base64 --decode && echo

# Get Grafana admin password
kubectl get secret pmm-secret -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 --decode && echo
```

### PMM SSL certificates

PMM ships with self signed SSL certificates to provide secure connection between client and server ([check here](https://docs.percona.com/percona-monitoring-and-management/how-to/secure.html#ssl-encryption)).
You could see the warning when connecting to PMM. To further increase security, you could provide your certificates and add values of credentials to the fields of the `cert` section:

```yaml
certs:
  name: pmm-certs
  files:
    certificate.crt: <content>
    certificate.key: <content>
    ca-certs.pem: <content>
    dhparam.pem: <content>
```

### PMM HA Configuration

The PMM HA deployment includes several HA-specific environment variables:

```yaml
pmmEnv:
  PMM_HA_ENABLE: "1"               # Enable HA clustering
  PMM_HA_BOOTSTRAP: "1"            # Bootstrap HA cluster
  PMM_HA_GOSSIP_PORT: "9096"       # Gossip protocol port
  PMM_HA_RAFT_PORT: "9097"         # Raft consensus port
  PMM_HA_GRAFANA_GOSSIP_PORT: "9094"  # Grafana gossip port
  PMM_DISABLE_BUILTIN_CLICKHOUSE: "1"      # Use external ClickHouse
  PMM_DISABLE_BUILTIN_POSTGRES: "1"        # Use external PostgreSQL
  PMM_CLICKHOUSE_IS_CLUSTER: "1"           # Enable ClickHouse clustering
```

### PMM updates

By default UI update feature is disabled and should not be enabled. Do not modify that parameter or add it while modifying the custom `values.yaml` file:

```yaml
pmmEnv:
  PMM_ENABLE_UPDATES: "0"
```

Before updating the helm chart, it is recommended to pre-pull the image on all nodes where PMM replicas are running, as the PMM images could be large and could take time to download.

PMM HA updates should happen in a standard way:

```sh
helm repo update percona
helm upgrade pmm-ha -f values.yaml percona/pmm-ha
```

This will check updates in the repo and upgrade deployment if the updates are available. The rolling update strategy ensures zero-downtime upgrades.

### [PMM environment variables](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/docker.html#environment-variables)

In case you want to add extra environment variables (useful for advanced operations like custom init scripts), you can use the `pmmEnv` property.

```yaml
pmmEnv:
  PMM_ENABLE_UPDATES: "0"
  DATA_RETENTION: "2160h" # 90 days
```

### Scaling and Monitoring

#### Scaling PMM HA

To scale the PMM HA deployment:

```sh
# Scale PMM server replicas
helm upgrade pmm-ha --set replicas=5 percona/pmm-ha

# Scale HAProxy replicas
helm upgrade pmm-ha --set haproxy.replicaCount=5 percona/pmm-ha

# Scale ClickHouse replicas
helm upgrade pmm-ha --set clickhouse.cluster.replicas=5 percona/pmm-ha

# Scale VictoriaMetrics components
helm upgrade pmm-ha \
  --set victoria-metrics-cluster.vmselect.replicaCount=3 \
  --set victoria-metrics-cluster.vminsert.replicaCount=3 \
  --set victoria-metrics-cluster.vmstorage.replicaCount=5 \
  percona/pmm-ha
```

#### Monitoring PMM HA Health

Check the health of your PMM HA deployment:

```sh
# Check PMM server pods
kubectl get pods -l app.kubernetes.io/name=pmm-ha

# Check HAProxy pods
kubectl get pods -l app.kubernetes.io/name=haproxy

# Check ClickHouse cluster status
kubectl get pods -l app.kubernetes.io/name=clickhouse

# Check VictoriaMetrics cluster status
kubectl get pods -l app.kubernetes.io/name=victoria-metrics-cluster

# Check PMM HA cluster status (requires port-forward to PMM UI)
kubectl port-forward svc/monitoring-service 8443:443
# Then visit https://localhost:8443 and check the HA status in the UI
```

#### Troubleshooting HA Issues

Common troubleshooting steps for PMM HA:

1. **Check pod distribution**: Ensure pods are distributed across different nodes
2. **Verify network connectivity**: Check if all HA ports (9096, 9097, 9094) are accessible
3. **Review logs**: Check logs from all PMM server replicas
4. **Validate secrets**: Ensure all required secrets are properly configured
5. **Check storage**: Verify persistent volumes are properly mounted and accessible

# Need help?

**Commercial Support**  | **Community Support** |
:-: | :-: |
| <br/>Enterprise-grade assistance for your mission-critical database deployments in containers and Kubernetes. Get expert guidance for complex tasks like multi-cloud replication, database migration and building platforms.<br/><br/>  | <br/>Connect with our engineers and fellow users for general questions, troubleshooting, and sharing feedback and ideas.<br/><br/>  | 
| **[Get Percona Support](https://hubs.ly/Q02ZTH8Q0)** | **[Visit our Forum](https://forums.percona.com/)** |
