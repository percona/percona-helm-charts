{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "ps-database.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "ps-database.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 21 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 21 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 21 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ps-database.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 21 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "ps-database.labels" -}}
app.kubernetes.io/name: {{ include "ps-database.name" . }}
helm.sh/chart: {{ include "ps-database.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Resources with optional requests and limits
*/}}
{{- define "ps-db.resources" -}}
resources:
  {{- if hasKey .resources "requests" }}
  requests:
    {{- tpl (toYaml .resources.requests) .root | nindent 4 }}
  {{- end }}
  {{- if hasKey .resources "limits" }}
  limits:
    {{- tpl (toYaml .resources.limits) .root | nindent 4 }}
  {{- end }}
{{- end -}}

{{/*
Init container. Image is omitted when empty so the operator picks its default.
*/}}
{{- define "ps-db.initContainer" -}}
initContainer:
  {{- with .initContainer.image }}
  image: {{ . }}
  {{- end }}
  {{- with .initContainer.containerSecurityContext }}
  containerSecurityContext:
    {{- tpl (toYaml .) $.root | nindent 4 }}
  {{- end }}
  {{- with .initContainer.resources }}
  {{- include "ps-db.resources" (dict "resources" . "root" $.root) | nindent 2 }}
  {{- end }}
{{- end -}}
