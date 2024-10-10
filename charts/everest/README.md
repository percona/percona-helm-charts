# Percona Everest

This helm chart deploys Percona Everest.

Useful links:
- [Percona Everest Documentation](https://docs.percona.com/everest/index.html)
- [Percona Everest GitHub](https://github.com/percona/everest)

## Usage

### Deploy Percona Everest

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install everest-core percona/everest --namespace everest-system --create-namespace
```

> Note: we currently do not support deploying Everest in a namespace other than `everest-system`.

This command may take a few minutes to complete. Once done, you can retrieve the admin credentials using the following command:

```sh
kubectl get secret everest-accounts -n everest-system -o jsonpath='{.data.users\.yaml}' | base64 --decode  | yq '.admin.passwordHash'
```

### Deploy your database namespace components

Once Everest is running, we need to create a namespace for your databases and provision the necessary operators.

```sh
cat <<EOF | kubectl create -f -
apiVersion: v1
kind: Namespace
metadata:
  name: everest
  labels:
    app.kubernetes.io/managed-by: everest
EOF
helm install everest percona/everest-db-namespace --namespace everest
```

## Configuration

The following table shows the configurable parameters of the Percona Everest chart and their default values.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| everest-db-namespace.enabled | bool | `false` | Do not enable. |
| monitoring.enabled | bool | `true` | Enable monitoring for Everest. |
| monitoring.namespace | string | `"everest-monitoring"` | Namespace where monitoring is installed. Do no change unless you know what you are doing. |
| namespaceOverride | string | `""` | Namespace override. Defaults to the value of .Release.Namespace. |
| olm.catalogSourceImage | string | `"perconalab/everest-catalog"` | Image to use for Everest CatalogSource. |
| olm.enabled | bool | `true` | Enable OLM for Everest. |
| olm.image | string | `"quay.io/operator-framework/olm@sha256:1b6002156f568d722c29138575733591037c24b4bfabc67946f268ce4752c3e6"` | Image to use for the OLM components. |
| olm.namespace | string | `"everest-olm"` | Namespace where OLM is installed. Do no change unless you know what you are doing. |
| olm.packageserver.tls.caCert | string | `""` | CA certificate for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.tlsCert | string | `""` | Client certificate for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.tlsKey | string | `""` | Client key for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.type | string | `"helm"` | Type of TLS certificates. Supported values are "helm" and "cert-manager". For production setup, it is recommended to use "cert-manager". |
| operator.enableLeaderElection | bool | `true` | Enable leader election for the operator. |
| operator.healthProbeAddr | string | `":8081"` | Health probe address for the operator. |
| operator.image | string | `"perconalab/everest-operator"` | Image to use for the Everest operator container. |
| operator.metricsAddr | string | `"127.0.0.1:8080"` | Metrics address for the operator. |
| operator.resources | object | `{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"5m","memory":"64Mi"}}` | Resources to allocate for the operator container. |
| server.image | string | `"perconalab/everest"` | Image to use for the server container. |
| server.rbac | string | `"g, admin, role:admin\n"` | RBAC policy for Everest. |
| server.resources | object | `{"limits":{"cpu":"200m","memory":"500Mi"},"requests":{"cpu":"100m","memory":"20Mi"}}` | Resources to allocate for the server container. |
| telemetry | bool | `true` | If set, enabled sending telemetry information. |
