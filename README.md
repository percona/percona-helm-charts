# Percona Helm Charts

This repository contains Helm charts for various Percona products.

* [Percona XtraDB Cluster Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-database/)

## Installing Charts from this Repository

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
helm install percona/pxc-database
```
