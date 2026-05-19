# Installing Percona Everest on OpenShift

The Percona Everest Helm chart can be installed on OpenShift with some additional configuration steps.

> Note: Support for OpenShift is currently in progress, so it may not work as expected. If you encounter any issues, please report them by creating a new issue [here](https://github.com/percona/everest/issues/new).

## 1. Install Everest

Run the following command to install Everest with OpenShift compatibility enabled:

```sh
helm install everest-core percona/everest \
    --namespace everest-system \
    --create-namespace \
    --set compatibility.openshift=true \
    --set dbNamespace.compatibility.openshift=true \
    --set olm.install=false \
    --set kube-state-metrics.securityContext.enabled=false \
    --set kube-state-metrics.rbac.create=false
```

## 2. (Optional) Update RBAC for kube-state-metrics

If you're using a chart version older than 1.5.0, you must manually create a `ClusterRoleBinding` for kube-state-metrics. Use the following YAML:

```sh
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ksm-openshift-cluster-role-binding
roleRef:
  kind: "ClusterRole"
  apiGroup: "rbac.authorization.k8s.io"
  name: kube-state-metrics
subjects:
  - kind: "ServiceAccount"
    name: kube-state-metrics
    namespace: everest-monitoring
EOF
```

> Note: For versions 1.5.0 and above, this `ClusterRoleBinding` is created automatically when you set `compatibility.openshift=true`.

## 3. (Optional) Install additional database namespaces

If you need to add database namespaces, run the following command with OpenShift compatibility enabled:

```
helm install everest \
    percona/everest-db-namespace \
    --create-namespace \
    --namespace everest \
    --set compatibility.openshift=true
```

For detailed instructions, refer to the guide linked [here](../README.md), but adjust the installation parameters according to the values specified in this document.

