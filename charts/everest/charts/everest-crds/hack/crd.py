#!/usr/bin/env python3

import sys
import argparse
import yaml

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, help="Output directory for split CRD files")
    parser.add_argument("--labels", help="Comma-separated labels to add (e.g. key1=val1,key2=val2)")
    args = parser.parse_args()
    
    input_crds = sys.stdin.read()
    
    # split by ---
    crds = input_crds.strip().split("---")
    labels = args.labels.split(',') if args.labels else []
    
    for i, crd in enumerate(crds):
        crd = crd.strip()
        if not crd:
            continue

        # Parse the CRD YAML
        try:
            crd_data = yaml.safe_load(crd)
        except yaml.YAMLError as e:
            print(f"Error parsing CRD {i}: {e}", file=sys.stderr)
            continue

        # Add labels if specified
        if args.labels:
            labels = dict(label.split('=') for label in args.labels.split(','))
            if 'metadata' not in crd_data:
                crd_data['metadata'] = {}
            if 'labels' not in crd_data['metadata']:
                crd_data['metadata']['labels'] = {}
            crd_data['metadata']['labels'].update(labels)
        
        crd_version = crd_data['spec']['versions'][0]['name']
        crd_name = crd_data['metadata']['name']
        file_name = f"{crd_version}_{crd_name}.yaml"
        # Write to file
        output_file = f"{args.output}/{file_name}"
        with open(output_file, 'w') as f:
            yaml.dump(crd_data, f, default_flow_style=False)
        print(f"Wrote CRD {crd_name} to {output_file}")


if __name__ == "__main__":
    main()