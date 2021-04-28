{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "pxc-database.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pxc-database.fullname" -}}
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
{{- define "pxc-database.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 21 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pxc-database.labels" -}}
app.kubernetes.io/name: {{ include "pxc-database.name" . }}
helm.sh/chart: {{ include "pxc-database.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
This filters the backup.storages hash for S3 credentials. If we detect them, they go in a separate secret.
*/}}
{{- define "pxc-database.storages" -}}
{{- $storages := dict -}}
{{- range $key, $value := .Values.backup.storages -}}
{{- if and (hasKey $value "type") (eq $value.type "s3") (hasKey $value "s3") (hasKey (index $value "s3") "credentialsAccessKey") (hasKey (index $value "s3") "credentialsSecretKey") }}
{{- if hasKey (index $value "s3") "credentialsSecret" -}}
{{- fail "credentialsSecret and credentialsAccessKey/credentialsSecretKey isn't supported!" -}}
{{- end -}}
{{- $secretName := printf "%s-s3-%s" (include "pxc-database.fullname" $) $key -}}
{{- $s3 := set (omit (index $value "s3") "credentialsAccessKey" "credentialsSecretKey") "credentialsSecret" $secretName -}}
{{- $_value := set (omit $value "s3") "s3" $s3 -}}
{{- $_ := set $storages $key $_value -}}
{{- else -}}
{{- $_ := set $storages $key $value -}}
{{- end -}}
{{- end -}}
{{- $storages | toYaml -}}
{{- end -}}
