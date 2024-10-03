#
# @param .namespace     The namespace where the operator is installed
#
{{- define "everest.installplanApprover" }}
{{- $hookName := "everest-helm-post-install-hook" }}
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
      - operators.coreos.com
    resources:
      - installplans
    verbs:
      - get
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - operators.coreos.com
    resources:
      - subscriptions
      - clusterserviceversions
    verbs:
      - get
      - list
      - watch
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
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": hook-succeeded
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      containers:
        - image: bitnami/kubectl:latest
          name: {{ $hookName }}
          command:
            - /bin/sh
            - -c
            - |
              subs=$(kubectl -n {{ .namespace }} get subscription -o jsonpath='{.items[*].metadata.name}')
              for sub in $subs
              do
                echo "Waiting for InstallPlan to be created for Subscription $sub"
                kubectl wait --for=jsonpath='.status.installplan.name' sub/$sub -n {{ .namespace }} --timeout=600s
                
                ip=$(kubectl -n {{ .namespace }} get sub $sub -o jsonpath='{.status.installplan.name}')
                echo "InstallPlan $ip created for Subscription $sub"

                echo "Approving InstallPlan $ip"
                kubectl -n {{ .namespace }} patch installplan $ip --type='json' -p='[{"op": "replace", "path": "/spec/approved", "value": true}]'

                echo "Waiting for InstallPlan to be complete $ip"
                kubectl wait --for=jsonpath='.status.phase'=Complete installplan/$ip -n {{ .namespace }} --timeout=600s

                csv=$(kubectl get sub $sub -n {{ .namespace }} -o jsonpath='{.status.installedCSV}')

                echo "Waiting for CSV $csv to succeed"
                kubectl wait --for=jsonpath='.status.phase'=Succeeded csv/$csv -n {{ .namespace }} --timeout=600s
              done
      dnsPolicy: ClusterFirst
      restartPolicy: OnFailure
      serviceAccount: {{ $hookName }}
      serviceAccountName: {{ $hookName }}
      terminationGracePeriodSeconds: 30
---
{{- end }}
