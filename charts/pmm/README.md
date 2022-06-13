# Percona Monitoring and Management (PMM)

**THIS CHART IS A TECHNOLOGICAL PREVIEW**

## Introduction

PMM is an open source database monitoring, observability and management tool.

Check more info here: https://docs.percona.com/percona-monitoring-and-management/index.html

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

To uninstall/delete the `pmm` deployment:

```sh
helm uninstall pmm
```

This command takes a release name and uninstalls the release.

It removes all of the resources associated with the last release of the chart as well as the release history, freeing it up for future use.

## Parameters

| Name                                 | Description                                                                                                                                                                                                                                   | Value                 |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| `image.repository`                   | PMM image repository                                                                                                                                                                                                                          | `percona/pmm-server`  |
| `image.pullPolicy`                   | PMM image pull policy                                                                                                                                                                                                                         | `IfNotPresent`        |
| `image.tag`                          | PMM image tag (immutable tags are recommended)                                                                                                                                                                                                | `2.28.0`              |
| `image.imagePullSecrets`             | Global Docker registry secret names as an array                                                                                                                                                                                               | `[]`                  |
| `pmmEnv.DISABLE_UPDATES`             | Disables a periodic check for new PMM versions as well as ability to apply upgrades using the UI (need to be disabled in k8s environment as updates rolled with helm/container update)                                                        | `1`                   |
| `pmmResources`                       | optional [Resources](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) requested for [PMM container](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/index.html#set-up-pmm-server) | `{}`                  |
| `readyProbeConf.initialDelaySeconds` | Number of seconds after the container has started before readiness probes is initiated                                                                                                                                                        | `1`                   |
| `readyProbeConf.periodSeconds`       | How often (in seconds) to perform the probe                                                                                                                                                                                                   | `5`                   |
| `readyProbeConf.failureThreshold`    | When a probe fails, Kubernetes will try failureThreshold times before giving up                                                                                                                                                               | `6`                   |
| `secret.name`                        | Defines the name of the k8s secret that holds passwords and other secrets                                                                                                                                                                     | `pmm-secret`          |
| `secret.pmm_password`                | Initial PMM password - it changes only on the first deployment, ignored if PMM was already provisioned and just restarted. If PMM admin password is not set, it will be generated.                                                            | `""`                  |
| `certs`                              | Optional certificates, if not provided PMM would use generated self-signed certificates,                                                                                                                                                      | `{}`                  |
| `service.name`                       | Service name that is dns name monitoring services would send data to. `monitoring-service` used by default by pmm-client in Percona operators.                                                                                                | `monitoring-service`  |
| `service.type`                       | Kubernetes Service type                                                                                                                                                                                                                       | `NodePort`            |
| `storage.name`                       | name of PVC                                                                                                                                                                                                                                   | `pmm-storage`         |
| `storage.storageClassName`           | optional PMM data Persistent Volume Storage Class                                                                                                                                                                                             | `""`                  |
| `storage.size`                       | size of storage [depends](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/index.html#set-up-pmm-server) on number of monitored services and data retention                                                       | `10Gi`                |
| `nameOverride`                       | String to partially override common.names.fullname template with a string (will prepend the release name)                                                                                                                                     | `""`                  |
| `extraLabels`                        | Labels to add to all deployed objects                                                                                                                                                                                                         | `{}`                  |
| `serviceAccount.create`              | Specifies whether a ServiceAccount should be created                                                                                                                                                                                          | `true`                |
| `serviceAccount.annotations`         | Annotations for service account. Evaluated as a template. Only used if `create` is `true`.                                                                                                                                                    | `{}`                  |
| `serviceAccount.name`                | Name of the service account to use. If not set and create is true, a name is generated using the fullname template.                                                                                                                           | `pmm-service-account` |
| `podAnnotations`                     | Pod annotations                                                                                                                                                                                                                               | `{}`                  |
| `podSecurityContext`                 | Configure Pods Security Context                                                                                                                                                                                                               | `{}`                  |
| `securityContext`                    | Configure Container Security Context                                                                                                                                                                                                          | `{}`                  |
| `nodeSelector`                       | Node labels for pod assignment                                                                                                                                                                                                                | `{}`                  |
| `tolerations`                        | Tolerations for pod assignment                                                                                                                                                                                                                | `[]`                  |
| `affinity`                           | Affinity for pod assignment                                                                                                                                                                                                                   | `{}`                  |


Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example,

```sh
helm install pmm \
  --set-string pmmEnv.ENABLE_DBAAS="1" \
  --set service.type="NodePort" \
  --set storage.storageClassName="linode-block-storage-retain" \
    percona/pmm
```

The above command enables the PMM DBaaS feature. Additionally, it sets the Service network type to `LoadBalancer` and storage class to `linode-block-storage-retain` for persistence storage on LKE.

> NOTE: Once this chart is deployed, it is not possible to change the application's access credentials, such as password, using Helm. To change these application credentials after deployment, delete any persistent volumes (PVs) used by the chart and re-deploy it, or use the application's built-in administrative tools if available.

Alternatively, a YAML file that specifies the values for the above parameters can be provided while installing the chart. For example:

```sh
helm install pmm -f values.yaml percona/pmm
```

> **Tip**: You can use the default [values.yaml](values.yaml) or get them from chart definition: `helm show values percona/pmm > values.yaml`

## Configuration and installation details

### [Image tags](https://kubernetes.io/docs/concepts/containers/images/#updating-images)

It is strongly recommended to use immutable tags in a production environment. This ensures your deployment does not change automatically if the same tag is updated with a different image.

Percona will release a new chart updating its containers if a new version of the main container, significant changes, or critical vulnerabilities exist.

### PMM admin password

PMM admin password would be set only on the first deployment. That setting is ignored if PMM was already provisioned and just restarted and/or updated.

If PMM admin password is not set explicitly (default), it will be generated.

To get admin password execute:

```sh
kubectl get secret pmm-secret -o jsonpath='{.data.PMM_ADMIN_PASSWORD}' | base64 --decode
```

### PMM SSL certificates

PMM ships with self signed SSL certificates to provide secure connection between client and server ([check here](https://docs.percona.com/percona-monitoring-and-management/how-to/secure.html#ssl-encryption)).
You could see the warning when connecting to PMM. To further harden security you could provide your own certificates, add values of certificates and secrets to the fields of the `cert` section:

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

By default UI update feature is disabled abd should stay that way, please don't modify that parameter or/and add it if modifying custom `values.yaml` file:

```yaml
pmmEnv:
  DISABLE_UPDATES: "1"
```

Before update it is recommended to pre-pull image on the node where PMM is running as PMM images could be large and could take some time to download.

PMM updates should happen in a standard way:

```sh
helm upgrade pmm -f values.yaml percona/pmm
```

### [PMM environment variables](https://docs.percona.com/percona-monitoring-and-management/setting-up/server/docker.html#environment-variables)

In case you want to add extra environment variables (useful for advanced operations like custom init scripts), you can use the `pmmEnv` property.

```yaml
pmmEnv:
  DISABLE_UPDATES: "1"
  ENABLE_DBAAS: "1"
```
