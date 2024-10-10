#
# @param .namespace     The namespace where DB and its resources are deployed
#
{{- define "everest.dbResourcesCleanup" }}
{{- $hookName := printf "everest-helm-pre-delete-db-resource-cleanup" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook-delete-policy": hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook-delete-policy": hook-succeeded
rules:
  - apiGroups:
      - everest.percona.com
    resources:
      - databaseclusters
      - backupstorages
      - monitoringconfigs
    verbs:
      - delete
      - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook-delete-policy": hook-succeeded
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
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
    "helm.sh/hook": pre-delete
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  template:
    spec:
      containers:
        - image: bitnami/kubectl:latest
          name: {{ $hookName }}
          command:
            - /bin/sh
            - -c
            - |
              echo "Deleting DatabaseClusters"
              kubectl delete databaseclusters -n {{ .namespace }} --all --wait
              
              echo "Deleting BackupStorages"
              kubectl delete backupstorages -n {{ .namespace }} --all --wait
                
              echo "Deleting MonitoringConfigs"
              kubectl delete monitoringconfigs -n {{ .namespace }} --all --wait
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}

