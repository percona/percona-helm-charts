# Percona Helm Charts

This repository contains Helm charts for various Percona products.

* [Percona XtraDB Cluster Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)
* [Percona Server for MongoDB Operator](charts/psmdb-operator/)
* [Percona Server for MongoDB](charts/psmdb-db/)

## Installing Charts from this Repository

If you're using Helm2 please install CRD manually for Percona XtraDB Cluster Operator:
```bash
kubectl apply -f https://raw.githubusercontent.com/Percona-Lab/percona-helm-charts/master/charts/pxc-operator/crds/crd.yaml
```
or for Percona Server for MongoDB Operator:
```bash
kubectl apply -f https://raw.githubusercontent.com/percona/percona-helm-charts/master/charts/psmdb-operator/crds/crd.yaml
```

Add the Repository to Helm:

```bash
helm repo add percona https://percona-lab.github.io/percona-helm-charts
```

Install Percona XtraDB Cluster Operator:

```bash
helm install percona/pxc-operator
```

Install Percona XtraDB Cluster:

```bash
helm install percona/pxc-db
```

Install Percona Server for MongoDB Operator:

```bash
helm install percona/psmdb-operator
```

Install Percona Server for MongoDB:

```bash
helm install percona/psmdb-db
```
