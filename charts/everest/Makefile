HELM ?= helm

# values to override
IMAGE_PREFIX ?= percona
TELEMETRY ?= true

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
	$(MAKE) deps
	

release: prepare-chart
release:
	$(MAKE) release -C charts/everest-crds

release-dev: VERSION=0.0.0
release-dev: IMAGE_PREFIX=perconalab
release-dev: TELEMETRY=false
release-dev: prepare-chart
release-dev:
	$(MAKE) release-dev -C charts/everest-crds

add-repos:
	$(HELM) version
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo add vm https://victoriametrics.github.io/helm-charts
	$(HELM) repo add percona https://percona.github.io/percona-helm-charts/
	$(HELM) repo add percona-olm https://percona.github.io/operator-lifecycle-manager/

deps: add-repos
	$(HELM) dependency update .
	$(HELM) dependency update ./charts/everest-db-namespace

docs-gen:
	docker run --rm -v "$(PWD)/:/helm-docs" -u $(shell id -u) jnorwood/helm-docs:v1.14.2

link-crds:
	@mkdir -p crds
	@for crd in charts/everest-crds/templates/*.yaml; do \
		ln -sf "../$${crd}" crds/; \
		echo "Linked $$crd → crds/"; \
	done
