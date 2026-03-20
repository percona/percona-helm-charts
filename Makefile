HELM ?= helm

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
