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
{{/*
Roll the pods when the data source credentials change. They arrive through secretKeyRef, and
Kubernetes does not refresh environment variables in a running pod, so without this Grafana would
keep the old password after ClickHouse has already switched to the new one.
*/}}
checksum/clickhouse-datasource: {{ include (print $.Template.BasePath "/clickhouse-datasource-secret.yaml") . | sha256sum }}
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
Generate PMM HA peer list dynamically based on replicas count
*/}}
{{- define "pmm.haPeers" -}}
{{- $peers := list }}
{{- $serviceName := .Values.service.name | default "monitoring-service" }}
{{- $replicas := int .Values.replicas }}
{{- range $i := until $replicas }}
  {{- $peer := printf "%s-%d.%s.%s.svc.cluster.local" $.Release.Name $i $serviceName $.Release.Namespace }}
  {{- $peers = append $peers $peer }}
{{- end }}
{{- join "," $peers }}
{{- end -}}


{{/*
Generate comma-separated list of ClickHouse pod FQDNs (without port)

NOTE: This naming pattern is defined by the ClickHouse Operator (Altinity).
Reference: https://github.com/Altinity/clickhouse-operator/blob/master/pkg/model/chi/namer/patterns.go
Pattern: chi-{chi}-{cluster}-{shard}-{replica}.{namespace}.svc.cluster.local
Where:
  - chi = ClickHouseInstallation CR name (Release.Name)
  - cluster = cluster name from spec.configuration.clusters[].name
  - shard = shard index (0-based)
  - replica = replica index (0-based)

Example output: chi-pmm-ha-bela-pmm-clickhouse-0-0.pmm-ha-dafasief.svc.cluster.local,chi-pmm-ha-bela-pmm-clickhouse-0-1.pmm-ha-dafasief.svc.cluster.local

Alternative discovery: PMM can query ClickHouse system.clusters table at runtime for dynamic node discovery.
*/}}
{{- define "pmm.clickhouse.nodes" -}}
{{- $nodes := list -}}
{{- range $shardIndex := until (int .Values.clickhouse.cluster.shards) -}}
{{- range $replicaIndex := until (int $.Values.clickhouse.cluster.replicas) -}}
{{- $nodeFQDN := printf "chi-%s-%s-%d-%d.%s.svc.cluster.local" $.Release.Name $.Values.clickhouse.cluster.name $shardIndex $replicaIndex $.Release.Namespace -}}
{{- $nodes = append $nodes $nodeFQDN -}}
{{- end -}}
{{- end -}}
{{- join "," $nodes -}}
{{- end -}}

{{/*
Generate ClickHouse Keeper nodes list dynamically based on replicasCount

NOTE: This naming pattern is defined by the ClickHouse Keeper Operator (Altinity).
Reference: https://github.com/Altinity/clickhouse-keeper-operator
Pattern: chk-{name}-{cluster}-0-{replica}.{namespace}.svc.cluster.local
Where:
  - name = ClickHouseKeeperInstallation CR name (Release.Name-keeper)
  - cluster = keeper cluster name from spec.configuration.clusters[].name
  - replica = replica index (0-based)

Example output for 3 replicas:
  - host: chk-pmm-ha-keeper-keeper-nodes-0-0.pmm-ha.svc.cluster.local
    port: 2181
  - host: chk-pmm-ha-keeper-keeper-nodes-0-1.pmm-ha.svc.cluster.local
    port: 2181
*/}}
{{- define "pmm.clickhouse.keeper.nodes" -}}
{{- $keeperClusterName := .Values.clickhouse.keeper.cluster.name -}}
{{- $replicasCount := int .Values.clickhouse.keeper.replicasCount -}}
{{- range $replicaIndex := until $replicasCount }}
- host: chk-{{ $.Release.Name }}-keeper-{{ $keeperClusterName }}-0-{{ $replicaIndex }}.{{ $.Release.Namespace }}.svc.cluster.local
  port: 2181
{{- end -}}
{{- end -}}

{{/*
Name of the PMM Client StatefulSet
*/}}
{{- define "pmm.client.fullname" -}}
{{- printf "%s-client" (include "pmm.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels of the PMM Client pods. They must differ from the PMM Server ones, otherwise the
Client pods would be picked up by the PMM Server service and join the HA peer discovery.
*/}}
{{- define "pmm.client.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pmm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: pmm-client
app.kubernetes.io/part-of: percona-platform
{{- end -}}

{{/*
Common labels of the PMM Client resources
*/}}
{{- define "pmm.client.labels" -}}
helm.sh/chart: {{ include "pmm.chart" . }}
{{ include "pmm.client.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
PMM Server address reachable from inside the cluster. HAProxy routes to the current leader, so this
stays valid across failovers.
*/}}
{{- define "pmm.client.serverAddress" -}}
{{- $haproxy := .Values.haproxy.fullnameOverride | default (printf "%s-haproxy" (include "pmm.fullname" .)) -}}
{{- printf "%s.%s.svc.cluster.local:443" $haproxy .Release.Namespace -}}
{{- end -}}

{{/*
Base directory of the PMM Client installation inside the image. It holds the exporters and tools, so
only the subdirectories which have to survive a restart are backed by a volume: "config" keeps the
Agent identity, "tmp" keeps the on-disk queue vmagent fills while PMM Server is unreachable.
*/}}
{{- define "pmm.client.baseDir" -}}
/usr/local/percona/pmm
{{- end -}}

{{/*
Environment shared by the PMM Client container and the init container which registers it.
Credentials are deliberately not part of it, see pmm-client-statefulset.yaml.
The temporary directory is left at its default, which is "tmp" under the base directory.
*/}}
{{- define "pmm.client.env" -}}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
- name: PMM_AGENT_CONFIG_FILE
  value: {{ include "pmm.client.baseDir" . }}/config/pmm-agent.yaml
- name: PMM_AGENT_SERVER_ADDRESS
  value: {{ include "pmm.client.serverAddress" . }}
- name: PMM_AGENT_SERVER_INSECURE_TLS
  value: "1"
- name: PMM_AGENT_LISTEN_ADDRESS
  value: 0.0.0.0
- name: PMM_AGENT_LISTEN_PORT
  value: "7777"
- name: PMM_AGENT_SETUP_NODE_TYPE
  value: container
- name: PMM_AGENT_SETUP_NODE_NAME
  value: $(POD_NAMESPACE)-$(POD_NAME)
- name: PMM_AGENT_SETUP_NODE_ADDRESS
  value: $(POD_IP)
- name: PMM_AGENT_SETUP_METRICS_MODE
  value: push
{{- end -}}

{{/*
Volume mounts backing the PMM Client directories which have to survive a restart
*/}}
{{- define "pmm.client.volumeMounts" -}}
- name: pmm-agent
  mountPath: {{ include "pmm.client.baseDir" . }}/config
  subPath: config
- name: pmm-agent
  mountPath: {{ include "pmm.client.baseDir" . }}/tmp
  subPath: tmp
{{- end -}}

{{- define "pmm.nodeExporter.mode" -}}
{{- (.Values.nodeExporter).mode | default "internal" -}}
{{- end -}}

{{/*
Whether the bundled prometheus-node-exporter DaemonSet will render ("true"/"false").
Like Helm's `condition:`, only a boolean false disables the subchart.
*/}}
{{- define "pmm.nodeExporter.bundledEnabled" -}}
{{- $v := dig "enabled" true (default dict (index .Values "prometheus-node-exporter")) -}}
{{- if and (kindIs "bool" $v) (not $v) }}false{{ else }}true{{ end }}
{{- end -}}

{{/*
Fail-fast validation for the internal/openshift node-exporter toggle.
Called from statefulset.yaml, which always renders.
*/}}
{{- define "pmm.nodeExporter.validate" -}}
{{- $mode := include "pmm.nodeExporter.mode" . -}}
{{- if not (or (eq $mode "internal") (eq $mode "openshift")) -}}
{{- fail (printf "nodeExporter.mode must be \"internal\" or \"openshift\", got %q" $mode) -}}
{{- end -}}
{{- if eq $mode "openshift" -}}
{{- if eq (include "pmm.nodeExporter.bundledEnabled" .) "true" -}}
{{- fail "nodeExporter.mode=openshift requires prometheus-node-exporter.enabled=false: the bundled DaemonSet would collide with OpenShift's node-exporter on host port 9100." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Target labels shared by both node-exporter scrape jobs. PMM's OS dashboards filter on node_name
and node_type ("generic" is PMM's type for a bare host), so without these the node is invisible there.
Emitted unindented; callers nindent it to their relabel_configs item level.
*/}}
{{- define "pmm.nodeExporter.pmmRelabelConfigs" -}}
- source_labels: [__meta_kubernetes_pod_node_name]
  target_label: node
- source_labels: [__meta_kubernetes_pod_node_name]
  target_label: node_name
- target_label: node_type
  replacement: generic
- source_labels: [__meta_kubernetes_namespace]
  target_label: namespace
- source_labels: [__meta_kubernetes_pod_name]
  target_label: pod
{{- end -}}

{{/*
OpenShift node-exporter scrape job for the VMAgent inlineScrapeConfig.
Emits an unindented job (callers nindent it under inlineScrapeConfig). Only used
when nodeExporter.mode == "openshift".
*/}}
{{- define "pmm.nodeExporter.openshiftScrapeJob" -}}
# OpenShift platform node-exporter, scraped via its kube-rbac-proxy (SA-token auth).
# server_name: the proxy's cert covers the service DNS name, not the node IP endpoints SD targets.
- job_name: 'openshift-node-exporter'
  scheme: https
  bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  tls_config:
    ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
    server_name: node-exporter.openshift-monitoring.svc
  kubernetes_sd_configs:
    - role: endpoints
      namespaces:
        names:
          - openshift-monitoring
  relabel_configs:
    - source_labels: [__meta_kubernetes_service_name]
      regex: 'node-exporter'
      action: keep
    - source_labels: [__meta_kubernetes_endpoint_port_name]
      regex: 'https'
      action: keep
    {{- include "pmm.nodeExporter.pmmRelabelConfigs" . | nindent 4 }}
{{- end -}}

{{/*
Name of the chart-managed secret holding the read-only ClickHouse data source credentials.

Kept apart from .Values.secret.name because that secret is user-managed by default, and these
credentials are internal: the chart creates the ClickHouse user itself, so nobody has to supply
them.
*/}}
{{- define "pmm.clickhouse.datasourceSecretName" -}}
{{- printf "%s-clickhouse-datasource" (include "pmm.fullname" .) -}}
{{- end -}}

{{/*
Username of the read-only ClickHouse user backing the Grafana data source.

Grafana runs data source queries on behalf of every signed-in user, including Viewers, so this
must not be the user PMM writes Query Analytics data with.
*/}}
{{- define "pmm.clickhouse.datasourceUser" -}}
{{- .Values.clickhouse.datasource.user | default "clickhouse_pmm_readonly" -}}
{{- end -}}

{{/*
Password of the read-only ClickHouse data source user.

The secret hands the plaintext to PMM while the ClickHouse drop-in needs its SHA-256, so both
have to agree. A generated password is therefore memoised on .Values: randAlphaNum would
otherwise return a different value to each caller and leave Grafana unable to authenticate.
Once generated it is read back from the chart-managed secret, so upgrades keep the same value.
*/}}
{{- define "pmm.clickhouse.datasourcePassword" -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "pmm.clickhouse.datasourceSecretName" .)) -}}
{{- if .Values.clickhouse.datasource.password -}}
{{- .Values.clickhouse.datasource.password -}}
{{- else if and $existing (index $existing.data "PMM_CLICKHOUSE_DATASOURCE_PASSWORD") -}}
{{- index $existing.data "PMM_CLICKHOUSE_DATASOURCE_PASSWORD" | b64dec -}}
{{- else -}}
{{- if not (hasKey .Values "generatedClickhouseDatasourcePassword") -}}
{{- $_ := set .Values "generatedClickhouseDatasourcePassword" (randAlphaNum 32) -}}
{{- end -}}
{{- get .Values "generatedClickhouseDatasourcePassword" -}}
{{- end -}}
{{- end -}}

{{/*
Reject a ClickHouse identifier that would not survive being written into the users.d drop-in.

The data source username becomes an XML element name and the database name goes into a GRANT
statement, so neither may start with a digit nor carry characters outside the safe set. Takes a
dict with "name" and "value".
*/}}
{{- define "pmm.clickhouse.validateIdentifier" -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_-]*$" .value) -}}
{{- fail (printf "%s must match ^[A-Za-z_][A-Za-z0-9_-]*$ to be usable in the ClickHouse users.d drop-in, got %q" .name .value) -}}
{{- end -}}
{{- end -}}
