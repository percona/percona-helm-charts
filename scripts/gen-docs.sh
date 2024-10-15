#!/bin/bash
## Reference: https://github.com/norwoodj/helm-docs
set -eux

# Usage:
# sh ./scripts/gen-docs.sh </absolute/path/to/chart/dir>

echo "Generating docs..."
docker run --rm -v "$1/:/helm-docs" -u $(id -u) jnorwood/helm-docs:v1.9.1
