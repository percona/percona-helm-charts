release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is not set."; \
		exit 1; \
	fi
	@for crd in templates/*.yaml; do \
		yq eval '.metadata.labels["helm.sh/chart-version"] = "$(VERSION)"' $$crd -i; \
	done

release-dev:
	@$(MAKE) release VERSION=0.0.0