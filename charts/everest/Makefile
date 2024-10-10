prepare-chart:
	yq eval -i '.version = "${VERSION}"' Chart.yaml
	yq eval -i '.appVersion = "${VERSION}"' Chart.yaml


release: prepare-chart
	yq eval -i '.server.image = "percona/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "percona/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "percona/everest-operator"' values.yaml

release-dev: prepare-chart
	yq eval -i '.server.image = "perconalab/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "perconalab/everest-catalog"' values.yaml
	yq eval -i '.operator.image = "perconalab/everest-operator"' values.yaml

