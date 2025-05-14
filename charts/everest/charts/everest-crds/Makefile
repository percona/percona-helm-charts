EVEREST_REPO_URL ?= https://github.com/percona/everest-operator
CRD_DIR ?= config/crd
CRD_VERSION ?= main
CRD_OUTPUT_DIR ?= templates
CRD_OUTPUT_FILE ?= $(CRD_OUTPUT_DIR)/everest.yaml
crds-gen:
	@mkdir -p $(CRD_OUTPUT_DIR)
	@docker run --rm registry.k8s.io/kustomize/kustomize:v5.0.0 build $(EVEREST_REPO_URL)/$(CRD_DIR)?ref=$(CRD_VERSION) > $(CRD_OUTPUT_FILE)
	@docker run --rm \
		-v "$(PWD)":/workspace \
		-w /workspace \
		python:3.11-slim /bin/sh -c "pip3 install pyyaml --no-cache-dir && python3 hack/crd-split.py $(CRD_OUTPUT_FILE)"
	@rm -rf $(CRD_OUTPUT_FILE)
