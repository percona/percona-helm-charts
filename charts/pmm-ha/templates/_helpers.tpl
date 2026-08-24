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
Generate PMM HA peer list dynamically based on replicas count
*/}}
{{- define "pmm.haPeers" -}}
{{- $peers := list }}
{{- $serviceName := .Values.service.name | default "monitoring-service" }}
{{- $replicas := int .Values.replicas }}
{{- $fullname := include "pmm.fullname" . }}
{{- range $i := until $replicas }}
  {{- /* Peers must use the StatefulSet name (pmm.fullname), not Release.Name: the pods are
         <fullname>-<ordinal>. pmm.fullname equals Release.Name only when the release name
         already contains the chart name (e.g. "pmm-ha" or "pmm-ha-2"); otherwise it is
         "<release>-pmm-ha" (e.g. release "pmm-2" -> pods "pmm-2-pmm-ha-0"). Using
         Release.Name for those releases yields peers that don't resolve and the HA
         memberlist panics on startup. */}}
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
Central backup RWX/NFS volume (shared mode). Renders a single pod-spec volume entry named
"central-backup-storage" referencing the same NFS/PVC as the backup-tools pod. Mounted at
.Values.centralBackupStorage.sharedMountPath inside the component pods so each tool writes its
backup straight to the shared volume. Call with the root context: {{- include "pmm.centralBackupVolume" . }}
*/}}
{{- define "pmm.centralBackupVolume" -}}
- name: central-backup-storage
{{- if .Values.centralBackupStorage.nfs.enabled }}
  nfs:
    server: {{ .Values.centralBackupStorage.nfs.server }}
    path: {{ .Values.centralBackupStorage.nfs.path }}
{{- else }}
  persistentVolumeClaim:
    claimName: {{ .Values.centralBackupStorage.existingClaim | default (printf "%s-central-backup" .Release.Name) }}
{{- end }}
{{- end -}}

{{/*
Name of the key inside an S3 credentials Secret. Collapses the
`(<s3>.existingSecretKeys | default dict).accessKey | default "access-key"` idiom that the
pmm-backup, vmbackup and clickhouse-backup sidecars each hand-copy. Call with the keys dict
(may be nil) and which credential is wanted:
  {{ include "pmm.s3SecretKeyName" (dict "keys" $s3.existingSecretKeys "which" "access") }}
  {{ include "pmm.s3SecretKeyName" (dict "keys" $s3.existingSecretKeys "which" "secret") }}
*/}}
{{- define "pmm.s3SecretKeyName" -}}
{{- $keys := .keys | default dict -}}
{{- if eq .which "access" -}}
{{- $keys.accessKey | default "access-key" -}}
{{- else -}}
{{- $keys.secretKey | default "secret-key" -}}
{{- end -}}
{{- end -}}

{{/*
Name of the backup S3 ServiceAccount (used by vmstorage/ClickHouse for the IRSA credential chain
and referenced by the restore temp pods). Release-scoped by default so two releases in the same
namespace don't collide on one fixed SA (Helm ownership conflict on install, and uninstall of one
release deleting the SA the other still uses). Override via centralBackupStorage.s3.serviceAccountName.
*/}}
{{- define "pmm.backupS3SaName" -}}
{{- .Values.centralBackupStorage.s3.serviceAccountName | default (printf "%s-backup-s3" .Release.Name) -}}
{{- end -}}

{{/*
S3 key root for THIS install: <namespace>/<prefix>.

Every S3 path the backup and restore tooling builds hangs off this — <component>/<id>/ and
clickhouse/... — so it is the one place that decides which keys an install owns.

Why the namespace leads the path: retention deletes by AGE under the root it is given and
cannot tell whose backup an id is, so two installs sharing a root delete each other's
backups (irreversibly, on a bucket without versioning). The prefix alone does not prevent
that, because it defaults to the same literal "pmm-ha" for every install — so two namespaces
on one cluster collide unless the operator intervenes. Leading with .Release.Namespace makes
that case safe automatically, while keeping the prefix configurable for the case the
namespace cannot solve: the same namespace name on two DIFFERENT clusters sharing one bucket
(namespaces are cluster-scoped, and no cluster identity is readable from the chart's
namespaced RBAC). Set a distinct prefix per cluster for that topology.

Namespace first also keeps the bucket human-navigable and DR-discoverable: the path names the
install, so a restore can be pointed at a source (--s3-prefix <ns>/<prefix>) without querying
the source cluster, which in a real disaster may be gone.
*/}}
{{- define "pmm.backupS3Root" -}}
{{- $prefix := .Values.centralBackupStorage.s3.prefix | default "pmm-ha" | trimPrefix "/" | trimSuffix "/" -}}
{{- printf "%s/%s" .Release.Namespace $prefix -}}
{{- end -}}

{{/*
The relabel rules that scope a backup-metrics scrape job to THIS release's backup-tools pod.
Defined once because five scrape jobs need it and a divergence between them is invisible until
two releases share a namespace — a topology this chart supports (the backup SA and the central
PVC are both release-scoped for it).

regexQuoteMeta on the release name matters: Prometheus anchors relabel regexes but does not
escape them, so an unescaped release called `pmm.prod` would also keep a co-located `pmmXprod`
release's pods — reintroducing the cross-release mixing this rule exists to stop.
*/}}
{{- define "pmm.backupToolsScrapeKeep" -}}
- source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_component]
  regex: 'backup-tools'
  action: keep
- source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_instance]
  regex: '{{ regexQuoteMeta .Release.Name }}'
  action: keep
{{- end -}}
