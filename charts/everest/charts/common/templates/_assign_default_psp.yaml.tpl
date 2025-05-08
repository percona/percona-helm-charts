#
# @param .namespace     The namespace where Everest server is installed
#
{{- define "everest.assignDefaultPsp" }}
{{- $hookName := printf "everest-helm-psp-post-upgrade-hook" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
rules:
  - apiGroups:
      - ''
    resources:
      - namespaces
    verbs:
      - list
      - get
  - apiGroups:
      - everest.percona.com
    resources:
      - databaseclusters
    verbs:
      - get
      - list
      - patch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
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
  name: {{ $hookName }}-pg-{{ randNumeric 6 }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
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
              for nsName in `kubectl get namespace -lapp.kubernetes.io/managed-by=everest --no-headers -o jsonpath='{.items[*].metadata.name}'`
              do
                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="postgresql")].metadata.name}'`
                  do
                    kubectl patch -n $nsName  databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-postgresql"}}' --type=merge
                  done
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $hookName }}-psmdb-{{ randNumeric 6 }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
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
              for nsName in `kubectl get namespace -lapp.kubernetes.io/managed-by=everest --no-headers -o jsonpath='{.items[*].metadata.name}'`
              do
                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="psmdb")].metadata.name}'`
                  do
                    kubectl patch -n $nsName  databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-psmdb"}}' --type=merge
                  done
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $hookName }}-pxc-{{ randNumeric 6 }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
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
              for nsName in `kubectl get namespace -lapp.kubernetes.io/managed-by=everest --no-headers -o jsonpath='{.items[*].metadata.name}'`
              do
                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="pxc")].metadata.name}'`
                  do
                    kubectl patch -n $nsName  databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-pxc"}}' --type=merge
                  done
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}
