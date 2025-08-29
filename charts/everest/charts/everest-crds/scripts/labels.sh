#!/bin/bash

# Usage:
#   ./add-labels.sh /path/to/yamls "key1=value1,key2=value2"

set -e

DIR="$1"
LABELS="$2"

if [ -z "$DIR" ] || [ -z "$LABELS" ]; then
  echo "Usage: $0 <directory> \"key1=value1,key2=value2,...\""
  exit 1
fi

# Convert "key1=value1,key2=value2" to: .metadata.labels."key1" = "value1" | ...
LABEL_EXPR=""
IFS=',' read -ra PAIRS <<< "$LABELS"
for pair in "${PAIRS[@]}"; do
  KEY="${pair%%=*}"
  VALUE="${pair#*=}"
  LABEL_EXPR+=".metadata.labels.\"${KEY}\" = \"${VALUE}\" | "
done
LABEL_EXPR="${LABEL_EXPR% | }"

# Patch each YAML file
find "$DIR" -type f \( -iname "*.yaml" -o -iname "*.yml" \) | while read -r file; do
  echo "Patching labels in $file"
  tmp=$(mktemp)
  yq eval-all "select(fileIndex >= 0) | ${LABEL_EXPR}" "$file" > "$tmp"
  mv "$tmp" "$file"
done

echo "Done!"
