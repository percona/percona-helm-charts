# Percona Helm Charts

This repository contains Helm charts for various Percona products.

* [Percona XtraDB Cluster Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)

## Installing Charts from this Repository

If you're using Helm2 please install CRD manually:
```bash
kubectl apply -f https://raw.githubusercontent.com/Percona-Lab/percona-helm-charts/master/charts/pxc-operator/crds/crd.yaml
```

Add the Repository to Helm:

```bash
helm repo add percona https://percona-lab.github.io/percona-helm-charts
```

Install Percona Operator:

```bash
helm install percona/pxc-operator
```

Install Percona Cluster:

```bash
helm install percona/pxc-db
```
