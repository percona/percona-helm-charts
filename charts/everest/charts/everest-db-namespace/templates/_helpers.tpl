{{/*
Allows overriding the install namespace in combined charts.
*/}}
{{- define "db.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Allow overriding OLM namespace
*/}}
{{- define "db.olmNamespace"}}
{{- if .Values.compatibility.openshift }}
{{- "openshift-marketplace" }}
{{- else }}
{{- .Values.olm.namespace }}
{{- end }}
{{- end }}

