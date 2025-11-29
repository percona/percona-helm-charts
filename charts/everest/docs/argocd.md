# Using Everest Helm Chart with ArgoCD

## Overview
Everest can be installed and managed using ArgoCD, but there are specific configurations you must apply to avoid common pitfalls.
This guide outlines these issues and provides recommended configurations.

## Known issues (and solutions)

* The chart contains resources whose values are randomly generated if not explicitly specified. 
Since ArgoCD rerenders templates on every sync, these values will change, leading to your Application always appearing out of sync.
To resolve this, you need to include these resources in the `spec.ignoreDifferences` fields (see example below).
* The `everest-accounts` Secret might be managed externally (e.g., via `everestctl`).
To prevent ArgoCD from overwriting changes applied externally, include this Secret in the `spec.ignoreDifferences` field.
* During chart upgrades, Everest uses a `pre-upgrade` hook to verify some prerequisites.
ArgoCD treats this as a `PreSync` hook, causing upgrade checks to run on every sync, which will eventually fail.
To avoid this, disable the upgrade checks by setting `upgrade.preflightChecks=false`.
Note that disabling these checks means safe upgrades cannot be guaranteed when using ArgoCD.
* It is recommended to deploy the database namespaces separately from the core Everest application.
To achieve this, set `dbNamespaces.enabled=false` in your chart values and deploy the database namespaces as a separate `Application`.

#### Recommended configuration example:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
...
spec:
  ...
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    - RespectIgnoreDifferences=true
    # To prevent issues with synchronising some CRDs.
    - ServerSideApply=true
  ...
  ignoreDifferences:
  # If `server.jwtKey` is not set, the chart will generates a random key.
  # As a result, the Secret will always be out of sync, since ArgoCD will
  # rerender it on each sync.
  - group: ""
    jsonPointers:
    - /data
    kind: Secret
    name: everest-jwt
    namespace: everest-system
  # If `server.initialAdminPassword` is not set, the chart will generates a random password.
  # As a result, the Secret will always be out of sync, since ArgoCD will
  # rerender it on each sync. Moreover, this Secret may be managed externally, for example, using `everestctl`.
  - group: ""
    jsonPointers:
    - /data
    kind: Secret
    name: everest-accounts
    namespace: everest-system
  # If OLM is deployed without cert-manager, the below TLS certificates are randomly generated.
  # As a result, the Secret will always be out of sync, since ArgoCD will
  # rerender it on each sync.
  - group: ""
    jsonPointers:
    - /data
    kind: Secret
    name: packageserver-service-cert
    namespace: everest-olm
  - group: apiregistration.k8s.io
    jqPathExpressions:
    - .spec.caBundle
    - .metadata.annotations
    kind: APIService
    name: v1.packages.operators.coreos.com
  # If `operator.webhook.certs` are not set explicitly, the chart will generate random certificates.
  # As a result, the TLS Secret and Mutating/Validating webhook configurations (caBundle) will always appear out of sync.
  - group: ""
    jsonPointers:
    - /data
    kind: Secret
    name: webhook-server-cert
    namespace: everest-system
  - group: admissionregistration.k8s.io
    jqPathExpressions:
    - .webhooks[].clientConfig.caBundle
    kind: MutatingWebhookConfiguration
    name: everest-operator-mutating-webhook-configuration
  - group: admissionregistration.k8s.io
    jqPathExpressions:
    - .webhooks[].clientConfig.caBundle
    kind: ValidatingWebhookConfiguration
    name: everest-operator-validating-webhook-configuration
  ...
  source:
    helm:
      parameters:
      - name: dbNamespace.enabled
        value: "false"
      - name: upgrade.preflightChecks
        value: "false"
...
```

Complete example can be found [here](./application.yaml).

## Managing database namespaces

Once your core Everest application is installed and synced, you can create a new ArgoCD Application for managing your database namespaces.

#### Example:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: everest-db
  namespace: argocd
spec:
  destination:
    namespace: everest
    server: https://kubernetes.default.svc
  project: default
  source:
    chart: everest-db-namespace
    repoURL: https://percona.github.io/percona-helm-charts/
    targetRevision: 1.3.0
  syncPolicy:
    syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
```
