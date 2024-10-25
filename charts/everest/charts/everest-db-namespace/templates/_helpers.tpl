{{/*
Allows overriding the install namespace in combined charts.
*/}}
{{- define "db.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Allow overriding OLM namespacse
*/}}
{{- define "db.olmNamespace"}}
{{- .Values.olm.namespace }}
{{- end }}
