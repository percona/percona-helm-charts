HELM ?= helm

# values to override
IMAGE_PREFIX ?= percona
TELEMETRY ?= true
VERSION ?= 0.0.0

.PHONY: prepare-chart
prepare-chart:
	CHART_FILES="Chart.yaml ./charts/everest-db-namespace/Chart.yaml ./charts/everest-crds/Chart.yaml"; \
	for chart in $$CHART_FILES; do \
		yq eval -i '.version = "${VERSION}"' $$chart; \
		yq eval -i '.appVersion = "${VERSION}"' $$chart; \
	done
	yq eval -i '.server.image = "$(IMAGE_PREFIX)/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "$(IMAGE_PREFIX)/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "$(IMAGE_PREFIX)/everest-operator"' values.yaml
	yq eval -i '.telemetry = $(TELEMETRY)' values.yaml
	yq eval -i '(.dependencies[] | select(.name == "everest-db-namespace")).version = "${VERSION}"' Chart.yaml
	yq eval -i '(.dependencies[] | select(.name == "everest-crds")).version = "${VERSION}"' Chart.yaml
	$(MAKE) deps
	

.PHONY: release-crds
release-crds:
	VERSION=$(VERSION) \
	$(MAKE) release -C charts/everest-crds


.PHONY: release
release: release-crds
release: prepare-chart

.PHONY: release-dev
release-dev: IMAGE_PREFIX=perconalab
release-dev: TELEMETRY=false
release-dev: release-crds
release-dev: prepare-chart

.PHONY: add-repos
add-repos:
	$(HELM) version
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo add vm https://victoriametrics.github.io/helm-charts
	$(HELM) repo add percona https://percona.github.io/percona-helm-charts/
	$(HELM) repo add percona-olm https://percona.github.io/operator-lifecycle-manager

.PHONY: deps
deps: add-repos
	$(HELM) dependency update .
	$(HELM) dependency update ./charts/everest-db-namespace

.PHONY: docs-gen
docs-gen:
	docker run --rm -v "$(PWD)/:/helm-docs" -u $(shell id -u) jnorwood/helm-docs:v1.14.2

.PHONY: link-crds
link-crds:
	@mkdir -p crds
	@for crd in charts/everest-crds/templates/*.yaml; do \
		ln -sf "../$${crd}" crds/; \
		echo "Linked $$crd → crds/"; \
	done

EVEREST_REPO_URL ?= https://github.com/percona/everest-operator
CRD_DIR ?= config/crd
CRD_VERSION ?= main
.PHONY: crds-gen
crds-gen:
	EVEREST_REPO_URL=$(EVEREST_REPO_URL) \
	CRD_DIR=$(CRD_DIR) \
	CRD_VERSION=$(CRD_VERSION) \
	VERSION=$(VERSION) \
	CRD_SUBCHART_DIR=$(PWD)/charts/everest-crds \
	$(MAKE) -C charts/everest-crds crds-gen

.PHONY: prepare-pr
prepare-pr:
	$(MAKE) deps
	$(MAKE) docs-gen
	EVEREST_REPO_URL=$(EVEREST_REPO_URL) \
	CRD_DIR=$(CRD_DIR) \
	CRD_VERSION=$(CRD_VERSION) $(MAKE) crds-gen link-crds
