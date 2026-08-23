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

# pmm-ha's backup orchestrator (charts/pmm-ha/files/pmm-backup.sh) carries its own suites,
# because the bugs it keeps citing in its comments are invisible to `sh -n`: a `set -u` read of
# a variable a refactor deleted, a dash-only expansion, a helper whose non-zero return aborts
# the run between the upload and the manifest write. Run these before touching that file.
# The same two suites run in .github/workflows/pmm-ha-pr-checks.yaml.
SH ?= sh

.PHONY: test-pmm-backup
test-pmm-backup: lint-pmm-backup
	$(SH) charts/pmm-ha/tests/pmm-backup-unit.sh

.PHONY: lint-pmm-backup
lint-pmm-backup:
	$(SH) -n charts/pmm-ha/files/pmm-backup.sh
	$(SH) charts/pmm-ha/tests/pmm-backup-lint.sh
