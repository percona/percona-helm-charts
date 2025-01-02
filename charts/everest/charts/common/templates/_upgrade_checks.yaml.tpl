#
# @param .namespace             The namespace where the operator is installed
# @param .version               Version to upgrade to
# @param .versionMetadataURL    The URL of the version metadata service
#
{{- define "everest.preUpgradeChecks" }}
{{- $hookName := printf "everest-helm-pre-upgrade-hook" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
rules:
  - apiGroups:
      - apps
    resources:
      - deployments
    verbs:
      - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $hookName }}
subjects:
  - kind: ServiceAccount
    name: {{ $hookName }}
    namespace: {{ .namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
rules:
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - list
  - apiGroups:
      - operators.coreos.com
    resources:
      - subscriptions
      - clusterserviceversions
    verbs:
      - get
      - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $hookName }}
subjects:
  - kind: ServiceAccount
    name: {{ $hookName }}
    namespace: {{ .namespace }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $hookName }}-{{ randNumeric 6 }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      containers:
        - image: alpine:3.20
          name: {{ $hookName }}
          command:
            - /bin/sh
            - -ec
            - |
              OS=$(uname -s | tr '[:upper:]' '[:lower:]')
              ARCH=$(uname -m)

              # Map ARCH to match available builds
              if [ "$ARCH" = "x86_64" ]; then
                  ARCH="amd64"
              elif [ "$ARCH" = "aarch64" ]; then
                  ARCH="arm64"
              else
                  echo "Unsupported architecture: $ARCH"
                  exit 1
              fi

              VERSION={{ .version }}
              apk add --no-cache --quiet curl
              curl -sSL -o everestctl https://github.com/percona/everest/releases/download/v${VERSION}/everestctl-${OS}-${ARCH}
              chmod -R 777 ./everestctl
              
              echo "Checking requirements for upgrade to version ${VERSION}"
              ./everestctl upgrade --in-cluster --dry-run --version-metadata-url={{ .versionMetadataURL }} --kubeconfig=""
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      terminationGracePeriodSeconds: 30
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
{{- end }}
