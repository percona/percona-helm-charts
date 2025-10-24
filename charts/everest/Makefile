HELM ?= helm

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# values to override
IMAGE_PREFIX ?= percona
TELEMETRY ?= true
VERSION ?= 0.0.0

.PHONY: prepare-chart
prepare-chart: ## Prepare the Helm chart for release or development
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
release: release-crds ## Prepare the chart for release
release: prepare-chart

.PHONY: release-dev
release-dev: IMAGE_PREFIX=perconalab
release-dev: TELEMETRY=false
release-dev: release-crds ## Prepare the chart for development release
release-dev: prepare-chart

.PHONY: add-repos
add-repos: ## Add required Helm repositories
	$(HELM) version
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo add vm https://victoriametrics.github.io/helm-charts
	$(HELM) repo add percona https://percona.github.io/percona-helm-charts/
	$(HELM) repo add percona-olm https://percona.github.io/operator-lifecycle-manager

.PHONY: deps
deps: add-repos ## Update Helm dependencies
	$(HELM) dependency update .
	$(HELM) dependency update ./charts/everest-db-namespace

.PHONY: docs-gen
docs-gen: ## Generate documentation for the Helm chart
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
crds-gen: ## Generate CRDs from the Everest repository
	EVEREST_REPO_URL=$(EVEREST_REPO_URL) \
	CRD_DIR=$(CRD_DIR) \
	CRD_VERSION=$(CRD_VERSION) \
	VERSION=$(VERSION) \
	CRD_SUBCHART_DIR=$(PWD)/charts/everest-crds \
	$(MAKE) -C charts/everest-crds crds-gen

.PHONY: prepare-pr
prepare-pr: ## Prepare the chart for a pull request
	$(MAKE) deps
	$(MAKE) docs-gen
	EVEREST_REPO_URL=$(EVEREST_REPO_URL) \
	CRD_DIR=$(CRD_DIR) \
	CRD_VERSION=$(CRD_VERSION) $(MAKE) crds-gen link-crds
