HELM ?= helm

PSMDB_CRD_SRC ?= charts/psmdb-operator/crds/crd.yaml
PSMDB_CRD_DST ?= charts/psmdb-operator-crds/templates

.PHONY: split-psmdb-crds
split-psmdb-crds:
	@rm -f $(PSMDB_CRD_DST)/*.psmdb.percona.com.yaml
	@awk -v dst="$(PSMDB_CRD_DST)" ' \
		function flush() { \
			if (name != "" && buf != "") { printf "%s", buf > (dst "/" name ".yaml") } \
			buf = ""; name = "" \
		} \
		/^---[[:space:]]*$$/ { flush(); next } \
		{ \
			buf = buf $$0 "\n"; \
			if ($$0 ~ /^  name: .*\.psmdb\.percona\.com[[:space:]]*$$/) { name = $$2 } \
		} \
		END { flush() } \
	' $(PSMDB_CRD_SRC)
	@echo "Split $(PSMDB_CRD_SRC) into $(PSMDB_CRD_DST)"

.PHONY: helm-unittest
helm-unittest:
	$(HELM) plugin install https://github.com/helm-unittest/helm-unittest.git

.PHONY: test
test: test-pxc-operator test-pxc-db

.PHONY: test-pxc-operator
test-pxc-operator:
	$(HELM) unittest charts/pxc-operator

.PHONY: test-pxc-db
test-pxc-db:
	$(HELM) unittest charts/pxc-db
