# Assign default pod scheduling policies to all existing DB clusters.
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
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-4"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-4"
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
  - apiGroups:
      - everest.percona.com
    resources:
      - podschedulingpolicies
    verbs:
      - get
      - list
      - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-4"
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
    "helm.sh/hook-weight": "-4"
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
              kubectl wait --for=create --timeout=10s podschedulingpolicy everest-default-mysql everest-default-postgresql everest-default-mongodb

              for nsName in `kubectl get namespace -lapp.kubernetes.io/managed-by=everest --no-headers -o jsonpath='{.items[*].metadata.name}'`
              do
                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="postgresql")].metadata.name}'`
                  do
                    kubectl patch -n $nsName databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-postgresql"}}' --type=merge
                  done

                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="psmdb")].metadata.name}'`
                  do
                    kubectl patch -n $nsName databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-mongodb"}}' --type=merge
                  done

                  for dbName in `kubectl get databaseclusters -n $nsName -o jsonpath='{.items[?(@.spec.engine.type=="pxc")].metadata.name}'`
                  do
                    kubectl patch -n $nsName databasecluster/$dbName -p '{"spec":{"podSchedulingPolicyName": "everest-default-mysql"}}' --type=merge
                  done
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}
