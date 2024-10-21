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


release: IMAGE_PREFIX=percona
release: prepare-chart

release-dev: IMAGE_PREFIX=perconalab
release-dev: prepare-chart

docs-gen:
	docker run --rm -v "$(PWD)/:/helm-docs" -u $(shell id -u) jnorwood/helm-docs:v1.9.1
