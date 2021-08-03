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

{{- define "pg-database.primary-image" -}}
{{- if .Values.pgPrimary.image }}
{{- .Values.pgPrimary.image }}
{{- else }}
{{- printf "%s:%s-%s-postgres-ha" .Values.image.repo .Chart.AppVersion .Values.image.pgver }}
{{- end }}
{{- end -}}

{{- define "pg-database.backup-image" -}}
{{- if .Values.backup.image }}
{{- .Values.backup.image }}
{{- else }}
{{- printf "%s:%s-%s-pgbackrest" .Values.image.repo .Chart.AppVersion .Values.image.pgver }}
{{- end }}
{{- end -}}

{{- define "pg-database.backup-repo-image" -}}
{{- if .Values.backup.backrestRepoImage }}
{{- .Values.backup.backrestRepoImage }}
{{- else }}
{{- printf "%s:%s-%s-pgbackrest-repo" .Values.image.repo .Chart.AppVersion .Values.image.pgver }}
{{- end }}
{{- end -}}

{{- define "pg-database.pgbouncer-image" -}}
{{- if .Values.pgBouncer.image }}
{{- .Values.pgBouncer.image }}
{{- else }}
{{- printf "%s:%s-%s-pgbouncer" .Values.image.repo .Chart.AppVersion .Values.image.pgver }}
{{- end }}
{{- end -}}

{{- define "pg-database.pgbadger-image" -}}
{{- if .Values.pgBouncer.image }}
{{- .Values.pgBouncer.image }}
{{- else }}
{{- printf "%s:%s-%s-pgbadger" .Values.image.repo .Chart.AppVersion .Values.image.pgver }}
{{- end }}
{{- end -}}

{{- define "pg-database.backup-storages" -}}
{{- if .Values.backup.storages }}
storages:
{{- range $storage := .Values.backup.storages }}
{{- if or (eq $storage.type "s3") (eq $storage.type "gcs") }}
  {{ $storage.name }}:
  {{- if $storage.type }}
    type: {{ $storage.type }}
  {{- end }}
  {{- if $storage.endpointUrl }}
    endpointUrl: {{ $storage.endpointUrl }}
  {{- end }}
  {{- if $storage.region }}
    region: {{ $storage.region }}
  {{- end }}
  {{- if $storage.uriStyle }}
    uriStyle: {{ $storage.uriStyle }}
  {{- end }}
  {{- if $storage.verifyTLS }}
    verifyTLS: {{ $storage.verifyTLS }}
  {{- end }}
    bucket: {{ $storage.bucket }}
{{- end }}
{{- end }}
storageTypes:
{{- range $storage := .Values.backup.storages }}
- {{ $storage.type }}
{{- end }}
{{- else }}
storageTypes:
- local
{{- end }}
{{- end -}}