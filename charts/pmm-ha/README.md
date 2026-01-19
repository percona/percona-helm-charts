# Percona Monitoring and Management (PMM) High Availability

## Introduction

PMM HA is a high availability deployment of Percona Monitoring and Management (PMM), an open source database monitoring, observability and management tool. This chart provides a production-ready, scalable, and fault-tolerant PMM deployment with multiple replicas, load balancing, and operator-managed database backends.

**Important**: This chart works together with the `pmm-ha-dependencies` chart, which must be installed first to deploy the required Kubernetes operators.

Check more info here: https://docs.percona.com/percona-monitoring-and-management/index.html

## Architecture

PMM HA uses a **two-chart architecture**:

1. **pmm-ha-dependencies**: Installs Kubernetes operators (VictoriaMetrics, ClickHouse, PostgreSQL)
2. **pmm-ha** (this chart): Deploys PMM servers and creates operator-managed database resources

## High Availability Features

This PMM HA deployment provides the following high availability features:

- **Multiple PMM Server Replicas**: Deploy 3 PMM server instances for redundancy
- **HAProxy Load Balancing**: 3 HAProxy replicas with anti-affinity for traffic distribution
- **Operator-Managed ClickHouse Cluster**: Dedicated ClickHouse cluster with 3 replicas and ClickHouse Keeper (managed by Altinity ClickHouse Operator)
- **Operator-Managed VictoriaMetrics Cluster**: Distributed metrics storage with multiple replicas (managed by VictoriaMetrics Operator)
- **Operator-Managed PostgreSQL Cluster**: HA PostgreSQL cluster for Grafana metadata (managed by Percona PostgreSQL Operator)
- **Pod Anti-Affinity**: Ensures components are distributed across different nodes
- **Health Checks**: Comprehensive readiness and liveness probes
- **TLS/SSL Support**: Secure communication with configurable certificates

## Prerequisites

- Kubernetes 1.22+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure
- **Required Kubernetes Operators** (must be installed BEFORE this chart):
  - Install via `pmm-ha-dependencies` chart (recommended), OR
  - Install manually (advanced):
    - VictoriaMetrics Operator (v0.56.4+)
    - Altinity ClickHouse Operator (v0.25.4+)
    - Percona PostgreSQL Operator (v2.8.0+)

## Installing the Chart

PMM HA requires three Kubernetes operators to be installed before deployment. You can install them either:
- **Option A**: Using the `pmm-ha-dependencies` chart (recommended, simpler)
- **Option B**: Installing operators manually (advanced, more control)

### Option A: Install Using pmm-ha-dependencies Chart (Recommended)

#### Step 1: Install Operators

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update

# Install the operators
helm install pmm-operators percona/pmm-ha-dependencies --namespace pmm --create-namespace

# Wait for operators to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-metrics-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=altinity-clickhouse-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=pg-operator -n pmm --timeout=300s
```

#### Step 2: Install PMM HA

Once all operators are ready, install the chart:

```sh
# Install PMM HA
helm install pmm-ha percona/pmm-ha --namespace pmm
```

### Option B: Install Operators Manually (Advanced)

If you prefer to manage operators independently or need custom configurations:

#### Step 1: Install VictoriaMetrics Operator

```sh
helm repo add vm https://victoriametrics.github.io/helm-charts/
helm repo update

helm install victoria-metrics-operator vm/victoria-metrics-operator \
  --namespace pmm \
  --create-namespace \
  --set admissionWebhooks.enabled=true
```

#### Step 2: Install Altinity ClickHouse Operator

```sh
helm repo add altinity https://helm.altinity.com
helm repo update

helm install clickhouse-operator altinity/altinity-clickhouse-operator \
  --namespace pmm
```

#### Step 3: Install Percona PostgreSQL Operator

```sh
helm install postgres-operator percona/pg-operator \
  --namespace pmm
```

#### Step 4: Verify All Operators Are Ready

```sh
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=victoria-metrics-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=altinity-clickhouse-operator -n pmm --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=pg-operator -n pmm --timeout=300s
```

#### Step 5: Install PMM HA

```sh
helm install pmm-ha percona/pmm-ha --namespace pmm
```

The command deploys PMM HA on the Kubernetes cluster with the default high availability configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm list`

> **Important**: For production deployments, you must create the `pmm-secret` manually before installation since `secret.create` is set to `false` by default. See the [Creating PMM Secret Manually](#creating-pmm-secret-manually) section for detailed examples.

## Uninstalling the Chart

**IMPORTANT**: You must uninstall PMM HA first, then the operators. Uninstalling in the wrong order may leave orphaned resources.

### Step 1: Uninstall PMM HA

```sh
helm uninstall pmm-ha --namespace pmm
```

### Step 2: Wait for Resources to be Cleaned Up (Optional but Recommended)

Wait for operator-managed resources to be fully removed:

```sh
# Wait for VictoriaMetrics resources to be removed
kubectl wait --for=delete vmcluster -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s

# Wait for PostgreSQL resources to be removed
kubectl wait --for=delete postgrescluster -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s

# Wait for ClickHouse resources to be removed
kubectl wait --for=delete clickhouseinstallation -l app.kubernetes.io/instance=pmm-ha -n pmm --timeout=300s
```

### Step 3: Uninstall Operators

Choose the appropriate method based on how you installed the operators:

#### If Using pmm-ha-dependencies Chart:

```sh
helm uninstall pmm-operators --namespace pmm
```

#### If Installed Operators Manually:

```sh
helm uninstall victoria-metrics-operator --namespace pmm
helm uninstall clickhouse-operator --namespace pmm
helm uninstall postgres-operator --namespace pmm
```

### Step 4: Clean Up CRDs (Optional)

**WARNING**: This will remove CRDs cluster-wide and delete ALL custom resources of these types in ALL namespaces! This action will cause permanent data loss.

Only do this if you're completely removing the operators and have no other deployments using them:

```sh
# Remove VictoriaMetrics CRDs
kubectl delete crds $(kubectl get crds -o name | grep victoriametrics)

# Remove ClickHouse CRDs
kubectl delete crds $(kubectl get crds -o name | grep clickhouse)

# Remove PostgreSQL Operator CRDs
kubectl delete crds $(kubectl get crds -o name | grep -E "(postgres-operator|perconapg)")
```

> **Warning**: This will remove all PMM data, including metrics, dashboards, and configuration. Make sure to backup any important data before uninstalling.

## Connecting Clients to PMM

### Service Endpoints

PMM HA provides the following service endpoints for clients to connect:

| Service | Description | Port |
|---------|-------------|------|
| `pmm-ha-haproxy` | **Recommended** - HAProxy load balancer that routes to the active PMM leader | 443 (HTTPS) |
| `monitoring-service` | Headless service for direct PMM pod access (used internally) | 8443 (HTTPS) |

**For all external clients and Percona Operators, use `pmm-ha-haproxy` as the PMM server endpoint.**

### Connecting PMM Clients

To connect a PMM client to the HA cluster:

```sh
# From within the Kubernetes cluster
pmm-admin config --server-url=https://admin:<password>@pmm-ha-haproxy:443 --server-insecure-tls

# Or using the service token (recommended for automation)
pmm-admin config --server-url=https://service_token:<token>@pmm-ha-haproxy:443 --server-insecure-tls
```

### PostgreSQL Monitoring (Automatic)

When `pg-db.pmm.enabled: true` (default), PostgreSQL metrics are automatically pushed to PMM:

1. A **service account token** is automatically created in PMM by the `pmm-token-init` Job
2. The token is stored in the `pg-pmm-secret` Kubernetes secret
3. PostgreSQL pods use this token to authenticate and push metrics to PMM via the `pmm-ha-haproxy` endpoint

No manual configuration is required - the Percona PostgreSQL Operator handles the integration automatically.

### Using Service Tokens for Automation

Service tokens are recommended for automated deployments and CI/CD pipelines. To retrieve the auto-generated PostgreSQL monitoring token:

```sh
kubectl get secret pg-pmm-secret -n <namespace> -o jsonpath='{.data.PMM_SERVER_TOKEN}' | base64 -d
```

To create additional service tokens manually, see the [PMM documentation on service accounts](https://docs.percona.com/percona-monitoring-and-management/api/authentication.html).

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


### HAProxy external access configuration

| Name                          | Description                                                                                                     | Value       |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------- | ----------- |
| `haproxy.service.type`        | Service type for HAProxy: ClusterIP (internal), LoadBalancer (external via LB), or NodePort (external via node) | `ClusterIP` |
| `haproxy.service.annotations` | Service annotations (add cloud-specific annotations as needed)                                                   | `{}`        |


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
helm install pmm-ha --namespace pmm percona/pmm-ha
```

The above command installs PMM HA with 3 replicas for PMM Servers (default configuration).

> NOTE: Once this chart is deployed, it is impossible to change the application's access credentials, such as password, using Helm. To change these application credentials after deployment, delete any persistent volumes (PVs) used by the chart and re-deploy it, or use the application's built-in administrative tools if available.

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example:

```sh
helm install pmm-ha -f values.yaml --namespace pmm percona/pmm-ha
```

> **Tip**: You can use the default [values.yaml](values.yaml) or get them from chart definition: `helm show values percona/pmm-ha > values.yaml`

## Configuration and installation details

### High Availability Architecture

The PMM HA chart deploys the following components:

1. **PMM Server Cluster**: 3 PMM server replicas with built-in HA clustering
2. **HAProxy Load Balancer**: 3 HAProxy replicas for traffic distribution and failover
3. **ClickHouse Cluster**: 3 ClickHouse replicas with ClickHouse Keeper for coordination (managed by Altinity ClickHouse Operator)
4. **VictoriaMetrics Cluster**: Distributed metrics storage with multiple replicas (managed by VictoriaMetrics Operator)
5. **PostgreSQL Cluster**: HA PostgreSQL cluster for Grafana metadata storage (managed by Percona PostgreSQL Operator)

All components are configured with pod anti-affinity to ensure distribution across different nodes for maximum resilience.

> **Important**: The three Kubernetes operators (VictoriaMetrics, ClickHouse, PostgreSQL) must be installed before deploying PMM HA. They manage the lifecycle of their respective resources through Custom Resource Definitions (CRDs).

### [Image tags](https://kubernetes.io/docs/concepts/containers/images/#updating-images)

It is strongly recommended to use immutable tags in a production environment. This ensures your deployment does not change automatically if the same tag is updated with a different image.

Percona will release a new chart updating its containers if a new version of the main container is available, there are any significant changes, or critical vulnerabilities exist.

### PMM admin password

PMM admin password would be set only on the first deployment. That setting is ignored if PMM was already provisioned and just restarted and/or updated. In real-life situations it is recommended to create the `pmm-secret` secret manually before the release and set `secret.create` to false. The chart then won't overwrite secret during install or upgrade and values.yaml won't contain any secret.

If PMM admin password is not set explicitly (default), it will be generated.

To get admin password execute:

```sh
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 --decode && echo
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
  --from-literal=PG_PASSWORD="your-pmm-postgres-password" \
  --from-literal=GF_PASSWORD="your-grafana-postgres-password" \
  --namespace pmm
```

#### Option 2: Create Secret from YAML

Create a file named `pmm-secret.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pmm-secret
  namespace: pmm
type: Opaque
stringData:
  PMM_ADMIN_PASSWORD: "your-secure-password"
  PMM_CLICKHOUSE_USER: "clickhouse_pmm"
  PMM_CLICKHOUSE_PASSWORD: "your-clickhouse-password"
  VMAGENT_remoteWrite_basicAuth_username: "victoriametrics_pmm"
  VMAGENT_remoteWrite_basicAuth_password: "your-victoriametrics-password"
  PG_PASSWORD: "your-pmm-postgres-password"
  GF_PASSWORD: "your-grafana-postgres-password"
```

Then apply it:

```sh
kubectl apply -f pmm-secret.yaml
```

> **Note**: Using `stringData` instead of `data` allows you to provide plain text values, which Kubernetes will automatically base64-encode.

#### Retrieving Credentials After Deployment

After the PMM HA deployment is complete, you can retrieve the credentials using these commands:

```sh
# Get PMM admin password
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 --decode && echo

# Get ClickHouse credentials
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PMM_CLICKHOUSE_USER}' | base64 --decode && echo
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PMM_CLICKHOUSE_PASSWORD}' | base64 --decode && echo

# Get VictoriaMetrics credentials
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.VMAGENT_remoteWrite_basicAuth_username}' | base64 --decode && echo
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.VMAGENT_remoteWrite_basicAuth_password}' | base64 --decode && echo

# Get PostgreSQL passwords
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.PG_PASSWORD}' | base64 --decode && echo
kubectl get secret pmm-secret -n pmm -o jsonpath='{.data.GF_PASSWORD}' | base64 --decode && echo
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
helm upgrade pmm-ha -f values.yaml --namespace pmm percona/pmm-ha
```

This will check updates in the repo and upgrade deployment if the updates are available. The rolling update strategy ensures zero-downtime upgrades.

### [PMM environment variables](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/docker.html#environment-variables)

In case you want to add extra environment variables (useful for advanced operations like custom init scripts), you can use the `pmmEnv` property.

```yaml
pmmEnv:
  PMM_ENABLE_UPDATES: "0"
  PMM_DATA_RETENTION: "2160h" # 90 days
```

### Kubernetes cluster metrics

By default, this chart deploys `kube-state-metrics` and `node-exporter`, and the built-in VMAgent scrapes:

- kube-state-metrics (object state)
- node-exporter (node CPU/memory/disk/network)
- kubelet and cAdvisor (pod/container usage)
- Kubernetes apiserver

To disable exporters:

```yaml
kube-state-metrics:
  enabled: false

prometheus-node-exporter:
  enabled: false
```

**Note on label cardinality**: Container metrics from cAdvisor may have many labels (especially in EKS/GKE with cloud provider labels). The default VMInsert limit is 50 labels per timeseries. If you see "ignoring series... increase -maxLabelsPerTimeseries" warnings, increase the limit:

```yaml
victoriaMetrics:
  vminsert:
    extraArgs:
      maxLabelsPerTimeseries: "60"
```

### External access to PMM HA

By default, HAProxy is only accessible within the cluster. To enable external access from outside the cluster, configure the HAProxy service type.

#### Using LoadBalancer (Recommended for cloud environments)

This automatically provisions a cloud load balancer with a public IP/DNS:

```yaml
haproxy:
  service:
    type: LoadBalancer
```

After deployment, get the external endpoint:

```sh
kubectl get svc -n pmm -l app.kubernetes.io/name=haproxy
```

The `EXTERNAL-IP` column shows the public access point. Connect via `https://<EXTERNAL-IP>:443`.

#### Using NodePort (For bare-metal or when LoadBalancer is unavailable)

```yaml
haproxy:
  service:
    type: NodePort
```

Access PMM via `https://<any-node-ip>:<nodeport>`. Get the assigned NodePort:

```sh
kubectl get svc -n pmm -l app.kubernetes.io/name=haproxy -o jsonpath='{.items[0].spec.ports[0].nodePort}'
```

#### Cloud-specific configurations

Configure LoadBalancer settings for your cloud provider:

##### AWS (EKS)

```yaml
haproxy:
  service:
    type: LoadBalancer
    annotations:
      # Use Network Load Balancer (recommended)
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      # Internal (VPC only) - use "internet-facing" for public access
      service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
      # Optional: Use Elastic IPs for stable IPs (one per AZ, internet-facing only)
      # service.beta.kubernetes.io/aws-load-balancer-eip-allocations: "eipalloc-xxx,eipalloc-yyy"
```

##### Google Cloud (GKE)

```yaml
haproxy:
  service:
    type: LoadBalancer
    # Optional: Use a reserved static IP (created via: gcloud compute addresses create pmm-ip --region=REGION)
    # loadBalancerIP: "35.x.x.x"
    annotations:
      # Internal LB (VPC only) - remove for external/public access
      networking.gke.io/load-balancer-type: "Internal"
```

##### Azure (AKS)

```yaml
haproxy:
  service:
    type: LoadBalancer
    # Optional: Use a pre-created static public IP
    # loadBalancerIP: "20.x.x.x"
    annotations:
      # Internal LB (VNet only) - remove for external/public access
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
```

##### On-Premise / Bare Metal (MetalLB)

```yaml
haproxy:
  service:
    type: LoadBalancer
    loadBalancerIP: "192.168.1.100"
    annotations:
      metallb.universe.tf/address-pool: "production-pool"
```

#### Static IP summary

| Provider | Static IP Method |
|----------|------------------|
| AWS | Elastic IPs via `aws-load-balancer-eip-allocations` annotation |
| GCP | Reserved IP via `spec.loadBalancerIP` |
| Azure | Static Public IP via `spec.loadBalancerIP` |
| MetalLB | IP from pool via `spec.loadBalancerIP` |
### Scaling and Monitoring

#### Scaling PMM HA

To scale the PMM HA deployment:

```sh
# Scale PMM server replicas
helm upgrade pmm-ha --set replicas=5 --namespace pmm percona/pmm-ha

# Scale HAProxy replicas
helm upgrade pmm-ha --set haproxy.replicaCount=5 --namespace pmm percona/pmm-ha

# Scale ClickHouse replicas
helm upgrade pmm-ha --set clickhouse.cluster.replicas=5 --namespace pmm percona/pmm-ha

# Scale VictoriaMetrics components
helm upgrade pmm-ha \
  --set victoriaMetrics.vmselect.replicaCount=3 \
  --set victoriaMetrics.vminsert.replicaCount=3 \
  --set victoriaMetrics.vmstorage.replicaCount=5 \
  --namespace pmm \
  percona/pmm-ha
```

#### Monitoring PMM HA Health

Check the health of your PMM HA deployment:

```sh
# Check PMM server pods
kubectl get pods -l app.kubernetes.io/name=pmm -n pmm

# Check HAProxy pods
kubectl get pods -l app.kubernetes.io/name=haproxy -n pmm

# Check ClickHouse cluster pods
kubectl get pods -l clickhouse.altinity.com/app=chop -n pmm

# Check VictoriaMetrics cluster resources
kubectl get vmcluster,vmagent,vmauth -n pmm

# Check PostgreSQL cluster pods
kubectl get postgrescluster -n pmm

# Check all PMM-related resources
kubectl get all -l app.kubernetes.io/instance=pmm-ha -n pmm

# Port-forward PMM UI to the host
kubectl port-forward -n pmm svc/monitoring-service 8443:8443
# Then visit https://localhost:8443 to log in to PMM
```

#### Troubleshooting HA Issues

Common troubleshooting steps for PMM HA:

1. **Check pod distribution**: Ensure pods are distributed across different nodes
2. **Verify network connectivity**: Check if all HA ports (9096, 9097, 9094) are accessible
3. **Review logs**: Check logs from all PMM server replicas
4. **Validate secrets**: Ensure all required secrets are properly configured
5. **Check storage**: Verify persistent volumes are properly mounted and accessible

## Known Limitations

### Scaling Down to Single Replica

When scaling down to a single PMM replica, ensure the **Raft leader is on pmm-0** before scaling. Kubernetes StatefulSets remove pods in reverse ordinal order (highest first), so:

- Scaling from 3→1 removes pmm-2 and pmm-1, keeping only pmm-0
- If the Raft leader is on pmm-1 or pmm-2 when you scale down, **PMM will become unreachable**

Only after confirming pmm-0 is the leader, scale down:
   ```sh
   helm upgrade <release-name> percona/pmm-ha --namespace <namespace> --set replicas=1
   ```

# Need help?

**Commercial Support**  | **Community Support** |
:-: | :-: |
| <br/>Enterprise-grade assistance for your mission-critical database deployments in containers and Kubernetes. Get expert guidance for complex tasks like multi-cloud replication, database migration and building platforms.<br/><br/>  | <br/>Connect with our engineers and fellow users for general questions, troubleshooting, and sharing feedback and ideas.<br/><br/>  | 
| **[Get Percona Support](https://hubs.ly/Q02ZTH8Q0)** | **[Visit our Forum](https://forums.percona.com/)** |
