# Cleanup all load balancer configs during uninstall.
#
# @param .namespace     The namespace where Everest server is installed
# @param .image         The image to use for running the hook Job
#
{{- define "everest.lbcCleanup" }}
{{- $hookName := printf "everest-helm-lbc-cleanup-hook" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $hookName }}
  annotations:
    "helm.sh/hook": post-delete
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
    "helm.sh/hook-weight": "0"
rules:
  - apiGroups:
      - everest.percona.com
    resources:
      - loadbalancerconfigs
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
    "helm.sh/hook-weight": "0"
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
    "helm.sh/hook-weight": "0"
spec:
  template:
    spec:
      containers:
        - image: {{ .image }}
          name: {{ $hookName }}
          command:
            - /bin/sh
            - -c
            - |
              for lbc in $(kubectl get loadbalancerconfig -o name); do
                kubectl patch $lbc -p '{"metadata":{"finalizers":[]}}' --type=merge || true
                kubectl delete $lbc || true
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}
