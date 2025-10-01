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
Allows overriding the install namespace in combined charts.
*/}}
{{- define "pmm.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Determines whether to include namespace specification.
Includes namespace for:
- Fresh installs
- Upgrades from chart version 1.4.1+ (detected by existing namespace field)
*/}}
{{- define "pmm.includeNamespace" -}}
{{- $shouldInclude := true -}}
{{- if not .Release.IsInstall -}}
  {{- /* Try to detect previous chart version from existing StatefulSet labels/annotations */ -}}
  {{- $prevVersion := "" -}}
  {{- $sts := lookup "apps/v1" "StatefulSet" .Release.Namespace (include "pmm.fullname" .) -}}
  {{- if $sts -}}
    {{- $labels := (index $sts "metadata" "labels" | default (dict)) -}}
    {{- $annotations := (index $sts "metadata" "annotations" | default (dict)) -}}
    {{- $tplLabels := (index $sts "spec" "template" "metadata" "labels" | default (dict)) -}}
    {{- $tplAnn := (index $sts "spec" "template" "metadata" "annotations" | default (dict)) -}}
    {{- $chartLabel := (index $labels "helm.sh/chart" 
                      | default (index $tplLabels "helm.sh/chart" 
                      | default (index $annotations "helm.sh/chart" 
                      | default (index $tplAnn "helm.sh/chart" | default "")))) -}}
    {{- if $chartLabel -}}
      {{- /* Extract semver (x.y.z with optional -prerelease or +build) from label */ -}}
      {{- $found := regexFind "[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z\\.-]+)?" $chartLabel -}}
      {{- if $found -}}
        {{- $prevVersion = $found -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
  {{- $prevVersion = (regexFind "^[0-9]+\\.[0-9]+\\.[0-9]+" (trim $prevVersion)) -}}
  {{- if and $prevVersion (semverCompare "<=1.4.1" $prevVersion) -}}
    {{- $shouldInclude = false -}}
  {{- end -}}
{{- end -}}
{{- if $shouldInclude -}}
namespace: {{ include "pmm.namespace" . }}
{{- end -}}
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
Create password if it does not exist or reuse existing one.
*/}}
{{- define "pmm.password" -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace .Values.secret.name -}}
{{- if and $secret $secret.data.PMM_ADMIN_PASSWORD -}}
{{ $secret.data.PMM_ADMIN_PASSWORD }}
{{- else -}}
{{ .Values.secret.pmm_password | default (randAscii 16) | b64enc }}
{{- end -}}
{{- end -}}
