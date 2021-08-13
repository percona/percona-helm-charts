[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Percona Helm Charts

[Percona](https://www.percona.com/) is committed to simplify the deployment and management of databases on Kubernetes. [Helm](https://helm.sh/) enables users to package, run, share and manage even complex applications.
This repository contains Helm charts for the following Percona products.

* [Percona Distribution for MySQL Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)
* [Percona Distribution for MongoDB Operator](charts/psmdb-operator/)
* [Percona Server for MongoDB](charts/psmdb-db/)
* [Percona Distribution for PostgreSQL Operator](charts/pg-operator/)
* [Percona Distribution for PostgreSQL](charts/pg-db/)

Read more about Percona Kubernetes Operators [here](https://www.percona.com/software/percona-kubernetes-operators).

## Installing Charts from this Repository

You will need [Helm v3](https://github.com/helm/helm) for the installation. See detailed installation instructions in the README file of each chart.

# Contributing

Percona welcomes and encourages community contributions to help improve Percona Kubernetes Operators as well as other Percona's projects.

See the [Contribution Guide](CONTRIBUTING.md) for more information.

# Submitting Bug Reports

If you find a bug related to one of these Helm charts, please submit a report to the appropriate project's Jira issue tracker:

* [Percona Distribution for MySQL Operator](https://jira.percona.com/projects/K8SPXC)
* [Percona Distribution for MongoDB Operator](https://jira.percona.com/projects/K8SPSMDB)
* [Percona Distribution for PostgreSQL Operator](https://jira.percona.com/projects/K8SPG)

Learn more about submitting bugs, new feature ideas, and improvements in the [Contribution Guide](CONTRIBUTING.md).
