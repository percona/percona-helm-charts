{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "psmdb-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "psmdb-operator.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "psmdb-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "psmdb-operator.labels" -}}
app.kubernetes.io/name: {{ include "psmdb-operator.name" . }}
helm.sh/chart: {{ include "psmdb-operator.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}


{{- define "psmdb-operator.CRDsConfigMap" -}}
{{- printf "%s-crd-config-map" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "psmdb-operator.CRDsJob" -}}
{{- printf "%s-crd-job" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "psmdb-operator.CRConfigMap" -}}
{{- printf "%s-cr-config-map" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "psmdb-operator.mongoImage" -}}
{{- $pattern := default (printf "%s/%%s:%s" .Values.psmdb.image.registry .Values.psmdb.image.tag) -}}
{{- if eq .Values.psmdb.image.version "4.2" }}
{{- printf $pattern .Values.psmdb42.image.repository -}}
{{- else if eq .Values.psmdb.image.version "4.0" }}
{{- printf $pattern .Values.psmdb40.image.repository -}}
{{- else -}}
{{- printf $pattern .Values.psmdb36.image.repository -}}
{{- end -}}
{{- end -}}