release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is not set."; \
		exit 1; \
	fi
	@for crd in templates/*.yaml; do \
		yq eval '.metadata.labels["everest.percona.com/version"] = "$(VERSION)"' $$crd -i; \
	done

release-dev:
	@$(MAKE) release VERSION=0.0.0

EVEREST_REPO_URL ?= https://github.com/percona/everest-operator
CRD_DIR ?= config/crd
CRD_VERSION ?= main
VERSION ?= 0.0.0
CRD_SUBCHART_DIR ?= $(PWD)
.PHONY: crds-gen
crds-gen:
	@crd_tmp_file="crd.tmp.yaml"; \
	docker run --rm registry.k8s.io/kustomize/kustomize:v5.0.0 \
		build $(EVEREST_REPO_URL)/$(CRD_DIR)?ref=$(CRD_VERSION) > $(CRD_SUBCHART_DIR)/$$crd_tmp_file; \
	docker run --rm -i \
		-v "$(CRD_SUBCHART_DIR)":/workspace \
		-w /workspace \
		python:3.11-slim \
		/bin/sh -c "pip install pyyaml && cat $$crd_tmp_file | python3 ./hack/crd.py --output=templates/ --labels='everest.percona.com/crd=true,everest.percona.com/version=$(VERSION)'"; \
	rm $$crd_tmp_file