{{/*
Expand the name of the chart.
*/}}
{{- define "pmm-ha-dependencies.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "pmm-ha-dependencies.fullname" -}}
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
{{- define "pmm-ha-dependencies.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "pmm-ha-dependencies.labels" -}}
helm.sh/chart: {{ include "pmm-ha-dependencies.chart" . }}
{{ include "pmm-ha-dependencies.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "pmm-ha-dependencies.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pmm-ha-dependencies.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Fail fast on OpenShift while the ClickHouse operator pins a uid: restricted-v2 refuses those pods,
and the CRD pre-install hook would otherwise just time out. VictoriaMetrics adapts on its own.
*/}}
{{- define "pmm-ha-dependencies.openshift.validate" -}}
{{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" -}}
{{- $ch := default dict (index .Values "altinity-clickhouse-operator") -}}
{{- $uids := dict
  "operator.containerSecurityContext.runAsUser" (dig "operator" "containerSecurityContext" "runAsUser" nil $ch)
  "metrics.containerSecurityContext.runAsUser" (dig "metrics" "containerSecurityContext" "runAsUser" nil $ch) -}}
{{- if dig "crdHook" "enabled" true $ch -}}
{{- $_ := set $uids "crdHook.podSecurityContext.runAsUser" (dig "crdHook" "podSecurityContext" "runAsUser" nil $ch) -}}
{{- end -}}
{{- $pinned := list -}}
{{- range $key := keys $uids | sortAlpha -}}
{{- if not (kindIs "invalid" (get $uids $key)) -}}
{{- $pinned = append $pinned (printf "altinity-clickhouse-operator.%s" $key) -}}
{{- end -}}
{{- end -}}
{{- if $pinned -}}
{{- fail (printf "This cluster exposes security.openshift.io/v1 (OpenShift), but these values pin a uid: %s. restricted-v2 rejects uids outside the namespace's assigned range, so those pods are never created and the install times out. Install with -f examples/values-openshift.yaml, or set them to null if you run with anyuid." (join ", " $pinned)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
