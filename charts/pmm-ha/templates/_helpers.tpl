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
"pmm.labels" with app.kubernetes.io/component set to .component, for objects other than the PMM
Server. It cannot simply append the component: "pmm.selectorLabels" already emits exactly one
"app.kubernetes.io/component: pmm-server" line, and a second one would be a duplicate key, which
helm-unittest rejects. So the rendered line is substituted instead.
Usage: include "pmm.componentLabels" (dict "ctx" $ "component" "vmagent")
*/}}
{{- define "pmm.componentLabels" -}}
{{ include "pmm.labels" .ctx | replace "app.kubernetes.io/component: pmm-server" (printf "app.kubernetes.io/component: %s" .component) }}
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
Name of the VMAgent CR, its ServiceAccount and RBAC. The operator names its config Secret
"vmagent-" + this.
*/}}
{{- define "pmm.vmagent.name" -}}
{{- printf "%s-vmagent" (include "pmm.fullname" .) -}}
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
The pmm-secret as `lookup` returns it, resolved once per render and memoised on .Values the same
way the generated VictoriaMetrics password is. pmm.validateSecret, secret.yaml and the two
pmm.vm.* helpers all need the same object, and `lookup` is a live API call every time it is
evaluated, so the same Secret was being fetched five or six times per render depending on
secret.create - on every CI --dry-run=server render too.

The whole object is cached rather than just .data, because pmm.validateSecret has to tell a
secret that is absent (or a client-side render, where lookup says nothing) apart from one that
exists carrying no data at all.
*/}}
{{- define "pmm.secret.cached" -}}
{{- if not (hasKey .Values "cachedPmmSecret") -}}
{{- $_ := set .Values "cachedPmmSecret" (lookup "v1" "Secret" .Release.Namespace .Values.secret.name) -}}
{{- end -}}
{{- end -}}

{{/*
Validate the pmm-secret when the user owns it.

statefulset.yaml mounts seven keys from this secret with no `optional`, so one missing key leaves
every PMM pod in CreateContainerConfigError without naming what is wrong. Check them here and
report all of the missing ones in a single message instead.

The list is exactly what secret.yaml generates, which is why secret.create exempts all of it:
demanding a key the chart is about to write would abort the install on its own output.

PMM_ADMIN_PASSWORD is the key PMM-15400 is about - statefulset.yaml maps it to Grafana's
GF_SECURITY_ADMIN_PASSWORD, and leaving that ref optional is what let it vanish silently.

Included from statefulset.yaml and vmauth.yaml - both read these keys, and vmauth.yaml
renders first, so it needs its own call to report the missing key rather than dying on a
b64dec. Keep every consumer that decodes a key from this secret calling it.
*/}}
{{/*
Refuse IRSA with serviceAccount.create=false and no static keys: the PMM /srv sidecar would have no S3 credentials.
*/}}
{{- define "pmm.validateBackupIrsaSa" -}}
{{- $cbs := .Values.centralBackupStorage -}}
{{- if and $cbs.enabled (eq $cbs.mode "s3") $cbs.s3.irsaRoleArn (not .Values.serviceAccount.create) (not $cbs.s3.existingSecret) -}}
{{- fail (printf "centralBackupStorage.s3.irsaRoleArn is set (%s), but serviceAccount.create is false. IRSA authenticates a POD through the ServiceAccount it runs under, and with create=false this chart neither creates that ServiceAccount nor gives the PMM pods one: statefulset.yaml omits serviceAccountName entirely, so they run under the namespace 'default' account. The pmm-backup sidecar would then assume the role with that 'default' account's token, which the role's trust policy does not name, and every /srv backup would fail with 403.\n\nSetting serviceAccount.name does NOT help here - it names the account the chart would have created, and nothing reads it while create is false.\n\nPick one:\n  - set serviceAccount.create=true and let the chart create the ServiceAccount, whose token the sidecar assumes the role with (this is what IRSA needs; the chart also creates the matching ClusterRole/ClusterRoleBinding here); or\n  - use static keys instead: centralBackupStorage.s3.existingSecret=<secret>, which authenticates the sidecar directly and needs no ServiceAccount at all." $cbs.s3.irsaRoleArn) -}}
{{- end -}}
{{- end -}}

{{- define "pmm.validateSecret" -}}
{{/*
An empty secret.name is never a working configuration - statefulset.yaml drops both the envFrom
secretRef and the GF_SECURITY_ADMIN_PASSWORD ref, and vmauth.yaml / pg-user-credentials-secrets.yaml
/ clickhouse-cluster.yaml all read keys off a secret that was never named. Fail on it explicitly
and first: `lookup` with an empty name does not come back empty, it returns a SecretList - truthy,
with no .data - so the key loop below would otherwise report all seven keys as missing from a
secret the operator never asked for, and simply skipping the loop would leave the render to die in
vmauth.yaml on "index of untyped nil", naming neither the secret nor the setting.
*/}}
{{- if not .Values.secret.name -}}
{{- fail "secret.name is empty. Set it to the name of the Kubernetes Secret that holds the PMM credentials (the chart default is 'pmm-secret')." -}}
{{- end -}}
{{- if not .Values.secret.create -}}
{{- include "pmm.secret.cached" . -}}
{{- $found := get .Values "cachedPmmSecret" -}}
{{/*
Only inspect keys once the Secret is actually in hand. `lookup` also comes back empty on every
client-side render - helm template, --dry-run=client, a GitOps preview - where it says nothing
about the secret's contents, and reporting all seven keys as missing there would be simply
wrong. When the secret really is absent, pg-user-credentials-secrets.yaml fails with the
accurate "Secret not found" message instead.
*/}}
{{- if $found -}}
{{- $data := $found.data | default dict -}}
{{- $required := list "PMM_ADMIN_PASSWORD" "GF_PASSWORD" "PG_PASSWORD" "PMM_CLICKHOUSE_USER" "PMM_CLICKHOUSE_PASSWORD" "PMM_HA_VM_USERNAME" "PMM_HA_VM_PASSWORD" -}}
{{- $missing := list -}}
{{- range $key := $required -}}
{{- if not (get $data $key) -}}
{{- $missing = append $missing $key -}}
{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- $hint := "" -}}
{{- if has "PMM_ADMIN_PASSWORD" $missing -}}
{{- $hint = " PMM_ADMIN_PASSWORD sets the PMM/Grafana admin password." -}}
{{- end -}}
{{- if or (has "PMM_HA_VM_USERNAME" $missing) (has "PMM_HA_VM_PASSWORD" $missing) -}}
{{- $hint = printf "%s Technical Preview installations stored the VictoriaMetrics credential as VMAGENT_remoteWrite_basicAuth_username and VMAGENT_remoteWrite_basicAuth_password: rename those keys rather than adding a second copy, because PMM Server forwards every VMAGENT_* key in this secret to all PMM Clients. Alternatively set secret.create=true to have the chart generate the credential." $hint -}}
{{- end -}}
{{- fail (printf "Secret '%s' in namespace '%s' is missing, or has an empty value for, required key(s): %s.%s" .Values.secret.name .Release.Namespace (join ", " $missing) $hint) -}}
{{- end -}}
{{- /*
The renamed keys must replace the Technical Preview ones, not join them. Every key of a user-owned
secret becomes a PMM Server environment variable through envFrom, and PMM Server forwards each
VMAGENT_* variable to every PMM Client's vmagent as its remote-write credential, wherever the
operator points those writes. A leftover copy therefore wins over the credential PMM Server derives
from PMM_VM_URL and goes stale at the next rotation, when every client write starts failing with
nothing in the render or the server log to explain it.
*/ -}}
{{- $legacy := list -}}
{{- range $key := list "VMAGENT_remoteWrite_basicAuth_username" "VMAGENT_remoteWrite_basicAuth_password" -}}
{{- if hasKey $data $key -}}
{{- $legacy = append $legacy $key -}}
{{- end -}}
{{- end -}}
{{- if $legacy -}}
{{- fail (printf "Secret '%s' in namespace '%s' still carries the Technical Preview key(s) %s. PMM Server forwards every VMAGENT_* key in this secret to all PMM Clients as their remote-write credential, so a leftover copy overrides the PMM_HA_VM_* credential and breaks every client write once that credential is rotated. Remove them with: kubectl get secret %s -n %s -o json | jq 'del(.data.VMAGENT_remoteWrite_basicAuth_username, .data.VMAGENT_remoteWrite_basicAuth_password)' | kubectl replace -f - (kubectl apply does not delete them; see 'Creating PMM Secret Manually' in the chart README for the full rename)." .Values.secret.name .Release.Namespace (join ", " $legacy) .Values.secret.name .Release.Namespace) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Override pg-database.fullname to ensure consistent naming
This overrides the function from the pg-db subchart
*/}}
{{- define "pg-database.fullname" -}}
{{- printf "%s-pg-db" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
host:port of the PostgreSQL primary (the pg-operator's <cluster>-ha service).
*/}}
{{- define "pmm.postgres.addr" -}}
{{- printf "%s-ha.%s.svc.cluster.local:5432" (include "pg-database.fullname" .) .Release.Namespace -}}
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
Port HAProxy binds for PMM traffic. The HAProxy Service publishes this same value, so every
in-cluster consumer of PMM has to follow it rather than assume 443.
*/}}
{{- define "pmm.haproxy.httpsPort" -}}
{{- (.Values.haproxy.containerPorts).https | default 443 -}}
{{- end -}}

{{/*
Port of the HAProxy stats frontend, which serves both the stats page and the Prometheus exporter.
The pmm-ha-haproxy-stats Service publishes it; pmm-ha-haproxy does not.
*/}}
{{- define "pmm.haproxy.statsPort" -}}
{{- .Values.haproxy.monitoring.stats.port | default 1024 -}}
{{- end -}}

{{/*
PMM Server address reachable from inside the cluster. HAProxy routes to the current leader, so this
stays valid across failovers.
*/}}
{{- define "pmm.client.serverAddress" -}}
{{- $haproxy := .Values.haproxy.fullnameOverride | default (printf "%s-haproxy" (include "pmm.fullname" .)) -}}
{{- $port := include "pmm.haproxy.httpsPort" . -}}
{{- printf "%s.%s.svc.cluster.local:%v" $haproxy .Release.Namespace $port -}}
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

{{/*
Whether the bundled kube-state-metrics Deployment will render ("true"/"false").
Like Helm's `condition:`, only a boolean false disables the subchart.
*/}}
{{- define "pmm.kubeStateMetrics.bundledEnabled" -}}
{{- $v := dig "enabled" true (default dict (index .Values "kube-state-metrics")) -}}
{{- if and (kindIs "bool" $v) (not $v) }}false{{ else }}true{{ end }}
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
{{- if gt $upper $maxOdd -}}
{{- if le $lower $maxOdd -}}
{{- $hint = printf "Use %d." $lower -}}
{{- else -}}
{{- $hint = printf "%s is %d, so the largest supported value is %d." (.ceilingName | default "The ceiling") $ceiling $maxOdd -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- fail (printf "%s must be odd, got %d: an even count adds a Raft voter without adding fault tolerance - it widens the majority a leader election needs while surviving no more failures. %s" $name $n $hint) -}}
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
Fail-fast validation for the `openshift` flag.

It only governs the PMM Server and PMM Client pod securityContexts. The bundled
kube-state-metrics and prometheus-node-exporter carry their own `restricted-v2` violations, and
left at their defaults they reproduce the very failure the flag exists to remove: Helm reports
`STATUS: deployed` while those workloads are rejected at admission and produce zero pods. So the
flag requires the rest of the overlay rather than silently delivering half of it.
Called from statefulset.yaml, which always renders.
*/}}
{{- define "pmm.openshift.validate" -}}
{{- if .Values.openshift -}}
{{- if ne (include "pmm.nodeExporter.mode" .) "openshift" -}}
{{- fail "openshift=true requires nodeExporter.mode=openshift: the bundled prometheus-node-exporter needs hostNetwork, hostPID, hostPath volumes and host port 9100, none of which restricted-v2 permits. Install with -f examples/values-openshift.yaml." -}}
{{- end -}}
{{- if eq (include "pmm.kubeStateMetrics.bundledEnabled" .) "true" -}}
{{- if dig "securityContext" "enabled" true (default dict (index .Values "kube-state-metrics")) -}}
{{- fail "openshift=true requires kube-state-metrics.securityContext.enabled=false: the subchart pins uid/gid/fsGroup 65534, outside the namespace's assigned ranges. Install with -f examples/values-openshift.yaml." -}}
{{- end -}}
{{- end -}}
{{- $httpsPort := int (include "pmm.haproxy.httpsPort" .) -}}
{{- if lt $httpsPort 1024 -}}
{{- fail (printf "openshift=true requires haproxy.containerPorts.https above 1024, got %d: restricted-v2 runs the container as a non-root uid with all capabilities dropped and allowPrivilegeEscalation=false, so HAProxy cannot bind a privileged port (\"cannot bind socket (Permission denied) for [0.0.0.0:%d]\") and the only ingress to PMM crash-loops while Helm still reports STATUS: deployed. Install with -f examples/values-openshift.yaml." $httpsPort $httpsPort) -}}
{{- end -}}
{{- else -}}
{{/*
The inverse check: the cluster IS OpenShift but openshift=false, so the chart is about to pin
uid/gid values restricted-v2 rejects. Worth failing the render over, because the failure it
prevents is silent, delayed and NOT self-healing:

  - the StatefulSets are accepted, and pods already running stay up, so nothing looks wrong;
  - every REPLACEMENT pod is refused ("1000 is not an allowed group ... must be in the ranges:
    [1000850000, 1000859999]"), so the set quietly degrades, 3 -> 2 -> ...;
  - and it cannot be repaired by fixing the values and upgrading again. Helm diffs against the
    last SUCCESSFUL release; a failed upgrade's manifest is not recorded, so the uid keys it
    applied are invisible to every later upgrade. They have to be cleared by hand:
      kubectl patch sts <sts> --type=merge \
        -p '{"spec":{"template":{"spec":{"securityContext":null}}}}'

Detection is .Capabilities, not `lookup`: it needs no RBAC, and a client-side `helm template`
carries the default API list, so CI renders do not trip this.

Narrow on purpose - it fires only when something restricted-v2 would actually reject is set, so
clearing those keys is an escape hatch for anyone running with anyuid.
*/}}
{{- if .Capabilities.APIVersions.Has "security.openshift.io/v1" -}}
{{- $psc := .Values.podSecurityContext | default dict -}}
{{- $pinned := list -}}
{{- range $k := (list "runAsUser" "runAsGroup" "fsGroup") -}}
{{- if hasKey $psc $k -}}{{- $pinned = append $pinned (printf "podSecurityContext.%s" $k) -}}{{- end -}}
{{- end -}}
{{- if not (kindIs "invalid" .Values.pmmClient.fsGroup) -}}
{{- $pinned = append $pinned "pmmClient.fsGroup" -}}
{{- end -}}
{{- $cpsc := .Values.pmmClient.podSecurityContext | default dict -}}
{{- range $k := (list "runAsUser" "runAsGroup" "fsGroup") -}}
{{- if hasKey $cpsc $k -}}{{- $pinned = append $pinned (printf "pmmClient.podSecurityContext.%s" $k) -}}{{- end -}}
{{- end -}}
{{- if $pinned -}}
{{- fail (printf "This cluster exposes security.openshift.io/v1 (OpenShift), but openshift=false. %s would be rendered onto the PMM Server and PMM Client StatefulSets, and restricted-v2 rejects uids and groups outside the namespace's assigned ranges.\n\nThe pods are ADMITTED at apply time and only REPLACEMENT pods are refused, so the StatefulSet degrades silently later, and a failed upgrade leaves values that no subsequent upgrade can clear (Helm diffs against the last successful release).\n\nSet openshift=true, or install with -f examples/values-openshift.yaml. If you deliberately run with anyuid, clear those keys instead (podSecurityContext={}, pmmClient.fsGroup=null and pmmClient.podSecurityContext.runAsUser=null)." (join ", " $pinned)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Refuse a namespace enforcing "restricted" while the PostgreSQL PMM sidecar is on: the operator
adds it without a security context once PMM is up, the re-created PostgreSQL pod is refused, and
Helm still reports success. Offline renders skip this (`lookup`), OpenShift's restricted-v2 fills
the context in, and pgDbPmmSidecarPatched acknowledges the manual patch in the README.
*/}}
{{- define "pmm.podSecurity.validate" -}}
{{- if and (index .Values "pg-db" "pmm" "enabled") (not .Values.openshift) (not .Values.pgDbPmmSidecarPatched) -}}
{{- $ns := lookup "v1" "Namespace" "" .Release.Namespace -}}
{{- $enforce := dig "metadata" "labels" "pod-security.kubernetes.io/enforce" "" ($ns | default dict) -}}
{{- if eq $enforce "restricted" -}}
{{- fail (printf "Namespace '%s' enforces the \"restricted\" Pod Security Standard, and pg-db.pmm.enabled=true. The PostgreSQL Operator adds the PMM sidecar to the PostgreSQL pods without a security context once PMM is up, so those pods are then refused and PMM Server loses its database while Helm still reports success.\n\nEither set pg-db.pmm.enabled=false (PMM then does not monitor its own database), or set pgDbPmmSidecarPatched=true and hand the security context to the operator right after installing:\n\n  kubectl -n %s patch perconapgcluster %s-pg-db --type merge -p '{\"spec\":{\"pmm\":{\"containerSecurityContext\":{\"runAsUser\":1002,\"runAsNonRoot\":true,\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]},\"seccompProfile\":{\"type\":\"RuntimeDefault\"}}}}}'\n\nSee \"PMM sidecar in the PostgreSQL pods\" in the chart README." .Release.Namespace .Release.Namespace .Release.Name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fail-fast validation for the ClickHouse Keeper node count.
Called from statefulset.yaml alongside the other value checks, for the same ordering
reason described above.

The parenthesised lookup matches pmm.nodeExporter.mode: without it, a nulled clickhouse
or clickhouse.keeper key aborts with a raw Go nil-pointer error instead of the message
this validator exists to produce.

Unlike replicas there is no HAProxy-style hard constraint here, so the ceiling is a
supportability limit rather than a correctness one: every Keeper node is a full Raft
voter, so each extra pair widens the majority that every write waits on while buying
fault tolerance nobody asked for - 9 already survives 4 simultaneous losses. The bound
is enforced here rather than in pmm.validate.oddCount, which only clamps the hint: adding
a rejection there would fire ahead of the maxReplicas check in pmm.replicas.validate and
swallow its far more specific message.
*/}}
{{- define "pmm.keeper.validate" -}}
{{- $ceiling := 9 -}}
{{- $raw := ((.Values.clickhouse).keeper).replicasCount -}}
{{- include "pmm.validate.oddCount" (dict "name" "clickhouse.keeper.replicasCount" "value" $raw "ceiling" $ceiling "ceilingName" "The supported maximum") -}}
{{- $n := int $raw -}}
{{- if gt $n $ceiling -}}
{{- fail (printf "clickhouse.keeper.replicasCount (%d) exceeds the supported maximum (%d): every Keeper node is a full Raft voter, so each extra pair widens the majority every write waits on without buying fault tolerance the cluster needs - %d already survives 4 simultaneous losses." $n $ceiling $ceiling) -}}
{{- end -}}
{{- end -}}

{{/*
Fail-fast validation that the bundled PostgreSQL cluster still reaches HAProxy.

`haproxy.containerPorts.https` moves the HAProxy bind and the Service port together, and the
chart's own consumers follow it. `pg-db.pmm.serverHost` does not: the PostgreSQL operator copies
it verbatim into PMM_AGENT_SERVER_ADDRESS, and pmm-agent appends :443 to an address that carries
no port. Left behind, the sidecar dials a port HAProxy no longer publishes while every pod stays
Running and the PMM inventory stays empty - the same silent half-install the openshift validator
exists to prevent, and reachable on plain Kubernetes.
Only checked when serverHost actually points at this chart's HAProxy; an external PMM is the
user's business.
Called from statefulset.yaml, which always renders.
*/}}
{{- define "pmm.haproxy.validate" -}}
{{- $port := int (include "pmm.haproxy.httpsPort" .) -}}
{{- $pg := default dict (index .Values "pg-db") -}}
{{- if dig "pmm" "enabled" false $pg -}}
{{- $host := dig "pmm" "serverHost" "" $pg -}}
{{- $svc := .Values.haproxy.fullnameOverride | default (printf "%s-haproxy" (include "pmm.fullname" .)) -}}
{{- $parts := splitList ":" $host -}}
{{- if hasPrefix $svc (first $parts) -}}
{{- $declared := 443 -}}
{{- if gt (len $parts) 1 -}}
{{- $declared = int (last $parts) -}}
{{- end -}}
{{- if ne $declared $port -}}
{{- fail (printf "pg-db.pmm.serverHost is %q, which resolves to port %d, but haproxy.containerPorts.https is %d. The PostgreSQL operator copies serverHost verbatim into PMM_AGENT_SERVER_ADDRESS and pmm-agent appends :443 to an address with no port, so the PMM sidecar would dial a port HAProxy does not publish - silently, while every pod stays Running and the PMM inventory stays empty. Set pg-db.pmm.serverHost to %q." $host $declared $port (printf "%s:%d" $svc $port)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fail-fast check for the minimum Helm version, 3.17.0. Two things set it:
- Helm before 3.13.0 ignores a null in this chart's values.yaml that should remove a subchart
  default, so the haproxytech defaults stat: 1024 and http: 80 stay on the pmm-ha-haproxy
  Service, and a LoadBalancer or NodePort service type exposes the unauthenticated stats page
  while the install reports success.
- Without a cluster (helm template), Helm checks kubeVersion against the Kubernetes version it
  was built for, which is below the chart's 1.32 floor before Helm 3.17.0 (3.16 assumes 1.31).
Called from statefulset.yaml, which always renders.
*/}}
{{- define "pmm.helmVersion.validate" -}}
{{- $version := .Capabilities.HelmVersion.Version -}}
{{- if not (semverCompare ">=3.17.0-0" $version) -}}
{{- fail (printf "pmm-ha supports Helm 3.17.0 or later, got %s; upgrade Helm. The minimum exists because Helm before 3.17.0 assumes a Kubernetes version older than 1.32 when rendering without a cluster, so it rejects the chart's kubeVersion, and Helm before 3.13.0 also ignores the nulls in values.yaml that keep the HAProxy stats port off the pmm-ha-haproxy Service, so it would publish the unauthenticated stats page on port %s." $version (include "pmm.haproxy.statsPort" .)) -}}
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
Central backup volume entry "central-backup-storage".
*/}}
{{- define "pmm.centralBackupVolume" -}}
{{- /* Always a PVC: restore temp pods can only mount a claim. Use a PV for raw NFS. */}}
- name: central-backup-storage
  persistentVolumeClaim:
    claimName: {{ .Values.centralBackupStorage.existingClaim | default (printf "%s-central-backup" .Release.Name) }}
{{- end -}}

{{/*
Key name inside an S3 credentials Secret: (dict "keys" <existingSecretKeys> "which" "access"|"secret").
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
Static S3 key env from a Secret: (dict "secret" <name> "keys" <existingSecretKeys> ["idVar" "secretVar"]).
*/}}
{{- define "pmm.s3KeyEnv" -}}
- name: {{ .idVar | default "AWS_ACCESS_KEY_ID" }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ include "pmm.s3SecretKeyName" (dict "keys" .keys "which" "access") }}
- name: {{ .secretVar | default "AWS_SECRET_ACCESS_KEY" }}
  valueFrom:
    secretKeyRef:
      name: {{ .secret }}
      key: {{ include "pmm.s3SecretKeyName" (dict "keys" .keys "which" "secret") }}
{{- end -}}

{{/*
rclone "s3" remote env for the pmm-backup sidecar and pmm-backup.sh runs; render_rclone_s3_env() mirrors it for temp pods.
*/}}
{{- define "pmm.rcloneS3Env" -}}
{{- $s3 := .Values.centralBackupStorage.s3 -}}
- name: RCLONE_CONFIG_S3_TYPE
  value: "s3"
- name: RCLONE_CONFIG_S3_PROVIDER
  value: {{ $s3.provider | default "AWS" | quote }}
- name: RCLONE_CONFIG_S3_ENV_AUTH
  value: "true"
- name: RCLONE_CONFIG_S3_REGION
  value: {{ $s3.region | quote }}
{{- /* The IAM policy has no CreateBucket. */}}
- name: RCLONE_CONFIG_S3_NO_CHECK_BUCKET
  value: "true"
{{- with $s3.endpoint }}
- name: RCLONE_CONFIG_S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
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
Backup S3 ServiceAccount name; release-scoped so two releases can share a namespace.
*/}}
{{- define "pmm.backupS3SaName" -}}
{{- .Values.centralBackupStorage.s3.serviceAccountName | default (printf "%s-backup-s3" .Release.Name) -}}
{{- end -}}

{{/*
S3 key root for this install: <namespace>/<prefix>, prefix defaulting to the release name.
Retention deletes by age under its root, so the root must be unique per install.
*/}}
{{- define "pmm.backupS3Root" -}}
{{- $prefix := .Values.centralBackupStorage.s3.prefix | default .Release.Name | trimPrefix "/" | trimSuffix "/" -}}
{{- printf "%s/%s" .Release.Namespace $prefix -}}
{{- end -}}

{{/*
Shared-target install path; independent of s3.prefix by design.
*/}}
{{- define "pmm.backupInstallPath" -}}
{{- printf "%s/%s" .Release.Namespace .Release.Name -}}
{{- end -}}

{{/*
This install's logs/, .staging/ and .metrics/ root. Shared mode nests it under the install path,
or two installs on one volume overwrite each other's metrics and reap each other's logs.
*/}}
{{- define "pmm.backupStateDir" -}}
{{- if eq .Values.centralBackupStorage.mode "shared" -}}
{{- printf "%s/%s" .Values.centralBackupStorage.mountPath (include "pmm.backupInstallPath" .) -}}
{{- else -}}
{{- .Values.centralBackupStorage.mountPath -}}
{{- end -}}
{{- end -}}

{{/*
Scope a scrape job to this release's backup-tools pod. regexQuoteMeta: relabel regexes are not escaped.
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
Env for a pmm-backup.sh run, shared by the Deployment and Job pods so their targets can't drift.
*/}}
{{- define "pmm.backupRunEnv" -}}
- name: NAMESPACE
  value: {{ .Release.Namespace }}
{{- /* Scopes the backup-tools selector when two releases share a namespace. */}}
- name: RELEASE_NAME
  value: {{ .Release.Name }}
{{- /* ClickHouse credentials: the same Secret the ClickHouse pods use, not the script's pmm-secret default. */}}
- name: CH_SECRET_NAME
  value: {{ .Values.secret.name | quote }}
- name: BACKUP_DIR
  value: {{ .Values.centralBackupStorage.mountPath }}
- name: STATE_DIR
  value: {{ include "pmm.backupStateDir" . }}
- name: METRICS_DIR
  value: {{ include "pmm.backupStateDir" . }}/.metrics
{{- /* Manual runs prune too, so they need retentionDays. */}}
- name: BACKUP_RETENTION
  value: {{ .Values.centralBackupStorage.schedule.retentionDays | int | quote }}
# Defaults for pmm-backup.sh; flags still override.
- name: BACKUP_TARGET
  value: {{ .Values.centralBackupStorage.mode | quote }}
{{- if eq .Values.centralBackupStorage.mode "shared" }}
- name: SHARED_MOUNT_PATH
  value: {{ .Values.centralBackupStorage.sharedMountPath | quote }}
{{- /* Per-install catalog under a shared mount; same string as S3_PREFIX. */}}
- name: SHARED_SUBPATH
  value: {{ include "pmm.backupInstallPath" . | quote }}
{{- else }}
- name: S3_BUCKET
  value: {{ .Values.centralBackupStorage.s3.bucket | quote }}
- name: S3_REGION
  value: {{ .Values.centralBackupStorage.s3.region | quote }}
- name: S3_PREFIX
  value: {{ include "pmm.backupS3Root" . | quote }}
- name: S3_PROVIDER
  value: {{ .Values.centralBackupStorage.s3.provider | default "AWS" | quote }}
{{ include "pmm.rcloneS3Env" . }}
{{- with .Values.centralBackupStorage.s3.existingSecret }}
{{ include "pmm.s3KeyEnv" (dict "secret" . "keys" $.Values.centralBackupStorage.s3.existingSecretKeys) }}
{{- end }}
{{- with .Values.centralBackupStorage.s3.endpoint }}
- name: S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- /* vmbackup/vmrestore take the endpoint only as a flag, so this pod needs VM's own (DN-28). */}}
{{- $vmEndpoint := .Values.victoriaMetrics.vmstorage.backup.s3.endpoint | default .Values.centralBackupStorage.s3.endpoint }}
{{- if and $vmEndpoint (ne $vmEndpoint .Values.centralBackupStorage.s3.endpoint) }}
- name: VM_S3_ENDPOINT
  value: {{ $vmEndpoint | quote }}
{{- end }}
{{- /* VM region/secret overrides, so vmrestore's temp pod reads what vmbackup wrote. */}}
{{- $vmS3 := .Values.victoriaMetrics.vmstorage.backup.s3 }}
{{- $vmRegion := $vmS3.region | default .Values.centralBackupStorage.s3.region }}
{{- if and $vmRegion (ne $vmRegion .Values.centralBackupStorage.s3.region) }}
- name: VM_S3_REGION
  value: {{ $vmRegion | quote }}
{{- end }}
{{- /* Whenever set, even if it names the central Secret: its keys may differ (vmcluster.yaml uses them). */}}
{{- if $vmS3.existingSecret }}
- name: VM_S3_SECRET_NAME
  value: {{ $vmS3.existingSecret | quote }}
- name: VM_S3_SECRET_ACCESS_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $vmS3.existingSecretKeys "which" "access") | quote }}
- name: VM_S3_SECRET_SECRET_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $vmS3.existingSecretKeys "which" "secret") | quote }}
{{- end }}
{{- with .Values.centralBackupStorage.s3.existingSecret }}
- name: S3_SECRET_NAME
  value: {{ . | quote }}
- name: S3_SECRET_ACCESS_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "access") | quote }}
- name: S3_SECRET_SECRET_KEY_KEY
  value: {{ include "pmm.s3SecretKeyName" (dict "keys" $.Values.centralBackupStorage.s3.existingSecretKeys "which" "secret") | quote }}
{{- end }}
{{- /* Only when the SA is created; a missing SA fails temp pods at admission mid-restore. */}}
{{- if .Values.centralBackupStorage.s3.irsaRoleArn }}
- name: S3_SERVICE_ACCOUNT
  value: {{ include "pmm.backupS3SaName" . | quote }}
{{- end }}
{{- end }}
{{- with .Values.victoriaMetrics.vmstorage.backup.restoreImage }}
- name: VMRESTORE_IMAGE
  value: {{ . | quote }}
{{- end }}
{{- /* Both modes: a ResourceQuota would reject unqualified temp pods after scale-down. */}}
- name: TEMP_POD_RESOURCES
  value: {{ .Values.centralBackupStorage.tools.restorePodResources | default .Values.centralBackupStorage.tools.resources | default dict | toJson | quote }}
{{- end -}}

{{/*
SA every backup/restore run uses (the one bound to the backup Role).
*/}}
{{- define "pmm.backupRunSaName" -}}
{{- printf "%s-backup-sa" .Release.Name -}}
{{- end -}}

{{/*
IRSA annotations for backup SAs; role-arn only if the user didn't set it (duplicate keys fail).
*/}}
{{- define "pmm.backupIrsaAnnotations" -}}
{{- if and (eq .Values.centralBackupStorage.mode "s3") .Values.centralBackupStorage.s3.irsaRoleArn -}}
{{- with .Values.centralBackupStorage.s3.serviceAccountAnnotations }}
{{ toYaml . }}
{{- end }}
{{- if not (hasKey (.Values.centralBackupStorage.s3.serviceAccountAnnotations | default dict) "eks.amazonaws.com/role-arn") }}
eks.amazonaws.com/role-arn: {{ .Values.centralBackupStorage.s3.irsaRoleArn | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Pod security context for the PMM Server StatefulSet.

On OpenShift the namespace owns the identity: `restricted-v2` requires runAsUser to be inside
the namespace's assigned uid-range and fsGroup inside its supplemental-group range, and rejects
the pod outright otherwise. Dropping just those three keys lets OpenShift assign the identity
while everything else the user set - seccompProfile, supplementalGroups, fsGroupChangePolicy -
survives, since `restricted-v2` permits all of them.

On plain Kubernetes fsGroup is load-bearing - it is what makes the PVC group-writable for the
image's uid - so it must stay. runAsUser is not: the PMM Server image already declares
`USER 1000`, and its entrypoint supports an arbitrary assigned uid via the NSS wrapper.
*/}}
{{- define "pmm.podSecurityContext" -}}
{{- $ctx := .Values.podSecurityContext | default dict -}}
{{- if .Values.openshift -}}
{{- $ctx = omit $ctx "runAsUser" "runAsGroup" "fsGroup" -}}
{{- end -}}
{{- if $ctx -}}
securityContext:
  {{- toYaml $ctx | nindent 2 }}
{{- else -}}
securityContext: {}
{{- end -}}
{{- end -}}

{{/*
Pod security context for the PMM Client StatefulSet. Same reasoning as above; the client image
runs as uid 1002 rather than 1000. `pmmClient.fsGroup` owns the group - the image user has to
own the volume to write to it - and `pmmClient.podSecurityContext` carries the rest.
*/}}
{{- define "pmm.client.podSecurityContext" -}}
{{- $ctx := deepCopy (.Values.pmmClient.podSecurityContext | default dict) -}}
{{- if not (kindIs "invalid" .Values.pmmClient.fsGroup) -}}
{{- $_ := set $ctx "fsGroup" .Values.pmmClient.fsGroup -}}
{{- end -}}
{{- if .Values.openshift -}}
{{- $ctx = omit $ctx "runAsUser" "runAsGroup" "fsGroup" -}}
{{- end -}}
{{- if $ctx -}}
securityContext:
  {{- toYaml $ctx | nindent 2 }}
{{- else -}}
securityContext: {}
{{- end -}}
{{- end -}}

{{/*
Name of the secret holding the PMM service account token the pg-db PMM client uses.

Reproduces pg-db's own default expression - `pmm.secret | default (printf "%s-pmm-secret"
(include "pg-database.fullname" .))` (charts/pg-db/templates/cluster.yaml) - rather than the
string it happens to produce, so the two cannot drift: pmm-ha overrides pg-database.fullname
above, and both sides pick that override up from the same place. Only the Job reads this
helper; the subchart reaches pg-database.fullname directly.

Release-scoped on purpose: the token is created imperatively by the token-init Job rather
than owned by Helm, so `helm uninstall` cannot remove it. A fixed name therefore lets a NEW
release inherit the previous install's dead token.
*/}}
{{- define "pmm.pgPmmSecretName" -}}
{{- $explicit := index .Values "pg-db" "pmm" "secret" -}}
{{- if $explicit -}}
{{- $explicit -}}
{{- else -}}
{{- printf "%s-pmm-secret" (include "pg-database.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
backup-tools identity: Deployment selector and backup Job podAffinity.
*/}}
{{- define "pmm.backupToolsSelectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backup-tools
{{- end -}}

{{/*
Chart-shipped scripts; subPath mounts keep /usr/local/bin intact.
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

{{- define "pmm.backupRunResources" -}}
{{- toYaml (.Values.centralBackupStorage.tools.resources | default dict) -}}
{{- end -}}

{{- define "pmm.centralBackupMount" -}}
- name: central-backup-storage
  mountPath: {{ .Values.centralBackupStorage.mountPath }}
{{- end -}}

{{/*
Name of the pg-db PMM token-init Job, suffixed with a hash of its own pod template.

A Job's spec.template is immutable, and this Job carries no helm.sh/hook annotations, so Helm
treats it as an ordinary release resource and patches it on upgrade. Any change to the script
or to an env value would then fail the upgrade with `spec.template: field is immutable` for as
long as the previous Job exists - ttlSecondsAfterFinished bounds that to 24h after it
completed, so it only bites an upgrade that follows soon after an install, which is exactly
what CI (fresh `ct install` only) never exercises. With the hash in the name such a change
renames the resource instead, and Helm creates the new Job and prunes the old one.

The release name is truncated, rather than the finished string, so the result stays within the
63-character limit that applies to the `job-name` label Kubernetes puts on the Job's pods while
keeping the "-pmm-token-init" part readable: 37 + "-pmm-token-init" + "-" + 8 = 61. Helm caps
release names at 53, so the untruncated `<release>-pmm-token-init` this replaces could reach 68
and be rejected outright.
*/}}
{{- define "pmm.pgTokenJobName" -}}
{{- $base := .Release.Name | trunc 37 | trimSuffix "-" -}}
{{- printf "%s-pmm-token-init-%s" $base (include "pmm.pgTokenJobPodTemplate" . | sha256sum | trunc 8) -}}
{{- end -}}

{{/*
Data retention.

In HA, retention is fixed when the replicas start: vmstorage reads its period when it
starts, and each replica's Query Analytics service reads its own when it starts. PMM
therefore refuses a retention change through its API and shows the UI field as read-only,
which makes this chart the only place the period is set.

`dataRetentionDays` is that place. The one value is rendered into two, so there is no
window in which the stores disagree: PMM_DATA_RETENTION on every PMM replica, which
governs Query Analytics data in ClickHouse, and VMCluster.spec.retentionPeriod, which
governs metrics.

PMM requires PMM_DATA_RETENTION to be a whole multiple of 24h and refuses to start
otherwise, which is why this chart takes whole days and does the conversion itself rather
than accepting a free-form duration.

Example: dataRetentionDays: 90 -> PMM_DATA_RETENTION "2160h" and retentionPeriod "90d".
*/}}
{{- define "pmm.dataRetention.validate" -}}
{{- if .Values.victoriaMetrics.enabled }}
  {{- with .Values.victoriaMetrics.vmstorage }}
    {{- /* A null is Helm's way to delete a key, so it counts as removed rather than declared. */}}
    {{- if not (kindIs "invalid" (index . "retentionPeriod")) }}
      {{- fail "victoriaMetrics.vmstorage.retentionPeriod is no longer used: this chart renders the VMCluster retention period from the top-level `dataRetentionDays`, and a value declared here would let metrics keep data for a different period than Query Analytics. Set `dataRetentionDays` (whole days) instead." }}
    {{- end }}
  {{- end }}
{{- end }}
{{- with .Values.pmmEnv }}
  {{- if not (kindIs "invalid" (index . "PMM_DATA_RETENTION")) }}
    {{- fail "pmmEnv.PMM_DATA_RETENTION is derived by this chart from the top-level `dataRetentionDays`, and a value declared here would let Query Analytics keep data for a different period than metrics. Set `dataRetentionDays` (whole days) instead." }}
  {{- end }}
{{- end }}
{{- /* "" is unset too: it was this chart's own default when dataRetentionDays was optional. */}}
{{- if or (kindIs "invalid" .Values.dataRetentionDays) (eq (toString .Values.dataRetentionDays | trim) "") }}
  {{- fail "dataRetentionDays must be set to a whole number of days. It is the only way to set data retention in HA, because PMM fixes the period when the replicas start and refuses to change it at runtime, so leaving it unset gives a cluster whose retention nothing can set." }}
{{- end }}
{{- if kindIs "bool" .Values.dataRetentionDays }}
  {{- fail (printf "dataRetentionDays must be a whole number of days, got the boolean %v" .Values.dataRetentionDays) }}
{{- end }}
{{- /* 36500 days is VictoriaMetrics' own 100-year maximum, and it keeps days * 24 far from overflowing. */}}
{{- if or (lt (int .Values.dataRetentionDays) 1) (gt (int .Values.dataRetentionDays) 36500) (ne (float64 .Values.dataRetentionDays) (float64 (int .Values.dataRetentionDays))) }}
  {{- fail (printf "dataRetentionDays must be a whole number of days between 1 and 36500, got %v" .Values.dataRetentionDays) }}
{{- end }}
{{- end -}}

{{/*
Retention period for the PMM_DATA_RETENTION environment variable, as a Go duration.
*/}}
{{- define "pmm.dataRetention.pmm" -}}
{{- include "pmm.dataRetention.validate" . -}}
{{- printf "%dh" (mul (int .Values.dataRetentionDays) 24) -}}
{{- end -}}

{{/*
Retention period for VMCluster.spec.retentionPeriod, in days.
*/}}
{{- define "pmm.dataRetention.vm" -}}
{{- include "pmm.dataRetention.validate" . -}}
{{- printf "%dd" (int .Values.dataRetentionDays) -}}
{{- end -}}

{{/*
Value of one VictoriaMetrics credential already stored in .Values.secret.name, empty when the
secret does not carry the key. Takes a dict with "root" and "key".
*/}}
{{- define "pmm.vm.existingCredential" -}}
{{- include "pmm.secret.cached" .root -}}
{{- $existing := get .root.Values "cachedPmmSecret" -}}
{{- $data := dict -}}
{{- if $existing -}}
{{- $data = $existing.data | default dict -}}
{{- end -}}
{{- if hasKey $data .key -}}
{{- index $data .key | b64dec -}}
{{- end -}}
{{- end -}}

{{/*
Username vmauth validates incoming remote-write and query requests against.

vmauth needs the plaintext in its own config while PMM Server and vmagent read it from
.Values.secret.name, so both have to agree: resolving it in one place is what keeps the config
secret and pmm-secret from drifting apart. A user-owned secret that lacks the key is reported by
pmm.validateSecret, which vmauth.yaml and statefulset.yaml call before resolving it.
*/}}
{{- define "pmm.vm.username" -}}
{{- $existing := include "pmm.vm.existingCredential" (dict "root" . "key" "PMM_HA_VM_USERNAME") -}}
{{- if $existing -}}
{{- $existing -}}
{{- else -}}
{{- .Values.secret.victoriametrics_user | default "victoriametrics_pmm" -}}
{{- end -}}
{{- end -}}

{{/*
Password vmauth validates incoming remote-write and query requests against.

A generated password is memoised on .Values, the same way the ClickHouse data source password is:
randAlphaNum would otherwise hand vmauth a different password than the one written to the secret
PMM Server and vmagent authenticate with.
*/}}
{{/*
Refuse a VictoriaMetrics credential that PMM_VM_URL cannot carry.

statefulset.yaml composes PMM_VM_URL as http://$(user):$(password)@host and PMM Server reads the
credential back out with url.Parse and User.Password(). Each half is checked against the character
set url.Parse returns unchanged there, because everything outside it ends as a failed write path
with nothing naming the credential: '"', '<', '>', '[', '\', ']', '^', '`', '{', '|', '}' and any
non-ASCII character make url.Parse reject the whole URL; '/', '?' and '#' end the authority, so the
credential is silently dropped or the URL is rejected; whitespace makes the userinfo invalid; and a
':' in the username moves the boundary, so the rest of the username becomes the start of the
password. '@' is safe in both halves, because url.Parse splits the authority on the last one.

The set is Go's validUserinfo minus '%': url.Parse accepts a percent escape and then decodes it, so
a password of %41 is stored as %41 and arrives at vmauth as A.

An allowlist rather than an enumeration of rejected characters: the two agree with url.Parse on
every printable ASCII character in both halves, but only the allowlist also covers non-ASCII and
the empty string.

Only what the chart can see is checked. A generated password is alphanumeric, and a user-owned
secret is read here through the same memoised lookup every other consumer uses.
*/}}
{{- define "pmm.vm.validateCredential" -}}
{{- $username := include "pmm.vm.username" . -}}
{{- $password := include "pmm.vm.password" . -}}
{{- if not (regexMatch "^[A-Za-z0-9._~!$&'()*+,;=@-]+$" $username) -}}
{{- fail (printf "The VictoriaMetrics username is not usable in PMM_VM_URL: PMM Server parses that URL with url.Parse, which returns the username unchanged only when it is built from letters, digits and the punctuation -._~!$&'()*+,;=@ . Any other character, '%%', ':' and whitespace included, changes the credential, drops it, or fails the parse, and every metric write and query then fails with 401. Set it to a value from that set, in the PMM_HA_VM_USERNAME key of secret '%s' or in secret.victoriametrics_user." .Values.secret.name) -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z0-9._~!$&'()*+,;=:@-]+$" $password) -}}
{{- fail (printf "The VictoriaMetrics password is not usable in PMM_VM_URL: PMM Server parses that URL with url.Parse, which returns the password unchanged only when it is built from letters, digits and the punctuation -._~!$&'()*+,;=:@ . Any other character, '%%' and whitespace included, changes the credential, drops it, or fails the parse, and every metric write and query then fails with 401. Set it to a value from that set, in the PMM_HA_VM_PASSWORD key of secret '%s' or in secret.victoriametrics_password." .Values.secret.name) -}}
{{- end -}}
{{- end -}}

{{- define "pmm.vm.password" -}}
{{- $existing := include "pmm.vm.existingCredential" (dict "root" . "key" "PMM_HA_VM_PASSWORD") -}}
{{- if $existing -}}
{{- $existing -}}
{{- else if .Values.secret.victoriametrics_password -}}
{{- .Values.secret.victoriametrics_password -}}
{{- else -}}
{{- if not (hasKey .Values "generatedVictoriaMetricsPassword") -}}
{{- $_ := set .Values "generatedVictoriaMetricsPassword" (randAlphaNum 32) -}}
{{- end -}}
{{- get .Values "generatedVictoriaMetricsPassword" -}}
{{- end -}}
{{- end -}}

{{/*
Resolve one key of the PMM secret to its base64 value, for the keys that more than one template
needs to agree on.

secret.yaml generates GF_PASSWORD and PG_PASSWORD, and pg-user-credentials-secrets.yaml has to
write those same two passwords into the per-user credentials secrets the PostgreSQL operator
reads. Under secret.create the secret does not exist yet at render time - Helm renders every
template before it applies the pre-install hook that creates it - so the second template cannot
read the value back and has to derive it the same way. Deriving it with a second randAlphaNum
would hand Grafana a password PostgreSQL never got, so the generated value is cached on .Values
and every caller gets the same one, the way pmm.clickhouse.datasourcePassword and
pmm.vm.password already do. The secret itself is read through pmm.secret.cached, like every
other consumer, so this adds no lookup of its own.

Precedence: the key already in the secret (upgrades keep their password), then the explicit
value from values.yaml, then a generated one. Takes a dict with "ctx" (the root context), "key"
and "override". Returns base64 - the callers write it straight into a Secret's data.
*/}}
{{- define "pmm.secret.key" -}}
{{- $ctx := .ctx -}}
{{- include "pmm.secret.cached" $ctx -}}
{{- $existing := get $ctx.Values "cachedPmmSecret" -}}
{{- $current := "" -}}
{{/* An empty secret.name makes lookup return a SecretList, which has no .data. */}}
{{- if and $existing $existing.data -}}
{{- $current = get $existing.data .key -}}
{{- end -}}
{{- if $current -}}
{{- $current -}}
{{- else if .override -}}
{{- .override | b64enc -}}
{{- else -}}
{{- $cache := printf "generated_%s" .key -}}
{{- if not (hasKey $ctx.Values $cache) -}}
{{- $_ := set $ctx.Values $cache (randAlphaNum 32 | b64enc) -}}
{{- end -}}
{{- get $ctx.Values $cache -}}
{{- end -}}
{{- end -}}
