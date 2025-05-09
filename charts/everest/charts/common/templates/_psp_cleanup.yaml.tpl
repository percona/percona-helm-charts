# Cleanup all default pod scheduling policies during uninstall.
#
# @param .namespace     The namespace where Everest server is installed
#
{{- define "everest.pspCleanup" }}
{{- $hookName := printf "everest-helm-psp-cleanup-hook" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-5"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-5"
rules:
  - apiGroups:
      - everest.percona.com
    resources:
      - podschedulingpolicies
    verbs:
      - get
      - list
      - patch
      - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-5"
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
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "-5"
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
              for pspName in `kubectl get podschedulingpolicy -o jsonpath='{.items[?(@.metadata.finalizers[*]=="everest.percona.com/readonly-protection")].metadata.name}'`
              do
                kubectl patch podschedulingpolicy/$pspName -p '{"metadata":{"finalizers":[]}}' --type=merge
                kubectl delete $pspName
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}
