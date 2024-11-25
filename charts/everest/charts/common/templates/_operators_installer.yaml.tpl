#
# @param .namespace     The namespace where the operators are installed
#
{{- define "everest.operatorsInstaller" }}
{{- $hookName := "everest-operators-installer" }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
rules:
  - apiGroups:
      - ""
    resources:
      - namespaces
    verbs:
      - get
      - list
      - patch
      - update
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
    "helm.sh/hook": post-install,post-upgrade
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
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $hookName }}
  namespace: {{ .namespace }}
  annotations:
    "helm.sh/hook": post-install,post-upgrade
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
              kubectl label namespace {{ .namespace }} app.kubernetes.io/managed-by=everest --overwrite
              subs=$(kubectl -n {{ .namespace }} get subscription -o jsonpath='{.items[*].metadata.name}')
              for sub in $subs
              do
                # We do not want to touch already installed operators, otherwise bad things can happen.
                installedCSV=$(kubectl -n {{ .namespace }} get sub $sub -o jsonpath='{.status.installedCSV}')
                if [ "$installedCSV" != "" ]; then
                  echo "Operator $sub already installed. Skip..."
                  continue
                fi

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
{{- end }}
