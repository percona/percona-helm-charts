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
{{- .Values.olm.namespaceOverride }}
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

{{- define "everest.versionMetadataURL" }}
{{- trimSuffix "/" (default "https://check.percona.com" .Values.versionMetadataURL) -}}
{{- end }}

{{- define "everest.tlsCerts" -}}
{{- $svcName := printf "everest" }}
{{- $svcNameWithNS := ( printf "%s.%s" $svcName (include "everest.namespace" .) ) }}
{{- $fullName := ( printf "%s.svc" $svcNameWithNS ) }}
{{- $altNames := list $svcName $svcNameWithNS $fullName }}
{{- $ca := genCA $svcName 3650 }}
{{- $cert := genSignedCert $fullName nil $altNames 3650 $ca }}
{{- $tlsCerts := .Values.server.tls.secret.certs }}
tls.key: {{ index $tlsCerts "tls.key" | default $cert.Key | b64enc }}
tls.crt: {{ index $tlsCerts "tls.crt" | default $cert.Cert | b64enc }}
{{- end }}

{{- define "everestOperator.tlsCerts" -}}
{{- $tlsCerts := .Values.operator.webhook.certs }}
{{- if (and (get $tlsCerts "tls.key" ) (get $tlsCerts "tls.crt") (get $tlsCerts "ca.crt") )}}
tls.key: {{ index $tlsCerts "tls.key" }}
tls.crt: {{ index $tlsCerts "tls.crt" }}
ca.crt: {{ index $tlsCerts "ca.crt" }}
{{- else }}
{{- $svcName := printf "everest-operator-webhook-service" }}
{{- $svcNameWithNS := ( printf "%s.%s" $svcName (include "everest.namespace" .) ) }}
{{- $fullName := ( printf "%s.svc" $svcNameWithNS ) }}
{{- $altNames := list $svcName $svcNameWithNS $fullName }}
{{- $ca := genCA $svcName 3650 }}
{{- $cert := genSignedCert $fullName nil $altNames 3650 $ca }}
tls.key: {{ $cert.Key | b64enc }}
tls.crt: {{ $cert.Cert | b64enc }}
ca.crt: {{ $ca.Cert | b64enc }}
{{- end }}
{{- end }}