#!/usr/bin/env bash
set -Eeuo pipefail

# Print the latest stable Minikube release for use by other scripts.
main() {
  local version
  version="$(
    curl --fail --silent --show-error --location --retry 3 \
      https://api.github.com/repos/kubernetes/minikube/releases/latest |
      jq -er '.tag_name'
  )"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "Invalid Minikube release: $version" >&2
    return 1
  }
  printf '%s\n' "$version"
}

main "$@"
