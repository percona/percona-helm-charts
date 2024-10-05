#
# @paramts  .root               Root object
#
{{- define "everest.operatorRoleBinding" }}
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: everest-operator
  namespace: {{ .namespace }}
subjects:
- kind: ServiceAccount
  name: everest-operator
  namespace: everest-system
roleRef:
  kind: ClusterRole
  name: everest-operator
  apiGroup: rbac.authorization.k8s.io
{{- end }}
