# Percona Helm Charts

This repository contains Helm charts for various Percona products.

* [Percona Distribution for MySQL Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)
* [Percona Distribution for MongoDB Operator](charts/psmdb-operator/)
* [Percona Server for MongoDB](charts/psmdb-db/)
* [Percona Distribution for PostgreSQL Operator](charts/pg-operator/)
* [Percona Distribution for PostgreSQL](charts/pg-db/)

To deploy and manage the databases you must deploy the corresponding Operator first.

## Installing Charts from this Repository

You will need Helm v3 for the installation.

Add the Repository to Helm:

```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm repo update
```

### Percona Distribution for MySQL Operator - quick start

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

### Percona Distribution for MongoDB Operator - quick start

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

### Percona Distribution for MongoDB PostgreSQL - quick start

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
