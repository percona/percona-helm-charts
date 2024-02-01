{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "pg-database.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pg-database.fullname" -}}
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
{{- define "pg-database.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 21 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pg-database.labels" -}}
app.kubernetes.io/name: {{ include "pg-database.name" . }}
helm.sh/chart: {{ include "pg-database.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pg-database.postgres-image" -}}
{{- if .Values.image }}
{{- .Values.image }}
{{- else }}
{{- printf "%s:%s-ppg%d-postgres" .Values.repository .Chart.AppVersion (.Values.postgresVersion | int ) }}
{{- end }}
{{- end -}}

{{- define "pg-database.backup-image" -}}
{{- if .Values.backups.pgbackrest.image }}
{{- .Values.backups.pgbackrest.image }}
{{- else }}
{{- printf "%s:%s-ppg%d-pgbackrest" .Values.repository .Chart.AppVersion (.Values.postgresVersion | int ) }}
{{- end }}
{{- end -}}

{{- define "pg-database.pgbouncer-image" -}}
{{- if .Values.proxy.pgBouncer.image }}
{{- .Values.proxy.pgBouncer.image }}
{{- else }}
{{- printf "%s:%s-ppg%d-pgbouncer" .Values.repository .Chart.AppVersion (.Values.postgresVersion | int )}}
{{- end }}
{{- end -}}

{{- define "pg-database.backup-repos" -}}
{{- if .Values.backups.pgbackrest.repos }}
repos:
{{- range $repo := .Values.backups.pgbackrest.repos }}
{{- if or ($repo.s3) ($repo.gcs) }}
  {{- if $repo.endpoint }}
    endpoint: {{ $repo.endpoint }}
  {{- end }}
  {{- if $repo.region }}
    region: {{ $repo.region }}
  {{- end }}
    bucket: {{ $repo.bucket }}
{{- end }}
{{- if $repo.azure }}
    container: {{ $repo.container}}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
