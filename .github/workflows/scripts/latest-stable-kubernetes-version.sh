#!/usr/bin/env bash
set -Eeuo pipefail

# Print the newest supported Kubernetes version from the specified Minikube release.
main() {
  local minikube_version=${1:-} version
  [[ "$minikube_version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Usage: latest-stable-kubernetes-version.sh <Minikube version, e.g. v1.39.0>" >&2
    return 1
  }
  version="$(
    curl --fail --silent --show-error --location --retry 3 \
      "https://raw.githubusercontent.com/kubernetes/minikube/$minikube_version/pkg/minikube/constants/constants.go" |
      awk '$1 == "NewestKubernetesVersion" {gsub(/"/, "", $3); print $3}'
  )"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Could not resolve stable Kubernetes supported by Minikube $minikube_version" >&2
    return 1
  }
  printf '%s\n' "$version"
}

main "$@"
