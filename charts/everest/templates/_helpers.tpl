{{/*
Expand the name of the chart.
*/}}
{{- define "chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Allows overriding the install namespace in combined charts.
*/}}
{{- define "everest.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Allow overriding OLM namespace
*/}}
{{- define "everest.olmNamespace"}}
{{- if .Values.compatibility.openshift }}
{{- "openshift-marketplace" }}
{{- else }}
{{- .Values.olm.namespace }}
{{- end }}
{{- end }}
 
{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "chart.fullname" -}}
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
{{- define "chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "chart.labels" -}}
helm.sh/chart: {{ include "chart.chart" . }}
{{ include "chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "chart.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "chart.everestAdminAccount" }}
admin:
  passwordHash: {{ randAlphaNum 64 }}
  enabled: true
  capabilities:
    - login
{{- end}}

{{- define "olm.certs" }}
{{- $tls := .Values.olm.packageserver.tls }}
{{- $psSvcName := printf "packageserver-service" }}
{{- $psSvcNameWithNS := ( printf "%s.%s" $psSvcName .Values.olm.namespace ) }}
{{- $psFullName := ( printf "%s.svc" $psSvcNameWithNS ) }}
{{- $psAltNames := list $psSvcName $psSvcNameWithNS $psFullName }}
{{- $psCA := genCA $psSvcName 3650 }}
{{- $psCert := genSignedCert $psFullName nil $psAltNames 3650 $psCA }}
{{- if (and $tls.caCert $tls.tlsCert $tls.tlsKey) }}
caCert: {{ $tls.caCert | b64enc }}
tlsCert: {{ $tls.tlsCert | b64enc }}
tlsKey: {{ $tls.tlsKey | b64enc }}
{{- else }}
caCert: {{ $psCA.Cert | b64enc }}
tlsCert: {{ $psCert.Cert | b64enc }}
tlsKey: {{ $psCert.Key | b64enc }}
{{- end }}
commonName: {{ $psSvcName }}
altNames:
{{- range $n := $psAltNames }}
- {{ $n }}
{{- end }}
- localhost
{{- end }}
