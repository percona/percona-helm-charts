# Percona Helm Charts

This repository contains Percona supported Helm charts to deploy MySQL, PostgreSQL and MongoDB clusters on Kubernetes.
To deploy and manage the databases you must deploy the corresponding Operator first.

Helm charts in this repository:

* [Percona Distribution for MySQL Operator](https://github.com/percona/percona-helm-charts/blob/main/charts/pxc-operator)
* [Percona XtraDB Cluster](https://github.com/percona/percona-helm-charts/blob/main/charts/pxc-db)
* [Percona Distribution for MongoDB Operator](https://github.com/percona/percona-helm-charts/blob/main/charts/psmdb-operator)
* [Percona Server for MongoDB](https://github.com/percona/percona-helm-charts/blob/main/charts/psmdb-db)
* [Percona Distribution for PostgreSQL Operator](https://github.com/percona/percona-helm-charts/blob/main/charts/pg-operator)
* [Percona Distribution for PostgreSQL](https://github.com/percona/percona-helm-charts/blob/main/charts/pg-db)

# Quick start installation

You will need Helm v3 for the installation.

Add the Repository to Helm:

```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
```

## Percona Distribution for MySQL Operator

Install the Operator:

```bash
helm install my-op percona/pxc-operator
```

Install Percona XtraDB Cluster:

```bash
helm install my-db percona/pxc-db
```

See more details in:
- [Helm installation documentation](https://www.percona.com/doc/kubernetes-operator-for-pxc/helm.html)
- [Operator chart parameter reference](https://github.com/percona/percona-helm-charts/tree/main/charts/pxc-operator)
- [Percona XtraDB Cluster parameters reference](https://github.com/percona/percona-helm-charts/tree/main/charts/pxc-db)

## Percona Distribution for MongoDB Operator

Install the Operator:

```bash
helm install my-op percona/psmdb-operator
```

Install Percona Server for MongoDB:

```bash
helm install my-db percona/psmdb-db
```

See more details in:
- [Helm installation documentation](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/helm.html)
- [Operator chart parameter reference](https://github.com/percona/percona-helm-charts/blob/main/charts/psmdb-operator)
- [Percona Server for MongoDB parameters reference](https://github.com/percona/percona-helm-charts/blob/main/charts/psmdb-db)

## Percona Distribution for PostgreSQL Operator

Install the Operator:

```bash
helm install my-operator percona/pg-operator
```

Install Percona Distribution for PostgreSQL:

```bash
helm install my-db percona/pg-db 
```

See more details in:
- [Helm installation documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html)
- [Operator chart parameter reference](https://github.com/percona/percona-helm-charts/blob/main/charts/pg-operator)
- [Percona Distribution for PostgreSQL parameters reference](https://github.com/percona/percona-helm-charts/blob/main/charts/pg-db)
