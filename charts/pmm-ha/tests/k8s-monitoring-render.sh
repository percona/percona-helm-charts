#!/usr/bin/env bash
# Contract the Kubernetes dashboards need from PMM HA's own cluster (PMM-13674).
# vmagent.yaml cannot be loaded by helm unittest, so this renders offline and asserts with yq.
# Piped greps read all input: `grep -q` exits early, SIGPIPEs yq and fails the pipeline under pipefail.
set -euo pipefail

chart="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
render() { helm template smoke "$chart" --namespace pmm --set secret.create=true "$@" > "$out"; }
scrape() { yq e 'select(.kind == "VMAgent") | .spec.inlineScrapeConfig' "$out"; }
job() { scrape | JOB="$1" yq e '.[] | select(.job_name == strenv(JOB))' -; }
copied() { job kube-state-metrics | T="$1" yq e '.metric_relabel_configs[] | select(.target_label == strenv(T)) | .source_labels[0]' -; }

render
[ "$(yq e 'select(.kind == "VMAgent") | .spec.externalLabels.k8s_cluster_id' "$out")" = smoke ] \
  || fail "k8s_cluster_id defaults to the release name"

[ "$(job kube-state-metrics | yq e '.honor_labels' -)" = true ] \
  || fail "kube-state-metrics job keeps the object's namespace/pod"
[ "$(copied exported_namespace)" = namespace ] || fail "namespace is copied to exported_namespace"
[ "$(copied exported_pod)" = pod ] || fail "pod is copied to exported_pod"

for j in kubelet cadvisor; do
  ! job "$j" | grep '__meta_kubernetes_node_label_' > /dev/null || fail "$j still copies every node label"
  [ "$(job "$j" | yq e '.relabel_configs[] | select(.target_label == "node") | .source_labels[0]' -)" = __meta_kubernetes_node_name ] \
    || fail "$j sets node from the node name"
done

crs="$(yq e 'select(.kind == "ConfigMap" and .metadata.name == "smoke-kube-state-metrics-customresourcestate-config") | .data["config.yaml"]' "$out")"
for m in kube_pxc kube_psmdb kube_pg kube_ps_mysql; do
  yq e '.spec.resources[].metricNamePrefix' - <<<"$crs" | grep -x "$m" > /dev/null || fail "custom-resource config has $m"
done
yq e 'select(.kind == "Deployment" and .metadata.name == "smoke-kube-state-metrics") | .spec.template.spec.containers[0].args[]' "$out" \
  | grep '^--metric-labels-allowlist=pods=\[app.kubernetes.io/component,app.kubernetes.io/instance,app.kubernetes.io/managed-by' > /dev/null \
  || fail "pod label allowlist"
for g in pxc.percona.com psmdb.percona.com pgv2.percona.com ps.percona.com; do
  yq e 'select(.kind == "ClusterRole" and .metadata.name == "smoke-kube-state-metrics") | .rules[].apiGroups[]' "$out" \
    | grep -x "$g" > /dev/null || fail "kube-state-metrics may list $g"
done

render --set k8sClusterId=prod-eu
[ "$(yq e 'select(.kind == "VMAgent") | .spec.externalLabels.k8s_cluster_id' "$out")" = prod-eu ] \
  || fail "k8sClusterId overrides the release name"

echo "k8s-monitoring render checks: OK"
