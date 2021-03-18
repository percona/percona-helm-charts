{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "pxc-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "pxc-operator.fullname" -}}
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
{{- define "pxc-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "pxc-operator.labels" -}}
app.kubernetes.io/name: {{ include "pxc-operator.name" . }}
helm.sh/chart: {{ include "pxc-operator.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pxc-operator.CRDsConfigMap" -}}
{{- printf "%s-crd-config-map" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "pxc-operator.CRDsJob" -}}
{{- printf "%s-crd-job" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "pxc-operator.CRConfigMap" -}}
{{- printf "%s-cr-config-map" .Release.Name | trunc 63 -}}
{{- end -}}

{{- define "pxc-operator.pxcVersion" -}}
{{- if hasPrefix "8.0" .Values.pxc.version -}}
{{ .Values.pxc80.image.registry }}/{{ .Values.pxc80.image.repository }}:{{ .Values.pxc80.image.tag }}
{{- else if hasPrefix "5.7" .Values.pxc.version -}}
{{ .Values.pxc57.image.registry }}/{{ .Values.pxc57.image.repository }}:{{ .Values.pxc57.image.tag }}
{{- end -}}
{{- end -}}

{{- define "pxc-operator.pxcBackupVersion" -}}
{{- if hasPrefix "8.0" .Values.pxc.version -}}
{{ .Values.pxc80backup.image.registry }}/{{ .Values.pxc80backup.image.repository }}:{{ .Values.pxc80backup.image.tag }}
{{- else if hasPrefix "5.7" .Values.pxc.version -}}
{{ .Values.pxc57backup.image.registry }}/{{ .Values.pxc57backup.image.repository }}:{{ .Values.pxc57backup.image.tag }}
{{- end -}}
{{- end -}}

{{- define "pxc-operator.unsafeConfigurations" -}}
{{- if eq .Values.pxc.replicas 1.0 -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{- define "pxc-operator.serviceType" -}}
{{- if or (eq .Values.serviceType "InternalLB") (eq .Values.serviceType "PublicLB") -}}
LoadBalancer
{{- else -}}
ClusterIP
{{- end -}}
{{- end -}}
