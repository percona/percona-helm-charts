#!/usr/bin/env bash

set -Eeuo pipefail

usage='Usage: test-operator-deploy.sh <install|upgrade> <psmdb|ps|pxc|pg> <--version=TAG|--branch=TAG> (upgrade: psmdb only)'
operator_namespace=operator
database_namespace=database
base_sha=${BASE_SHA:-}

die() {
  echo "$*" >&2
  exit 1
}

log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

resolve_operator_image() {
  local selector=$1
  local released=false
  local manifest_error=''

  case "$selector" in
    --version=*)
      released=true
      image_tag=${selector#--version=}
      image_repository="percona/$image_name"
      ;;
    --branch=*)
      image_tag=${selector#--branch=}
      image_repository="perconalab/$image_name"
      ;;
    *) die "$usage" ;;
  esac

  [[ -n "$image_tag" ]] || die "Image version or branch cannot be empty"
  [[ "$image_tag" =~ ^[[:alnum:]_][[:alnum:]_.-]{0,127}$ ]] ||
    die "Invalid container image tag: $image_tag"

  operator_image="$image_repository:$image_tag"
  if [[ "$released" == true ]] &&
    ! manifest_error="$(docker manifest inspect "$operator_image" 2>&1 >/dev/null)"; then
    if ! grep -Eiq 'manifest unknown|no such manifest|not found' \
      <<<"$manifest_error"; then
      die "Could not inspect $operator_image: $manifest_error"
    fi

    echo "$operator_image is not released; using the main development image"
    image_repository="perconalab/$image_name"
    image_tag=main
    operator_image="$image_repository:$image_tag"
  fi

  if [[ "$product" == pg || "$product" == pxc ]]; then
    operator_image_args=(--set "image=$operator_image")
  else
    operator_image_args=(
      --set "image.repository=$image_repository"
      --set "image.tag=$image_tag"
    )
  fi
}

configure() {
  (($# == 3)) || die "$usage"

  mode=$1
  product=$2
  [[ "$mode" == install || "$mode" == upgrade ]] ||
    die "Unsupported mode: $mode"
  [[ "$mode" != upgrade || "$product" == psmdb ]] ||
    die "Upgrade is only supported for psmdb"

  workload_label=app.kubernetes.io/instance
  check_observed_generation=true
  case "$product" in
    psmdb)
      image_name=percona-server-mongodb-operator
      resource=perconaservermongodb
      ;;
    ps)
      image_name=percona-server-mysql-operator
      resource=perconaservermysql
      check_observed_generation=false
      ;;
    pxc)
      image_name=percona-xtradb-cluster-operator
      resource=perconaxtradbcluster
      ;;
    pg)
      image_name=percona-postgresql-operator
      resource=perconapgcluster
      workload_label=postgres-operator.crunchydata.com/cluster
      ;;
    *)
      die "Unsupported product: $product"
      ;;
  esac

  operator="${product}-operator"
  crd="${product}-operator-crds"
  db="${product}-db"
  cluster="test-${db}"
  workload_selector="$workload_label=$cluster"
  local values_file=".github/workflows/files/minimal-${product}-values.yaml"
  [[ -f "$values_file" ]] || die "Test values not found: $values_file"
  db_args=(-f "$values_file")

  resolve_operator_image "$3"

  local chart
  for chart in "$operator" "$db"; do
    [[ -f "charts/$chart/Chart.yaml" ]] ||
      die "Chart not found: charts/$chart"
  done

  echo "Testing $mode for $product with $operator_image"
}

validate_kernel() {
  local kernel_version

  kernel_version="$(uname -r)"
  kernel_version=${kernel_version%%-*}

  version_at_least "$kernel_version" 6.19 || return 0
  version_at_least "$kernel_version" 7.0.14 && return 0

  die "PSMDB 8 is incompatible with Linux kernel $kernel_version; use a kernel older than 6.19 or at least 7.0.14"
}

version_at_least() {
  local version=$1
  local minimum=$2

  [[ "$(printf '%s\n' "$minimum" "$version" | sort -V | head -1)" == "$minimum" ]]
}

get_cr_version() {
  kubectl get "$resource/$cluster" -n "$database_namespace" -o json |
    jq -r '.spec.crVersion // empty'
}

get_workloads() {
  kubectl get statefulsets,deployments -n "$database_namespace" -o json |
    jq --arg label_key "$workload_label" --arg cluster "$cluster" '
      .items |= map(select(
        .metadata.labels[$label_key] == $cluster or
        .spec.template.metadata.labels[$label_key] == $cluster
      ))
    '
}

get_crashlooping_containers() {
  kubectl get pods -n "$database_namespace" \
    -l "$workload_selector" -o json |
    jq -r '
      [.items[] as $pod |
       (($pod.status.initContainerStatuses // []) +
        ($pod.status.containerStatuses // []))[] |
       select((.restartCount // 0) >= 3 and
              .state.waiting.reason == "CrashLoopBackOff") |
       "\($pod.metadata.name)/\(.name) (restarts=\(.restartCount))"] |
      join(", ")
    '
}

save_generations() {
  get_workloads | jq -ce '
    if (.items | length) == 0 then error("No workloads found") else
      [.items[] | {key: (.kind + "/" + .metadata.name), value: .metadata.generation}]
      | from_entries
    end
  '
}

readiness_status() {
  local cr=$1
  local workloads=$2
  local previous=$3

  jq -cn \
    --argjson cr "$cr" \
    --argjson workloads "$workloads" \
    --argjson check_observed_generation "$check_observed_generation" \
    --argjson previous "$previous" '
    def ready:
      (.spec.replicas // 1) as $n |
      (.status.observedGeneration // 0) >= .metadata.generation and
      (.status.replicas // 0) == $n and
      (.status.updatedReplicas // 0) == $n and
      (.status.readyReplicas // 0) == $n and
      (if .kind == "StatefulSet" then
         (.spec.updateStrategy.type // "RollingUpdate") == "OnDelete" or
         .status.currentRevision == .status.updateRevision
       else (.status.availableReplicas // 0) == $n end);
    ($workloads.items | map(
      (.kind + "/" + .metadata.name) as $key |
      {name: $key, generation: .metadata.generation,
       previous: $previous[$key], ready: ready,
       increased: ($previous == {} or
                   ($previous[$key] != null and .metadata.generation > $previous[$key]))}
    )) as $items |
    {cluster: ($cr.status.state // "NotReady"),
     generation: ($cr.metadata.generation // 0),
     observed: ($cr.status.observedGeneration // 0),
     workloads: $items,
     success: (($cr.status.state // "" | ascii_downcase) == "ready" and
       (($check_observed_generation | not) or
        ($cr.status.observedGeneration // 0) >= ($cr.metadata.generation // 0)) and
       ($items | length) > 0 and
       ($previous == {} or (($items | map(.name) | sort) == ($previous | keys | sort))) and
       all($items[]; .ready and .increased))}
  '
}

wait_ready() {
  local previous=${1:-'{}'}
  local deadline=$((SECONDS + 420))
  local cr crashlooping workloads result

  log "Waiting for $cluster and workloads (timeout: 420s)"
  while ((SECONDS < deadline)); do
    cr="$(kubectl get "$resource/$cluster" -n "$database_namespace" -o json)"
    log "$(jq -c '{generation: .metadata.generation, status: .status}' <<< "$cr")"
    kubectl get pods -n "$database_namespace" -o wide
    workloads="$(get_workloads)"
    result="$(readiness_status "$cr" "$workloads" "$previous")"
    log "$(jq -c 'del(.success)' <<<"$result")"

    if [[ "$(jq -r '.success' <<<"$result")" == true ]]; then
      log "SUCCESS: $cluster passed readiness checks"
      return 0
    fi

    crashlooping="$(get_crashlooping_containers)"
    if [[ -n "$crashlooping" ]]; then
      log "ERROR: database containers are crash-looping: $crashlooping" >&2
      return 1
    fi
    sleep 15
  done
  kubectl describe "$resource/$cluster" -n "$database_namespace"
  log "ERROR: timed out waiting for $cluster" >&2
  return 1
}

database_pod_state() {
  local pods

  pods="$(
    kubectl get pods \
      --namespace "$database_namespace" \
      --selector "$workload_selector" \
      --output json
  )"

  if ! jq --exit-status '.items | length > 0' <<<"$pods" >/dev/null; then
    echo "No database pods found for $cluster" >&2
    return 1
  fi

  jq --compact-output '
    [.items[] | {
      name: .metadata.name,
      uid: .metadata.uid,
      containers: (
        ((.status.initContainerStatuses // []) +
         (.status.containerStatuses // []) +
         (.status.ephemeralContainerStatuses // [])) |
        map({name, restartCount}) |
        sort_by(.name)
      )
    }] | sort_by(.name)
  ' <<<"$pods"
}

verify_operator_ready() {
  kubectl rollout status "deployment/$operator" \
    --namespace "$operator_namespace" \
    --timeout 10m
  kubectl wait pods \
    --namespace "$operator_namespace" \
    --selector "app.kubernetes.io/instance=$operator" \
    --for condition=Ready \
    --timeout 5m
}

verify_database_stability() {
  local before=$1
  local after

  echo "Operator $operator is ready; checking database pod stability for 60 seconds"
  sleep 60

  kubectl wait pods \
    --namespace "$database_namespace" \
    --selector "app.kubernetes.io/instance=$cluster" \
    --for condition=Ready \
    --timeout 5m
  after="$(database_pod_state)"

  if [[ "$before" != "$after" ]]; then
    echo "A database pod was replaced or a container restarted after the operator upgrade" >&2
    echo "Before: $before" >&2
    echo "After:  $after" >&2
    return 1
  fi

  echo "Database pods remained stable without restarts for 60 seconds"
}

validate_crds() {
  local crd_list
  local crds=()

  crd_list="$(
    kubectl get customresourcedefinitions \
      --selector 'app.kubernetes.io/component=crd,app.kubernetes.io/part-of=percona-server-mongodb-operator' \
      --output name
  )"
  mapfile -t crds <<<"$crd_list"
  if ((${#crds[@]} == 0)) || [[ -z "${crds[0]}" ]]; then
    echo "No CRDs were installed by $crd" >&2
    return 1
  fi

  kubectl wait \
    --for condition=Established \
    --timeout 2m \
    "${crds[@]}"
  kubectl get "${crds[@]}" \
    --output custom-columns='NAME:.metadata.name,ESTABLISHED:.status.conditions[?(@.type=="Established")].status'
}

install_crd_chart() {
  local crd_source=$1
  local crd_version=${2:-}
  local crd_args=()

  [[ -z "$crd_version" ]] || crd_args+=(--version "$crd_version")

  helm install "$crd" "$crd_source" \
    --namespace "$operator_namespace" \
    --create-namespace \
    --wait \
    --timeout 5m \
    "${crd_args[@]}"
  if [[ "$product" == psmdb ]]; then
    validate_crds
  else
    helm template "$crd" "$crd_source" "${crd_args[@]}" |
      kubectl wait --for condition=Established --timeout 2m -f -
  fi
}

upgrade_crd_chart() {
  helm upgrade "$crd" "charts/$crd" \
    --namespace "$operator_namespace" \
    --wait \
    --timeout 5m
  validate_crds
}

install_operator_chart() {
  local source=$1
  local version=${2:-}
  local use_target_image=${3:-false}
  local operator_args=()

  [[ -z "$version" ]] || operator_args+=(--version "$version")
  [[ "$use_target_image" != true ]] || operator_args+=("${operator_image_args[@]}")
  operator_args+=(--set watchAllNamespaces=true)
  if [[ -f "charts/$crd/Chart.yaml" ]]; then
    operator_args+=(--skip-crds)
  fi

  helm install "$operator" "$source" \
    --namespace "$operator_namespace" \
    --create-namespace \
    --wait \
    --timeout 10m \
    "${operator_args[@]}"
}

install_database_chart() {
  local source=$1
  local version=${2:-}
  local version_args=()

  [[ -z "$version" ]] || version_args+=(--version "$version")

  helm install test "$source" \
    --namespace "$database_namespace" \
    --create-namespace \
    --wait \
    --timeout 10m \
    "${version_args[@]}" \
    "${db_args[@]}"
}

chart_version() {
  git show "$base_sha:$1/Chart.yaml" |
    awk '$1 == "version:" { gsub(/"/, "", $2); print $2; exit }'
}

install_current_charts() {
  if [[ -f "charts/$crd/Chart.yaml" ]]; then
    install_crd_chart "charts/$crd"
  fi
  install_operator_chart "charts/$operator" '' true
  install_database_chart "charts/$db"
}

install_previous_charts() {
  local operator_version db_version crd_version

  [[ -n "$base_sha" ]] || die "BASE_SHA is required for an upgrade test"
  git cat-file -e "$base_sha^{commit}" 2>/dev/null ||
    git fetch --no-tags origin "$base_sha"

  operator_version="$(chart_version "charts/$operator")"
  db_version="$(chart_version "charts/$db")"
  crd_version="$(chart_version "charts/$crd")"
  [[ -n "$operator_version" && -n "$db_version" && -n "$crd_version" ]] ||
    die "Could not determine previous chart versions from $base_sha"

  helm repo add percona \
    https://percona.github.io/percona-helm-charts/ \
    --force-update
  helm repo update

  install_crd_chart "percona/$crd" "$crd_version"
  install_operator_chart "percona/$operator" "$operator_version"
  install_database_chart "percona/$db" "$db_version"
}

# List only components whose baseline images must survive a perconalab upgrade.
# Add each operator's component names here and its Helm fields in the pin function.
save_baseline_init_images() {
  local containers

  case "$product" in
    psmdb) containers='["mongo-init"]' ;;
    *) die "Baseline init images are not configured for $product" ;;
  esac

  kubectl get pods -n "$database_namespace" \
    -l "$workload_selector" -o json |
    jq -ce --argjson containers "$containers" '
      [.items[].spec.initContainers[]?] as $images |
      reduce $containers[] as $container ({};
        ([$images[] | select(.name == $container) | .image] | unique) as $found |
        if ($found | length) == 1 then .[$container] = $found[0]
        else error("Expected one baseline image for " + $container) end)
    '
}

pin_baseline_init_images() {
  local previous_images=$1 init_image
  local image_args=()

  case "$product" in
    psmdb)
      init_image="$(jq -er '."mongo-init" | select(type == "string" and length > 0)' <<< "$previous_images")"
      [[ "$init_image" != *@* && "${init_image##*/}" == *:* ]] ||
        die "Expected a tagged baseline image for mongo-init: $init_image"
      image_args+=(
        --set-string "initImage.repository=${init_image%:*}"
        --set-string "initImage.tag=${init_image##*:}"
      )
      ;;
    *) die "Baseline init image overrides are not configured for $product" ;;
  esac

  log "Pinning baseline init images: $previous_images"
  helm upgrade test "percona/$db" \
    --version "$(chart_version "charts/$db")" \
    --namespace "$database_namespace" \
    --reuse-values \
    "${image_args[@]}"
  wait_ready
}

upgrade_operator() {
  local database_state

  database_state="$(database_pod_state)"
  upgrade_crd_chart
  helm upgrade "$operator" "charts/$operator" \
    --namespace "$operator_namespace" \
    --wait \
    --timeout 10m \
    --set watchAllNamespaces=true \
    "${operator_image_args[@]}"
  verify_operator_ready
  verify_database_stability "$database_state"
}

upgrade_database() {
  local cr_version_before cr_version_after generations_before

  cr_version_before="$(get_cr_version)"
  generations_before="$(save_generations)"
  log "CR version before upgrade: ${cr_version_before:-unset}"
  log "Workload generations before upgrade: $generations_before"

  helm upgrade test "charts/$db" \
    --namespace "$database_namespace" \
    --reset-values \
    "${db_args[@]}"

  cr_version_after="$(get_cr_version)"
  log "CR version after upgrade: ${cr_version_after:-unset}"

  if [[ "$cr_version_before" == "$cr_version_after" ]]; then
    log "CR version unchanged: waiting 60 seconds before readiness checks"
    sleep 60
    wait_ready
    return
  fi

  log "CR version changed: requiring workload generations to increase"
  wait_ready "$generations_before"
}

run_install() {
  install_current_charts
  wait_ready
  helm test test --namespace "$database_namespace" --timeout 10m
}

run_upgrade() {
  local previous_init_images

  install_previous_charts
  wait_ready
  if [[ "$image_repository" == perconalab/* ]]; then
    previous_init_images="$(save_baseline_init_images)"
    pin_baseline_init_images "$previous_init_images"
  fi
  upgrade_operator
  upgrade_database
}

main() {
  configure "$@"
  [[ "$product" != psmdb ]] || validate_kernel

  case "$mode" in
    install) run_install ;;
    upgrade) run_upgrade ;;
  esac
}

main "$@"
