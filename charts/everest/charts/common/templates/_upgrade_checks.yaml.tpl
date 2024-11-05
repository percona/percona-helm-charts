#
# @param .namespace             The namespace where the operator is installed
# @param .version               Version to upgrade to
# @param .versionMetadataURL    The URL of the version metadata service
#
{{- define "everest.preUpgradeChecks" }}
{{- $hookName := printf "everest-helm-pre-upgrade-hook" }}
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
            - -c
            - |
              OS=$(uname -s | tr '[:upper:]' '[:lower:]')
              ARCH=$(uname -m)
              VERSION={{ .version }}
              apk add --no-cache --quiet curl
              curl -sSL -o everestctl https://github.com/percona/everest/releases/download/v${VERSION}/everestctl-${OS}-${ARCH}
              chmod -R 777 ./everestctl
              
              echo "Checking requirements for upgrade to version ${VERSION}"
              ./everestctl upgrade --dry-run --version-metadata-url={{ .versionMetadataURL }}
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      terminationGracePeriodSeconds: 30
{{- end }}
