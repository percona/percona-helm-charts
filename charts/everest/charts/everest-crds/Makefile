VERSION ?= 0.0.0
release:
	@for crd in templates/*.yaml; do \
		yq eval '.metadata.labels["helm.sh/chart-version"] = "$(VERSION)"' $$crd -i; \
	done