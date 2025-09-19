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
HAProxy init container script
This creates the init container script that waits for PMM instances
*/}}
{{- define "haproxy.initContainerScript" -}}
set -euo pipefail

echo "HAProxy init: Waiting for PMM instances to be ready..."
echo "Current namespace: {{ .Release.Namespace }}"
echo "Expected PMM replicas: {{ .Values.replicas }}"

# Install curl for health checks
apk add --no-cache curl > /dev/null 2>&1

# Function to check if a PMM instance is ready
check_pmm_ready() {
  local pmm_host="$1"
  local pmm_port="$2"
  local timeout="${3:-10}"
  
  echo "Checking PMM instance: $pmm_host:$pmm_port"
  
  # Try HTTP first, then HTTPS
  if curl -s --max-time "$timeout" --fail "http://$pmm_host:$pmm_port/v1/readyz" > /dev/null 2>&1; then
    echo "✅ HTTP health check passed for $pmm_host:$pmm_port"
    return 0
  elif curl -s --max-time "$timeout" --fail -k "https://$pmm_host:$pmm_port/v1/readyz" > /dev/null 2>&1; then
    echo "✅ HTTPS health check passed for $pmm_host:$pmm_port"
    return 0
  else
    echo "❌ Health check failed for $pmm_host:$pmm_port"
    return 1
  fi
}

# Wait for all PMM instances to be ready
max_attempts=60  # 5 minutes with 5-second intervals
attempt=1

while [ $attempt -le $max_attempts ]; do
  echo "Attempt $attempt/$max_attempts: Checking PMM instances..."
  
  all_ready=true
  ready_count=0
  
  # Check each PMM instance
  for i in $(seq 0 $(({{ .Values.replicas }} - 1))); do
    pmm_host="{{ .Release.Name }}-$i.monitoring-service.{{ .Release.Namespace }}.svc.cluster.local"
    
    if check_pmm_ready "$pmm_host" "8080" 5; then
      ready_count=$((ready_count + 1))
      echo "✅ Instance $i is ready ($ready_count/{{ .Values.replicas }})"
    else
      echo "❌ Instance $i is not ready yet"
      all_ready=false
    fi
  done
  
  echo "Ready instances: $ready_count/{{ .Values.replicas }}"
  
  if [ "$all_ready" = true ]; then
    echo "🎉 All PMM instances are ready! HAProxy can now start."
    exit 0
  fi
  
  echo "⏳ Not all PMM instances are ready yet. Waiting 5 seconds..."
  sleep 5
  attempt=$((attempt + 1))
done

echo "❌ Timeout: PMM instances did not become ready within 5 minutes"
echo "This may indicate an issue with PMM deployment"
exit 1
{{- end -}}

