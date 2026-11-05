#!/usr/bin/env bash
set -Eeuo pipefail

# Print the latest stable Minikube release for use by other scripts.
main() {
  local version
  local curl_args=(--header "Accept: application/vnd.github+json")
  if [[ -n "${GH_TOKEN:-}" ]]; then
    curl_args+=(--header "Authorization: Bearer $GH_TOKEN")
  fi
  version="$(
    curl --fail --silent --show-error --location --retry 3 \
      "${curl_args[@]}" \
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
