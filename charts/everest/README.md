# Percona Everest

This helm chart deploys Percona Everest.

Useful links:
- [Percona Everest Documentation](https://docs.percona.com/everest/index.html)
- [Percona Everest GitHub](https://github.com/percona/everest)

> :warning: Note: This chart is currently in technical preview.
Future releases could potentially introduce breaking changes, and we cannot promise a migration path. We do not recommend using this in production environment,
but if you do so, please be aware of the risks.

## Usage

### 1. Add the Percona Helm repository

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
```

### 2. Install Everest
```sh
helm install everest-core percona/everest \
    --namespace everest-system \
    --create-namespace
```

Notes:
* This command deploys the Everest components in the `everest-system` namespace. Currently, we do not support specifying a different namespace for Everest.
* Additionally, it also deploys a new namespace called `everest` for your databases and the database operators.
* If you prefer to manage your database namespace separately, you may set `dbNamespace.enabled=false`.
* You may override the name of the database namespace using the `dbNamespace.namespaceOverride` parameter.
* By default, all database operators are installed in your database namespace. You may override this by specifying one or more of the following: [`dbNamespace.pxc=false`, `dbNamespace.pg=false`, `dbNamespace.psmdb=false`].
* We currently do not support installation without the use of chart hooks. I.e, the use of `--no-hooks` is not supported during installation.

### 3. Retrieve the admin password

Once the installation is complete, you may retrieve the admin credentials using the following command:
```sh
kubectl get secret everest-accounts -n everest-system -o jsonpath='{.data.users\.yaml}' | base64 --decode  | yq '.admin.passwordHash'
```

You may open the Everest UI by port-forwarding the service to your local machine:

```sh
kubectl port-forward svc/everest -n everest-system 8080:8080
```

Notes:
* The default username to login to the Everest UI is `admin`.
* You may specify a different default admin password using `server.initialAdminPassword` parameter during installation.
* The default admin password is stored in plain text. It is highly recommended to update the password using `everestctl` to ensure that the passwords are hashed.

### 4. Deploy additional database namespaces

After Everest is successfully running, you may create additional database namespaces using the `everest-db-namespace` Helm chart.
If you had set `dbNamespaces.enabled=false` in the previous step, you may deploy a database namespaces using the following command:

```sh
helm install everest \
    percona/everest-db-namespace \
    --create-namespace \
    --namespace everest
```

Notes:
* By default, all database operators are installed in your database namespace. You may override this by specifying one or more of the following: [`dbNamespace.pxc=false`, `dbNamespace.pg=false`, `dbNamespace.psmdb=false`].
* We currently do not support installation without the use of chart hooks. I.e, the use of `--no-hooks` is not supported during installation.

### 5. Uninstall

#### 5.1 Uninstalling database namespaces

If you created any database namespaces (apart from the one installed by default), you must delete them first.

```sh
helm uninstall everest -n <your_db_namespace>
kubectl delete ns <your_db_namespace>
```

Notes:
* This runs a chart hook that cleans up your database resources first. While it is not recommended, you may skip this step by specifying `cleanupOnUninstall=false`.

#### 5.2 Uninstalling Everest

```sh
helm uninstall everest-core -n everest-system
kubectl delete ns everest-system
```

## Configuration

The following table shows the configurable parameters of the Percona Everest chart and their default values.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| compatibility.openshift | bool | `false` | Enable OpenShift compatibility. If set, ignores olm.install and olm.namespace settings. |
| createMonitoringResources | bool | `true` | If set, creates resources for Kubernetes monitoring. |
| dbNamespace.enabled | bool | `true` | If set, deploy the database operators in `everest` namespace. The namespace may be overridden by setting `dbNamespace.namespaceOverride`. |
| dbNamespace.namespaceOverride | string | `"everest"` | If `dbNamespace.enabled` is `true`, deploy the database operators in this namespace. |
| namespaceOverride | string | `""` | Namespace override. Defaults to the value of .Release.Namespace. |
| olm.catalogSourceImage | string | `"perconalab/everest-catalog"` | Image to use for Everest CatalogSource. |
| olm.image | string | `"quay.io/operator-framework/olm@sha256:1b6002156f568d722c29138575733591037c24b4bfabc67946f268ce4752c3e6"` | Image to use for the OLM components. |
| olm.install | bool | `true` | If set, installs OLM in the provided namespace. |
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
| server.apiRequestsRateLimit | int | `100` | Set the allowed number of requests per second. |
| server.image | string | `"perconalab/everest"` | Image to use for the server container. |
| server.initialAdminPassword | string | `""` | The initial password configured for the admin user. If unset, a random password is generated. It is strongly recommended to reset the admin password after installation. |
| server.jwtKey | string | `""` | Key for signing JWT tokens. This needs to be an RSA private key. This is created during installation only. To update the key after installation, you need to manually update the `everest-jwt` Secret or use everestctl. |
| server.oidc | object | `{}` | OIDC configuration for Everest. These settings are applied during installation only. To change the settings after installation, you need to manually update the `everest-settings` ConfigMap. |
| server.rbac | object | `{"enabled":false,"policy":"g, admin, role:admin\n"}` | Settings for RBAC. These settings are applied during installation only. To change the settings after installation, you need to manually update the `everest-rbac` ConfigMap. |
| server.rbac.enabled | bool | `false` | If set, enables RBAC for Everest. |
| server.rbac.policy | string | `"g, admin, role:admin\n"` | RBAC policy configuration. Ignored if `rbac.enabled` is false. |
| server.resources | object | `{"limits":{"cpu":"200m","memory":"500Mi"},"requests":{"cpu":"100m","memory":"20Mi"}}` | Resources to allocate for the server container. |
| telemetry | bool | `true` | If set, enabled sending telemetry information. |
| upgrade.preflightChecks | bool | `true` | If set, run preliminary checks before upgrading. It is strongly recommended to enable this setting. |
| versionMetadataURL | string | `"https://check.percona.com"` | URL of the Version Metadata Service. |
