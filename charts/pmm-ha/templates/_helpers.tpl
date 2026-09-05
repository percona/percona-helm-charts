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
Kept as a named template even though one job uses it today: the rule is subtle (an unescaped
release name in a regex silently keeps another release's pods) and it belongs somewhere a second
job can reuse rather than copy. Two releases in one namespace is a topology this chart supports —
the backup SA and the central PVC are both release-scoped for it.

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

{{/*
Environment for a backup/restore RUN of pmm-backup.sh — the single definition of how the
orchestrator learns this install's target (shared mount or S3 coordinates + credentials).
Consumed by the backup-tools Deployment (manual/interactive runs), the backup CronJob's
jobTemplate (scheduled runs) — and, through `kubectl create job --from`, every manual backup
and restore cloned from it. (examples/restore-job.yaml's standalone fallback is NOT a consumer:
it is a static file, cannot include a helper, and hand-copies a shared-mode-only subset — which
is exactly why that file steers operators to the clone instead.) These were one hand-copied
block per consumer before PMM-13858 moved scheduled runs into Jobs; env drift between the
Deployment and the Job would make a manual run and a scheduled run write to different
places, which is exactly the class of bug the S3_PREFIX composition comment below warns
about. Call with the root context and nindent to the env list's indent:
  {{- include "pmm.backupRunEnv" . | nindent 10 }}
*/}}
{{- define "pmm.backupRunEnv" -}}
- name: NAMESPACE
  value: {{ .Release.Namespace }}
{{- /* Lets the orchestrator scope its backup-tools selector to THIS release: two pmm-ha
       installs can share a namespace, and an unscoped selector can resolve the other one's
       central backup volume. See LABEL_BACKUP_TOOLS in files/pmm-backup.sh. */}}
- name: RELEASE_NAME
  value: {{ .Release.Name }}
- name: BACKUP_DIR
  value: {{ .Values.centralBackupStorage.mountPath }}
- name: METRICS_DIR
  value: {{ .Values.centralBackupStorage.mountPath }}/.metrics
# Backup target + S3 settings the chart already knows, projected as env so
# pmm-backup.sh (restore and manual backup runs) defaults to THIS
# install rather than requiring every --target/--s3-* flag to be re-typed — a
# forgotten --s3-secret otherwise makes a static-key restore schedule temp pods
# under a non-existent SA and fail at admission mid-restore. Flags still override.
- name: BACKUP_TARGET
  value: {{ .Values.centralBackupStorage.mode | quote }}
{{- if eq .Values.centralBackupStorage.mode "shared" }}
- name: SHARED_MOUNT_PATH
  value: {{ .Values.centralBackupStorage.sharedMountPath | quote }}
{{- else }}
- name: S3_BUCKET
  value: {{ .Values.centralBackupStorage.s3.bucket | quote }}
- name: S3_REGION
  value: {{ .Values.centralBackupStorage.s3.region | quote }}
{{- /* <namespace>/<prefix> — see the "pmm.backupS3Root" helper for why the
       namespace leads. The scripts treat S3_PREFIX as an opaque key prefix, so a
       multi-segment value needs no change on their side. */}}
- name: S3_PREFIX
  value: {{ include "pmm.backupS3Root" . | quote }}
- name: S3_PROVIDER
  value: {{ .Values.centralBackupStorage.s3.provider | default "AWS" | quote }}
{{- /* Defines the `s3:` remote the orchestrator addresses as s3:<bucket>/<prefix>.
       Same variable set that render_rclone_s3_env() puts in the temp restore pods,
       so there is one definition of what "the s3 remote" means. */}}
- name: RCLONE_CONFIG_S3_TYPE
  value: "s3"
- name: RCLONE_CONFIG_S3_PROVIDER
  value: {{ .Values.centralBackupStorage.s3.provider | default "AWS" | quote }}
- name: RCLONE_CONFIG_S3_ENV_AUTH
  value: "true"
- name: RCLONE_CONFIG_S3_REGION
  value: {{ .Values.centralBackupStorage.s3.region | quote }}
- name: RCLONE_CONFIG_S3_NO_CHECK_BUCKET
  value: "true"
{{- with .Values.centralBackupStorage.s3.endpoint }}
- name: RCLONE_CONFIG_S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- /* Static keys: env_auth=true above makes rclone read these. On the IRSA path
       there are no keys and the SA's web-identity token is used instead. */}}
{{- with .Values.centralBackupStorage.s3.existingSecret }}
- name: AWS_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "access") }}
- name: AWS_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ . }}
      key: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "secret") }}
{{- end }}
{{- with .Values.centralBackupStorage.s3.endpoint }}
- name: S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- /* VictoriaMetrics may point at a DIFFERENT endpoint than everything else
       (victoriaMetrics.vmstorage.backup.s3.endpoint). vmbackup/vmrestore accept it
       only as -customS3Endpoint, and this pod is what invokes them, so the effective
       value is resolved here rather than as an env var on the sidecar that no tool
       reads. Only emitted when it actually differs from S3_ENDPOINT. */}}
{{- $vmEndpoint := .Values.victoriaMetrics.vmstorage.backup.s3.endpoint | default .Values.centralBackupStorage.s3.endpoint }}
{{- if and $vmEndpoint (ne $vmEndpoint .Values.centralBackupStorage.s3.endpoint) }}
- name: VM_S3_ENDPOINT
  value: {{ $vmEndpoint | quote }}
{{- end }}
{{- with .Values.centralBackupStorage.s3.existingSecret }}
- name: S3_SECRET_NAME
  value: {{ . | quote }}
- name: S3_SECRET_ACCESS_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "access") | quote }}
- name: S3_SECRET_SECRET_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "secret") | quote }}
{{- end }}
{{- /* Only project the SA name when the chart actually CREATES that SA (i.e. IRSA is
       configured — see backup-s3-serviceaccount.yaml, same condition). Otherwise the
       restore temp pods would set serviceAccountName to a non-existent SA and be rejected
       at admission mid-restore (with PMM/VM already scaled to 0). Ambient-credential
       installs leave this empty and the temp pods use the namespace default SA. */}}
{{- if .Values.centralBackupStorage.s3.irsaRoleArn }}
- name: S3_SERVICE_ACCOUNT
  value: {{ include "pmm.backupS3SaName" . | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
ServiceAccount a backup/restore RUN executes under. On the IRSA path the run needs S3
credentials of its own, and the S3 SA is the one the role's trust policy names; otherwise the
plain backup SA. The RoleBinding binds BOTH, so the backup RBAC follows either way.

ONE definition: the Deployment and every Job pod must agree, or scheduled runs execute under a
different identity than interactive ones — which shows up as S3 403s that only happen at night.
*/}}
{{- define "pmm.backupRunSaName" -}}
{{- if and (eq .Values.centralBackupStorage.mode "s3") .Values.centralBackupStorage.s3.irsaRoleArn -}}
{{- include "pmm.backupS3SaName" . -}}
{{- else -}}
{{- printf "%s-backup-sa" .Release.Name -}}
{{- end -}}
{{- end -}}

{{/*
The labels that IDENTIFY the backup-tools pod. Used as the Deployment's selector and pod
labels, and as the backup Job's podAffinity matchLabels. Keeping them in one place is what
stops a future label change from silently turning the Job's REQUIRED affinity into a selector
that matches nothing — which would leave every scheduled run Pending until its deadline.
(pmm.backupToolsScrapeKeep expresses the same identity for vmagent's scrape job.)
*/}}
{{/*
Object/pod labels for a backup object, with app.kubernetes.io/component set to the given value.
Called as `(list . "backup-tools")`.

pmm.labels goes through pmm.selectorLabels, which hardcodes `component: pmm-server`. Emitting
that and then overriding it on the next line produced a DUPLICATE YAML key in every backup
object — it worked only because Helm's decoder keeps the last occurrence, while a strict decoder
(`kubectl apply --validate=strict`, some GitOps engines) rejects the manifest outright, and a
future reordering of the two lines would silently break both the Deployment's
selector.matchLabels and the Job's podAffinity (leaving every scheduled run Pending).

So the value is REPLACED in the rendered string rather than shadowed by a second key. Rendering
through pmm.labels keeps .Values.extraLabels and the chart/version/managed-by labels in one
place, and the `fail` below means a change to pmm.selectorLabels breaks the build instead of
silently mislabelling every backup object.
*/}}
{{- define "pmm.componentLabels" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- $out := include "pmm.labels" $root -}}
{{- /* Fail the render rather than emit the wrong component. A silent no-op here would put
       `component: pmm-server` on the backup Deployment while its selector (and the Job's
       podAffinity) still look for backup-tools — every scheduled run would sit Pending until
       its deadline, which is far worse than a build error. */}}
{{- if not (contains "app.kubernetes.io/component: pmm-server" $out) -}}
{{- fail "pmm.componentLabels: pmm.labels no longer emits 'app.kubernetes.io/component: pmm-server' — update this helper" -}}
{{- end -}}
{{- $out | replace "app.kubernetes.io/component: pmm-server" (printf "app.kubernetes.io/component: %s" $component) -}}
{{- end -}}

{{- define "pmm.backupToolsSelectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backup-tools
{{- end -}}

{{/*
The chart-shipped scripts, as a pod volume. subPath mounts keep the rest of /usr/local/bin
intact, so both scripts resolve via PATH.
*/}}
{{- define "pmm.backupScriptsVolume" -}}
- name: backup-scripts
  configMap:
    name: {{ .Release.Name }}-backup-scripts
    defaultMode: 0555
{{- end -}}

{{- define "pmm.backupScriptsMounts" -}}
- name: backup-scripts
  mountPath: /usr/local/bin/pmm-backup.sh
  subPath: pmm-backup.sh
- name: backup-scripts
  mountPath: /usr/local/bin/backup-entrypoint.sh
  subPath: backup-entrypoint.sh
{{- end -}}

{{/*
Resources for a process running the orchestrator. The Deployment and the Job pods run the very
same code, so they get the same sizing from one values key rather than two hand-copied blocks
under a comment asserting they match.
*/}}
{{- define "pmm.backupRunResources" -}}
{{- toYaml (.Values.centralBackupStorage.tools.resources | default dict) -}}
{{- end -}}

{{/*
The central backup volume's MOUNT. Pairs with pmm.centralBackupVolume — they are the two halves
of one fact (where the run reads and writes), so they live next to each other rather than one
being a helper and the other hand-copied into each consumer.
*/}}
{{- define "pmm.centralBackupMount" -}}
- name: central-backup-storage
  mountPath: {{ .Values.centralBackupStorage.mountPath }}
{{- end -}}
