#!/usr/bin/env python3
"""
Split a combined CRD YAML file into individual files named by each resource's metadata.name.
Usage:
    python3 hack/crd-split.py <combined-crd-file>
"""
import os
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is required. Install with: pip3 install pyyaml")
    sys.exit(1)


def split_crds(combined_file_path):
    # Read all documents from the combined YAML
    with open(combined_file_path, 'r') as combined_file:
        documents = list(yaml.safe_load_all(combined_file))

    if not documents:
        print(f"No documents found in {combined_file_path}")
        return

    # Determine output directory
    output_dir = os.path.dirname(os.path.abspath(combined_file_path))

    for doc in documents:
        # Ensure the document is a dict
        if not isinstance(doc, dict):
            print("Skipping non-mapping document")
            continue

        metadata = doc.get('metadata', {})
        name = metadata.get('name')
        if not name:
            print("Skipping document without metadata.name")
            continue

        output_path = os.path.join(output_dir, f"{name}.yaml")
        # Dump YAML to string and inject the Helm labels template under metadata
        yaml_str = yaml.safe_dump(doc, sort_keys=False)
        lines = yaml_str.splitlines()
        out_lines = []
        for line in lines:
            out_lines.append(line)
        # Write the modified content back to file
        with open(output_path, 'w') as out_file:
            out_file.write("\n".join(out_lines) + "\n")
        print(f"Wrote {output_path}")


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <combined-crd-file>")
        sys.exit(1)
    split_crds(sys.argv[1])
