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
Generate PMM HA peer list dynamically based on replicas count.

The hostnames must match the StatefulSet's pods, which are named after pmm.fullname -
NOT after .Release.Name. The two are equal only when the release name already contains
the chart name (the "pmm-ha" that every example uses); for any other release name,
building peers from .Release.Name yields hostnames that resolve to nothing and Raft
never forms a quorum.
*/}}
{{- define "pmm.haPeers" -}}
{{- $peers := list }}
{{- $fullname := include "pmm.fullname" . }}
{{- $serviceName := .Values.service.name | default "monitoring-service" }}
{{- $replicas := int .Values.replicas }}
{{- range $i := until $replicas }}
  {{- $peer := printf "%s-%d.%s.%s.svc.cluster.local" $fullname $i $serviceName $.Release.Namespace }}
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
The number of HAProxy server-template slots, and therefore the ceiling on replicas.
Shared by haproxy-configmap.yaml (which renders it) and pmm.replicas.validate (which
enforces it) so the two can never disagree about the default.

kindIs "invalid" rather than `default`, because sprig's `default` treats 0 as empty:
with it, maxReplicas=0 would silently become 10 and the range check below could never
see it.
*/}}
{{- define "pmm.maxReplicas" -}}
{{- if kindIs "invalid" .Values.maxReplicas -}}10{{- else -}}{{- .Values.maxReplicas -}}{{- end -}}
{{- end -}}

{{/*
Shared parity check for the chart's two Raft ensembles - PMM itself and ClickHouse
Keeper. Raft elects a leader by majority, so an even count needs more votes to elect
one without surviving more failures (4 tolerates a single loss, exactly like 3), and a
count of 2 tolerates none at all.

Takes a dict of:
  name     - the values key, used verbatim in every message
  value    - the raw value, validated before it is parsed
  ceiling  - largest permitted value, or 0 for unbounded. The "use N instead" hint is
             clamped to it so it never names a value a later check would reject.
  ceilingName - the values key the ceiling comes from, so the hint can name it.

The regex is deliberately strict. sprig's `int` parses base 0, so "010" would silently
become 8; and anything wider than int64 overflows to 0. Either way the message would
quote a number the user never typed, so both are rejected as malformed input instead.
*/}}
{{- define "pmm.validate.oddCount" -}}
{{- $name := .name -}}
{{- $raw := .value -}}
{{- if not (regexMatch "^[1-9][0-9]{0,3}$" (toString $raw)) -}}
{{- fail (printf "%s must be a whole number between 1 and 9999, got %v." $name $raw) -}}
{{- end -}}
{{- $n := int $raw -}}
{{- if eq (mod $n 2) 0 -}}
{{- $ceiling := int (.ceiling | default 0) -}}
{{- $lower := sub $n 1 -}}
{{- $upper := add $n 1 -}}
{{- $hint := printf "Use %d or %d." $lower $upper -}}
{{- if gt $ceiling 0 -}}
{{- $maxOdd := $ceiling -}}
{{- if eq (mod $ceiling 2) 0 -}}
{{- $maxOdd = sub $ceiling 1 -}}
{{- end -}}
{{- if le $upper $maxOdd -}}
{{- $hint = printf "Use %d or %d." $lower $upper -}}
{{- else if le $lower $maxOdd -}}
{{- $hint = printf "Use %d." $lower -}}
{{- else -}}
{{- $hint = printf "%s is %d, so the largest supported value is %d." (.ceilingName | default "The ceiling") $ceiling $maxOdd -}}
{{- end -}}
{{- end -}}
{{- fail (printf "%s must be odd so Raft can form a quorum, got %d: an even count needs more votes to elect a leader without surviving more failures. %s" $name $n $hint) -}}
{{- end -}}
{{- end -}}

{{/*
Fail-fast validation for the PMM replica count.
Called from statefulset.yaml, which always renders and reaches these checks before the
lookup in pg-user-credentials-secrets.yaml, so a plain `helm template` reports the real
problem rather than a missing secret.

HAProxy discovers PMM through a server-template with maxReplicas slots
(haproxy-configmap.yaml), fills them from a headless-service DNS answer in arbitrary
order, and marks a backend UP only when it answers /v1/server/leaderHealthCheck with
200. Going above maxReplicas is therefore not merely under-routing: if the Raft leader
lands on a pod that got no slot, every backend is DOWN and PMM serves 503.
*/}}
{{- define "pmm.replicas.validate" -}}
{{- $maxRaw := include "pmm.maxReplicas" . -}}
{{- if not (regexMatch "^([1-9][0-9]?|100)$" $maxRaw) -}}
{{- fail (printf "maxReplicas must be a whole number between 1 and 100, got %v: it is rendered verbatim into the HAProxy server-template, and every slot is a backend server allocated at startup." $maxRaw) -}}
{{- end -}}
{{- $maxReplicas := int $maxRaw -}}
{{- include "pmm.validate.oddCount" (dict "name" "replicas" "value" .Values.replicas "ceiling" $maxReplicas "ceilingName" "maxReplicas") -}}
{{- $replicas := int .Values.replicas -}}
{{- if gt $replicas $maxReplicas -}}
{{- fail (printf "replicas (%d) exceeds maxReplicas (%d): HAProxy renders only %d server-template slots and fills them from DNS in arbitrary order, so a pod left without a slot is invisible to it. Because HAProxy marks a backend UP only when it answers /v1/server/leaderHealthCheck, a Raft leader on that pod leaves every backend DOWN and PMM serves 503. Lower replicas, or raise maxReplicas and bump haproxy.podAnnotations \"pmm.percona.com/config-version\" in the same upgrade so HAProxy restarts with the new server-template." $replicas $maxReplicas $maxReplicas) -}}
{{- end -}}
{{- end -}}

{{/*
Fail-fast validation for the ClickHouse Keeper node count.
Called from statefulset.yaml alongside the other value checks, for the same ordering
reason described above.

The parenthesised lookup matches pmm.nodeExporter.mode: without it, a nulled clickhouse
or clickhouse.keeper key aborts with a raw Go nil-pointer error instead of the message
this validator exists to produce.
*/}}
{{- define "pmm.keeper.validate" -}}
{{- include "pmm.validate.oddCount" (dict "name" "clickhouse.keeper.replicasCount" "value" ((.Values.clickhouse).keeper).replicasCount) -}}
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
