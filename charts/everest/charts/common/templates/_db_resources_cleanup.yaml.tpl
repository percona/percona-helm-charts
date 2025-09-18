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
    "helm.sh/hook": pre-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-1"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-1"
rules:
  - apiGroups:
      - everest.percona.com
    resources:
      - databaseclusters
      - backupstorages
      - monitoringconfigs
    verbs:
      - get
      - delete
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": pre-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-1"
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
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-1"
spec:
  template:
    spec:
      containers:
        - image: percona/everest-helmtools:0.0.1
          name: {{ $hookName }}
          command:
            - /bin/sh
            - -ec
          args:
            - |
              echo "Deleting DatabaseClusters"
              kubectl delete databaseclusters -n {{ .namespace }} --all --wait --cascade='foreground'
              
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

