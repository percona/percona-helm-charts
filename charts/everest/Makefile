prepare-chart:
	CHART_FILES="Chart.yaml charts/everest-db-namespace/Chart.yaml"
	for chart in $${CHART_FILES}; do \
		yq eval -i '.version = "${VERSION}"' $${chart}; \
		yq eval -i '.appVersion = "${VERSION}"' $${chart}; \
	done

release: prepare-chart
	yq eval -i '.server.image = "percona/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "percona/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "percona/everest-operator"' values.yaml

release-dev: prepare-chart
	yq eval -i '.server.image = "perconalab/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "perconalab/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "perconalab/everest-operator"' values.yaml

docs-gen:
	docker run --rm -v "$(PWD)/:/helm-docs" -u $(shell id -u) jnorwood/helm-docs:v1.9.1
