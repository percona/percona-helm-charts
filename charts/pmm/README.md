# Percona Monitoring and Management (PMM)

## Introduction

PMM is an open source database monitoring, observability and management tool.

Check more info here: https://docs.percona.com/percona-monitoring-and-management/3/

## Prerequisites

- Kubernetes 1.22+
- Helm 3.2.0+
- PV provisioner support in the underlying infrastructure

## Installing the Chart

To install the chart with the release name `pmm`:

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install pmm percona/pmm
```

The command deploys PMM on the Kubernetes cluster in the default configuration. The [Parameters](#parameters) section lists the parameters that can be configured during installation.

> **Tip**: List all releases using `helm list`

## Uninstalling the Chart

To uninstall `pmm` deployment:

```sh
helm uninstall pmm
```

This command takes a release name and uninstalls the release.

It removes all of the resources associated with the last release of the chart as well as the release history.

## Parameters

### Percona Monitoring and Management (PMM) parameters

| Name                                 | Description                                                                                                                                                                                                                                   | Value                |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |----------------------|
| `image.repository`                   | PMM image repository                                                                                                                                                                                                                          | `percona/pmm-server` |
| `image.pullPolicy`                   | PMM image pull policy                                                                                                                                                                                                                         | `IfNotPresent`       |
| `image.tag`                          | PMM image tag (immutable tags are recommended)                                                                                                                                                                                                | `3.5.0`             |
| `image.imagePullSecrets`             | Global Docker registry secret names as an array                                                                                                                                                                                               | `[]`                 |
| `pmmEnv.PMM_ENABLE_UPDATES`          | Enables a periodic check for new PMM versions as well as the ability to apply upgrades using the UI (needs to be disabled in k8s environment as updates are rolled out with 'helm update')                                                        | `1`                  |
| `pmmResources`                       | optional [Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) requested for [PMM container](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/index.html#set-up-pmm-server) | `{}`                 |
| `readyProbeConf.initialDelaySeconds` | Number of seconds after the container has started before readiness probes is initiated                                                                                                                                                        | `1`                  |
| `readyProbeConf.periodSeconds`       | How often (in seconds) to perform the probe                                                                                                                                                                                                   | `5`                  |
| `readyProbeConf.failureThreshold`    | When a probe fails, Kubernetes will try failureThreshold times before giving up                                                                                                                                                               | `6`                  |


### PMM secrets

| Name                  | Description                                                                                                                                                                        | Value        |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `secret.name`         | Defines the name of the k8s secret that holds passwords and other secrets                                                                                                          | `pmm-secret` |
| `secret.annotations`  | Defines the annotations of the k8s secret that holds passwords and other secrets                                                                                                   | `{}`         |
| `secret.create`       | If true then secret will be generated by Helm chart. Otherwise it is expected to be created by user and all of its keys will be mounted as env vars.                                                                               | `true`       |
| `secret.pmm_password` | Initial PMM password - it changes only on the first deployment, ignored if PMM was already provisioned and just restarted. If PMM admin password is not set, it will be generated. | `""`         |
| `certs`               | Optional certificates, if not provided PMM would use generated self-signed certificates,                                                                                           | `{}`         |


### External Secrets Integration

| Name                                              | Description                                                                                                                                    | Value          |
| ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | -------------- |
| `externalSecrets.enabled`                         | Enable External Secrets Operator integration                                                                                                  | `false`        |
| `externalSecrets.oauth.enabled`                   | Enable ExternalSecret for OAuth credentials                                                                                                   | `false`        |
| `externalSecrets.oauth.name`                      | Name of the ExternalSecret resource (defaults to `<fullname>-oauth-external-secret`)                                                          | `""`           |
| `externalSecrets.oauth.secretStoreRef.name`       | Name of the SecretStore/ClusterSecretStore (e.g., "vault-backend", "aws-secretsmanager")                                                      | `""`           |
| `externalSecrets.oauth.secretStoreRef.kind`       | Kind of secret store: "SecretStore" (namespace-scoped) or "ClusterSecretStore" (cluster-wide)                                                 | `SecretStore`  |
| `externalSecrets.oauth.refreshInterval`           | How often to sync secrets from backend (e.g., "5m", "1h")                                                                                     | `5m`           |
| `externalSecrets.oauth.targetSecretName`          | Target Kubernetes Secret name (defaults to `<fullname>-oauth`)                                                                                | `""`           |
| `externalSecrets.oauth.data`                      | Remote secret configuration mapping Kubernetes secret keys to remote secret paths                                                             | `[]`           |
| `externalSecrets.oauth.annotations`               | Additional annotations for the ExternalSecret resource                                                                                        | `{}`           |
| `externalSecrets.oauth.labels`                    | Additional labels for the ExternalSecret resource                                                                                             | `{}`           |


### PMM network configuration

| Name                              | Description                                                                                                                                    | Value                 |
| --------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `service.name`                    | Service name that is dns name monitoring services would send data to. `monitoring-service` used by default by pmm-client in Percona operators. | `monitoring-service`  |
| `service.type`                    | Kubernetes Service type                                                                                                                        | `NodePort`            |
| `service.ports[0].port`           | https port number                                                                                                                              | `443`                 |
| `service.ports[0].targetPort`     | target port to map for statefulset and ingress                                                                                                 | `https`               |
| `service.ports[0].protocol`       | protocol for https                                                                                                                             | `TCP`                 |
| `service.ports[0].name`           | port name                                                                                                                                      | `https`               |
| `service.ports[1].port`           | http port number                                                                                                                               | `80`                  |
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
helm install pmm \
  --set service.type="NodePort" \
  --set storage.storageClassName="linode-block-storage-retain" \
    percona/pmm
```

The above command installs PMM with the Service network type set to `NodePort` and storage class to `linode-block-storage-retain` for persistence storage on LKE.

> NOTE: Once this chart is deployed, it is impossible to change the application's access credentials, such as password, using Helm. To change these application credentials after deployment, delete any persistent volumes (PVs) used by the chart and re-deploy it, or use the application's built-in administrative tools if available.

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example:

```sh
helm install pmm -f values.yaml percona/pmm
```

> **Tip**: You can use the default [values.yaml](values.yaml) or get them from chart definition: `helm show values percona/pmm > values.yaml`

## Configuration and installation details

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

### PMM updates

By default UI update feature is disabled and should not be enabled. Do not modify that parameter or add it while modifying the custom `values.yaml` file:

```yaml
pmmEnv:
  PMM_ENABLE_UPDATES: "0"
```

Before updating the helm chart,  it is recommended to pre-pull the image on the node where PMM is running, as the PMM images could be large and could take time to download

PMM updates should happen in a standard way:

```sh
helm repo update percona
helm upgrade pmm -f values.yaml percona/pmm
```

This will check updates in the repo and upgrade deployment if the updates are available.

### [PMM environment variables](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/docker.html#environment-variables)

In case you want to add extra environment variables (useful for advanced operations like custom init scripts), you can use the `pmmEnv` property.

```yaml
pmmEnv:
  PMM_ENABLE_UPDATES: "0"
  PMM_DATA_RETENTION: "2160h" # 90 days
```

### External Secrets Integration for OAuth

PMM supports integration with [External Secrets Operator](https://external-secrets.io/) to fetch OAuth credentials from external secret management systems like HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, or GCP Secret Manager. This provides a secure way to inject credentials without storing them in values files.

#### Prerequisites

1. Install [External Secrets Operator](https://external-secrets.io/latest/introduction/getting-started/) in your cluster
2. Create a SecretStore or ClusterSecretStore resource pointing to your secret backend
3. Store your OAuth credentials in your secret backend

#### Example: Using Vault with Okta

```yaml
externalSecrets:
  enabled: true
  oauth:
    enabled: true
    secretStoreRef:
      name: vault-backend
      kind: SecretStore
    refreshInterval: "5m"
    data:
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
        remoteRef:
          key: "secret/data/prod/pmm/okta"
          property: "client_id"
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
        remoteRef:
          key: "secret/data/prod/pmm/okta"
          property: "client_secret"

pmmEnv:
  GF_AUTH_GENERIC_OAUTH_ENABLED: 'true'
  GF_AUTH_GENERIC_OAUTH_SCOPES: 'openid profile email groups'
  GF_AUTH_GENERIC_OAUTH_AUTH_URL: 'https://dev-123456.okta.com/oauth2/v1/authorize'
  GF_AUTH_GENERIC_OAUTH_TOKEN_URL: 'https://dev-123456.okta.com/oauth2/v1/token'
  GF_AUTH_GENERIC_OAUTH_API_URL: 'https://dev-123456.okta.com/oauth2/v1/userinfo'
  GF_AUTH_GENERIC_OAUTH_ALLOWED_DOMAINS: 'example.com'
```

#### Example: Using AWS Secrets Manager

```yaml
externalSecrets:
  enabled: true
  oauth:
    enabled: true
    secretStoreRef:
      name: aws-secretsmanager
      kind: ClusterSecretStore
    refreshInterval: "1h"
    data:
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
        remoteRef:
          key: "prod/pmm/oauth-credentials"
          property: "client_id"
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
        remoteRef:
          key: "prod/pmm/oauth-credentials"
          property: "client_secret"

pmmEnv:
  GF_AUTH_GENERIC_OAUTH_ENABLED: 'true'
  # ... other OAuth configuration
```

#### Example: Using Azure Key Vault

```yaml
externalSecrets:
  enabled: true
  oauth:
    enabled: true
    secretStoreRef:
      name: azure-keyvault
      kind: SecretStore
    data:
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_ID"
        remoteRef:
          key: "pmm-oauth-client-id"
      - secretKey: "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"
        remoteRef:
          key: "pmm-oauth-client-secret"

pmmEnv:
  GF_AUTH_GENERIC_OAUTH_ENABLED: 'true'
  # ... other OAuth configuration
```

> **Note**: When using External Secrets, the OAuth credentials are automatically synced from your secret backend and injected as environment variables into the PMM container. The sync interval is controlled by `externalSecrets.oauth.refreshInterval`.

# Need help?

**Commercial Support**  | **Community Support** |
:-: | :-: |
| <br/>Enterprise-grade assistance for your mission-critical database deployments in containers and Kubernetes. Get expert guidance for complex tasks like multi-cloud replication, database migration and building platforms.<br/><br/>  | <br/>Connect with our engineers and fellow users for general questions, troubleshooting, and sharing feedback and ideas.<br/><br/>  | 
| **[Get Percona Support](https://hubs.ly/Q02ZTH8Q0)** | **[Visit our Forum](https://forums.percona.com/)** |
