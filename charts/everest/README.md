# Percona Everest

This helm chart deploys Percona Everest.

Useful links:
- [Percona Everest Documentation](https://docs.percona.com/everest/index.html)
- [Percona Everest GitHub](https://github.com/percona/everest)
- [Deploying with ArgoCD](./docs/argocd.md)
- [Installing on OpenShift](./docs/openshift.md)

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

#### 4.1 Deploying additional operators to an existing database namespace

If you have an existing database namespace and would like to deploy additional operators to it, you may do so using the following command:

```sh
helm upgrade everest \
    percona/everest-db-namespace \
    --namespace [NAMESPACE]
    --pxc=true \
    --pg=true
```

The above example assumes that the MongoDB operator is already installed in the database namespace and you would like to install the Percona XtraDB Cluster and PostgreSQL operators.

Notes:
* Removing a database operator from a namespace is not supported. You may only add additional operators.

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

### 6. Upgrade

#### 6.1 Upgrade CRDs

As of Helm v3, CRDs are not automatically updated during a Helm upgrade. You must manually upgrade the CRDs.

```sh
helm repo update
helm upgrade --install everest-crds \
    percona/everest-crds \
    --namespace everest-system \
    --take-ownership
```

> **Note:** If you're using a version of Helm older than `3.17.0`, the `--take-ownership` flag will not be available.
> This flag is required only when upgrading from Everest 1.8.0. Without it, you may encounter the following error:
>
> ```sh
> invalid ownership metadata; label validation error: missing key "app.kubernetes.io/managed-by": must be set to "Helm";
> annotation validation error: missing key "meta.helm.sh/release-name": must be set to "everest-crds";
> annotation validation error: missing key "meta.helm.sh/release-namespace": must be set to "everest-system"
> ```
>
> If you must use a Helm version older than `3.17.0`, you can manually simulate the behavior of `--take-ownership` by adding the required labels and annotations to the Everest CRDs:
>
> ```sh
> CRDS=(databaseclusters.everest.percona.com databaseengines.everest.percona.com databaseclusterbackups.everest.percona.com databaseclusterrestores.everest.percona.com backupstorages.everest.percona.com monitoringconfigs.everest.percona.com)
> kubectl label crds "${CRDS[@]}" app.kubernetes.io/managed-by=Helm --overwrite
> kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-name=everest-crds
> kubectl annotate crds "${CRDS[@]}" meta.helm.sh/release-namespace=everest-system
> ```
>
> This ensures the CRDs are correctly recognized as managed by Helm, avoiding validation issues during the upgrade.

#### 6.2 Upgrade Helm Releases

Upgrade the Helm release for Everest (core components):
```sh
helm upgrade everest-core percona/everest --namespace everest-system --version $(VERSION)
```

Upgrade the Helm release for the database namespace (if applicable):
```sh
helm upgrade everest percona/everest-db-namespace --namespace [DB NAMESPACE] --version $(VERSION)
```

Notes:
* :warning: When specifying values during an upgrade (i.e, using `--set`, `--set-json`, `--values`, etc.), Helm resets all the other values
to the defaults built into the chart. To preserve the previously set values, you must use the `--reuse-values` flag.
Alternatively, provide the full set of values, including any overrides applied during installation.
* It is recommended to upgrade 1 minor release at a time, otherwise you may run into unexpected issues.
* It is recommended to upgrade to the latest patch release first before upgrading to the next minor release.
* To ensure that the upgrade happens safely, we run a pre-upgrade hook that runs a series of checks. This can be disabled by setting `upgrade.preflightChecks=false`.
However, in doing so, a safe upgrade cannot be guaranteed.

## Configuration

The following table shows the configurable parameters of the Percona Everest chart and their default values.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| compatibility.openshift | bool | `false` | Enable OpenShift compatibility. |
| createMonitoringResources | bool | `true` | If set, creates resources for Kubernetes monitoring. |
| dataImporters.perconaPGOperator | object | `{"enabled":true}` | Settings for the Percona PostgreSQL Operator data importer. |
| dataImporters.perconaPGOperator.enabled | bool | `true` | If set, installs the Percona PostgreSQL Operator data importer. |
| dataImporters.perconaPSMDBOperator | object | `{"enabled":true}` | Settings for the Percona PSMDB Operator data importer. |
| dataImporters.perconaPSMDBOperator.enabled | bool | `true` | If set, installs the Percona PSMDB Operator data importer. |
| dataImporters.perconaPXCOperator | object | `{"enabled":true}` | Settings for the Percona PXC Operator data importer. |
| dataImporters.perconaPXCOperator.enabled | bool | `true` | If set, installs the Percona PXC Operator data importer. |
| dbNamespace.enabled | bool | `true` | If set, deploy the database operators in `everest` namespace. The namespace may be overridden by setting `dbNamespace.namespaceOverride`. |
| dbNamespace.namespaceOverride | string | `"everest"` | If `dbNamespace.enabled` is `true`, deploy the database operators in this namespace. |
| hooks | object | `{"image":"percona/everest-helmtools:0.0.1","lbcCleanup":{},"pspCleanup":{},"upgradeChecks":{}}` | Configuration for Helm chart hooks. |
| hooks.image | string |  | Default image to use for the Helm chart hooks job. |
| hooks.lbcCleanup | object | `{}` | Configuration for LoadBalancerConfig clean-up hook. |
| hooks.pspCleanup | object | `{}` | Configuration for PodSchedulingPolicy clean-up hook. |
| hooks.upgradeChecks | object | `{}` | Configuration for the upgrade checks hook. |
| ingress.annotations | object | `{}` | Additional annotations for the ingress resource. |
| ingress.enabled | bool | `false` | Enable ingress for Everest server |
| ingress.hosts | list | `[{"host":"chart-example.local","paths":[{"path":"/","pathType":"ImplementationSpecific"}]}]` | List of hosts and their paths for the ingress resource. |
| ingress.ingressClassName | string | `""` | Ingress class name. This is used to specify which ingress controller should handle this ingress. |
| ingress.tls | list | `[]` | Each entry in the list specifies a TLS certificate and the hosts it applies to. |
| namespaceOverride | string | `""` | Namespace override. Defaults to the value of .Release.Namespace. |
| olm.catalogSourceImage | string | `"perconalab/everest-catalog"` | Image to use for Everest CatalogSource. |
| olm.image | string | `"percona/olm@sha256:13e8f4e919e753faa7da35a9064822381098bcd44acc284877bf0964ceecbfd5"` | Image to use for the OLM components. |
| olm.install | bool | `true` | If set, installs OLM in the provided namespace. Should be set to `false` if compatibility.openshift=true. |
| olm.namespace | string | `"everest-olm"` | Namespace where OLM is installed. Do no change unless you know what you are doing. DEPRECATED: Will be removed in a future release. Use olm.namespaceOverride instead. |
| olm.namespaceOverride | string | `"everest-olm"` | Namespace where OLM is installed. Do no change unless you know what you are doing. |
| olm.packageserver.tls.caCert | string | `""` | CA certificate for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.tlsCert | string | `""` | Client certificate for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.tlsKey | string | `""` | Client key for the PackageServer APIService. Overrides the tls.type setting. |
| olm.packageserver.tls.type | string | `"helm"` | Type of TLS certificates. Supported values are "helm" and "cert-manager". For production setup, it is recommended to use "cert-manager". |
| operator.enableLeaderElection | bool | `true` | Enable leader election for the operator. |
| operator.env | list | `[]` | Additional environment variables to pass to the operator deployment. |
| operator.healthProbeAddr | string | `":8081"` | Health probe address for the operator. |
| operator.image | string | `"perconalab/everest-operator"` | Image to use for the Everest operator container. |
| operator.init | bool | `true` | Enable initContainer migration |
| operator.metricsAddr | string | `"127.0.0.1:8080"` | Metrics address for the operator. |
| operator.resources | object | `{"limits":{"cpu":"500m","memory":"128Mi"},"requests":{"cpu":"5m","memory":"64Mi"}}` | Resources to allocate for the operator container. |
| operator.webhook.certs | object | `{"ca.crt":"","tls.crt":"","tls.key":""}` | Certificates to use for the webhook server. The values must be base64 encoded. If unset, uses self-signed certificates. |
| operator.webhook.preserveTLSCerts | bool |  | If set to true, preserves existing TLS Certificate Secrets during upgrades. This setting is ignored if certificates are explicitly provided in operator.webhook.certs, in which case the specified certificates are used instead. This setting has no effect during installation. |
| pmm | object | `{"enabled":false,"nameOverride":"pmm"}` | PMM settings. |
| pmm.enabled | bool | `false` | If set, deploys PMM in the release namespace. |
| server.apiRequestsRateLimit | int | `100` | Set the allowed number of requests per second. |
| server.env | list | `[]` | Additional environment variables to pass to the server deployment. |
| server.image | string | `"perconalab/everest"` | Image to use for the server container. |
| server.initialAdminPassword | string | `""` | The initial password configured for the admin user. If unset, a random password is generated. It is strongly recommended to reset the admin password after installation. |
| server.jwtKey | string | `""` | Key for signing JWT tokens. This needs to be an RSA private key. This is created during installation only. To update the key after installation, you need to manually update the `everest-jwt` Secret or use everestctl. |
| server.oidc | object | `{}` | OIDC configuration for Everest. These settings are applied during installation only. To change the settings after installation, you need to manually update the `everest-settings` ConfigMap. |
| server.rbac | object | `{"enabled":false,"policy":"g, admin, role:admin\n"}` | Settings for RBAC. These settings are applied during installation only. To change the settings after installation, you need to manually update the `everest-rbac` ConfigMap. |
| server.rbac.enabled | bool | `false` | If set, enables RBAC for Everest. |
| server.rbac.policy | string | `"g, admin, role:admin\n"` | RBAC policy configuration. Ignored if `rbac.enabled` is false. |
| server.resources | object | `{"limits":{"cpu":"200m","memory":"500Mi"},"requests":{"cpu":"100m","memory":"20Mi"}}` | Resources to allocate for the server container. |
| server.service | object | `{"name":"everest","port":8080,"type":"ClusterIP"}` | Service configuration for the server. |
| server.service.name | string | `"everest"` | Name of the service for everest |
| server.service.port | int | `8080` | Port to expose on the service. If `tls.enabled=true`, then the service is exposed on port 443. |
| server.service.type | string | `"ClusterIP"` | Type of service to create. |
| server.tls.certificate.additionalHosts | list | `[]` | Certificate Subject Alternate Names (SANs) |
| server.tls.certificate.create | bool | `false` | Create a Certificate resource (requires cert-manager to be installed) If set, creates a Certificate resource instead of a Secret. The Certificate uses the Secret name provided by `tls.secret.name` The Everest server pod will come up only after cert-manager has reconciled the Certificate resource. |
| server.tls.certificate.domain | string | `""` | Certificate primary domain (commonName) |
| server.tls.certificate.duration | string |  | The requested 'duration' (i.e. lifetime) of the certificate. # Ref: https://cert-manager.io/docs/usage/certificate/#renewal |
| server.tls.certificate.issuer.group | string | `""` | Certificate issuer group. Set if using an external issuer. Eg. `cert-manager.io` |
| server.tls.certificate.issuer.kind | string | `""` | Certificate issuer kind. Either `Issuer` or `ClusterIssuer` |
| server.tls.certificate.issuer.name | string | `""` | Certificate issuer name. Eg. `letsencrypt` |
| server.tls.certificate.privateKey.algorithm | string | `"RSA"` | Algorithm used to generate certificate private key. One of: `RSA`, `Ed25519` or `ECDSA` |
| server.tls.certificate.privateKey.encoding | string | `"PKCS1"` | The private key cryptography standards (PKCS) encoding for private key. Either: `PCKS1` or `PKCS8` |
| server.tls.certificate.privateKey.rotationPolicy | string | `"Never"` | Rotation policy of private key when certificate is re-issued. Either: `Never` or `Always` |
| server.tls.certificate.privateKey.size | int | `2048` | Key bit size of the private key. If algorithm is set to `Ed25519`, size is ignored. |
| server.tls.certificate.renewBefore | string |  | How long before the expiry a certificate should be renewed. # Ref: https://cert-manager.io/docs/usage/certificate/#renewal |
| server.tls.certificate.secretTemplate | object | `{"annotations":{},"labels":{}}` | Template for the Secret created by the Certificate resource. |
| server.tls.certificate.secretTemplate.annotations | object | `{}` | Annotations to add to the Secret created by the Certificate resource. |
| server.tls.certificate.secretTemplate.labels | object | `{}` | Labels to add to the Secret created by the Certificate resource. |
| server.tls.certificate.usages | list | `[]` | Usages for the certificate ## Ref: https://cert-manager.io/docs/reference/api-docs/#cert-manager.io/v1.KeyUsage |
| server.tls.enabled | bool | `false` | If set, enables TLS for the Everest server. Setting tls.enabled=true creates a Secret containing the TLS certificates. Along with certificate.create, it creates a Certificate resource instead. |
| server.tls.secret.certs | object | `{"tls.crt":"","tls.key":""}` | Use the specified tls.crt and tls.key in the Secret. If unspecified, the server creates a self-signed certificate (not recommended for production). |
| server.tls.secret.name | string | `"everest-server-tls"` | Name of the Secret containing the TLS certificates. This Secret is created if tls.enabled=true and certificate.create=false. |
| telemetry | bool | `false` | If set, enabled sending telemetry information. In production release, this value is `true` by default. |
| upgrade.crdChecks | bool | `true` | Ensures that CRDs are upgraded first (default: true). Set to false to disable. |
| upgrade.preflightChecks | bool | `true` | Ensures that preflight checks are run before the upgrade (default: true). Set to false to disable. |
| versionMetadataURL | string | `"https://check.percona.com"` | URL of the Version Metadata Service. |

## Notice for developers
In case you made any changes in `percona-helm-charts/charts/everest/charts/common` or `percona-helm-charts/charts/everest/charts/everest-db-namespace` directories,
please make sure you perform the following actions before creating PR:
- bump chart version in `percona-helm-charts/charts/everest/charts/common/Chart.yaml` or `percona-helm-charts/charts/everest/charts/everest-db-namespace/Chart.yaml` accordingly in `version` parameter.
- in `percona-helm-charts/charts/everest` directory run:
    ```bash
    make prepare-pr
    ```

In case you need to update the Everest Custom Resource Definitions (CRDs) after the changes in `github.com/percona/everest-operator` repository, please run the following command:
```bash
CRD_VERSION=<branch name in percona/everest-operator repo> make prepare-pr
```
