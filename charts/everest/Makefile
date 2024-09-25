prepare-chart:
	yq eval -i '.version = "${VERSION}"' Chart.yaml
	yq eval -i '.appVersion = "${VERSION}"' Chart.yaml


release: prepare-chart
	yq eval -i '.image = "percona/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "percona/everest-catalog"' values.yaml
	yq eval -i '.everestOperator.channel = "stable-v0"' values.yaml

release-dev: prepare-chart
	yq eval -i '.image = "perconalab/everest"' values.yaml
	yq eval -i '.olm.catalogSourceImage = "perconalab/everest-catalog"' values.yaml
	yq eval -i '.everestOperator.channel = "fast-v0"' values.yaml

