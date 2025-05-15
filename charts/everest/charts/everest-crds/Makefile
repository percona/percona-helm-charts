release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is not set."; \
		exit 1; \
	fi
	@for crd in templates/*.yaml; do \
		yq eval '.metadata.labels["everest.percona.com/version"] = "$(VERSION)"' $$crd -i; \
	done

release-dev:
	@$(MAKE) release VERSION=0.0.0