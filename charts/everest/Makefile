HELM ?= helm

prepare-chart:
	CHART_FILES="Chart.yaml ./charts/everest-db-namespace/Chart.yaml"; \
	for chart in $$CHART_FILES; do \
		yq eval -i '.version = "${VERSION}"' $$chart; \
		yq eval -i '.appVersion = "${VERSION}"' $$chart; \
	done
	yq eval -i '.server.image = "$(IMAGE_PREFIX)/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "$(IMAGE_PREFIX)/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "$(IMAGE_PREFIX)/everest-operator"' values.yaml
	yq eval -i '(.dependencies[] | select(.name == "everest-db-namespace")).version = "${VERSION}"' Chart.yaml
	$(MAKE) deps

release: IMAGE_PREFIX=percona
release: prepare-chart

release-dev: IMAGE_PREFIX=perconalab
release-dev: prepare-chart

add-repos:
	$(HELM) version
	$(HELM) repo add prometheus-community https://prometheus-community.github.io/helm-charts
	$(HELM) repo add vm https://victoriametrics.github.io/helm-charts

deps: add-repos
	$(HELM) dependency update .
	$(HELM) dependency update ./charts/everest-db-namespace

docs-gen:
	docker run --rm -v "$(PWD)/:/helm-docs" -u $(shell id -u) jnorwood/helm-docs:v1.14.2


EVEREST_REPO_URL ?= https://github.com/percona/everest-operator
CRD_DIR ?= config/crd
CRD_VERSION ?= main
crds-gen:
	docker run --rm registry.k8s.io/kustomize/kustomize:v5.0.0 build $(EVEREST_REPO_URL)/$(CRD_DIR)?ref=$(CRD_VERSION) > crds/everest.yaml
