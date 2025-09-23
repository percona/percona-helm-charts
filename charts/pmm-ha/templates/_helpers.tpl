{{/*
Expand the name of the chart.
*/}}
{{- define "pmm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pmm.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "pmm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pmm.labels" -}}
helm.sh/chart: {{ include "pmm.chart" . }}
{{ include "pmm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pmm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pmm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pmm-server
app.kubernetes.io/part-of: percona-platform
{{- if .Values.extraLabels }}
{{ toYaml .Values.extraLabels }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "pmm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "pmm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Pod annotation
*/}}
{{- define "pmm.podAnnotations" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "pmm.chart" . }}
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
{{- if .Values.podAnnotations }}
{{ toYaml .Values.podAnnotations }}
{{- end }}
{{- end }}

{{/*
Override pg-database.fullname to ensure consistent naming
This overrides the function from the pg-db subchart
*/}}
{{- define "pg-database.fullname" -}}
{{- printf "%s-pg-db" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Generate PMM HA peer list dynamically based on replicas count
*/}}
{{- define "pmm.haPeers" -}}
{{- $peers := list }}
{{- $serviceName := .Values.service.name | default "monitoring-service" }}
{{- $replicas := int .Values.replicas }}
{{- range $i := until $replicas }}
  {{- $peer := printf "%s-%d.%s.%s.svc.cluster.local" $.Release.Name $i $serviceName $.Release.Namespace }}
  {{- $peers = append $peers $peer }}
{{- end }}
{{- join "," $peers }}
{{- end -}}

{{/*
Generate PMM HA peer list for specific replica index
*/}}
{{- define "pmm.haPeer" -}}
{{- $serviceName := .Values.service.name | default "monitoring-service" }}
{{- printf "%s-%d.%s.%s.svc.cluster.local" .Release.Name .index $serviceName .Release.Namespace }}
{{- end -}}

{{/*
Generate PMM HA node ID for specific replica index
*/}}
{{- define "pmm.haNodeId" -}}
{{- printf "%s-%d" .Release.Name .index }}
{{- end -}}


