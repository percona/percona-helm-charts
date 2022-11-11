[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Percona Helm Charts

[Percona](https://www.percona.com/) is committed to simplify the deployment and management of databases on Kubernetes. [Helm](https://helm.sh/) enables users to package, run, share and manage even complex applications.
This repository contains Helm charts for the following Percona products.

* [Percona Operator for MySQL](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)
* [Percona Operator for MongoDB](charts/psmdb-operator/)
* [Percona Server for MongoDB](charts/psmdb-db/)
* [Percona Operator for PostgreSQL](charts/pg-operator/)
* [Percona Distribution for PostgreSQL](charts/pg-db/)
* [Percona Monitoring and Management (PMM)](charts/pmm/)

Useful links:
* [About Percona Kubernetes Operators](https://www.percona.com/software/percona-kubernetes-operators)
* [About Percona Monitoring and Management](https://www.percona.com/software/database-tools/percona-monitoring-and-management)

## Installing Charts from this Repository

You will need [Helm v3](https://github.com/helm/helm) for the installation. See detailed installation instructions in the README file of each chart.

# Contributing

Percona welcomes and encourages community contributions to help improve Percona Kubernetes Operators as well as other Percona's projects.

See the [Contribution Guide](CONTRIBUTING.md) for more information.

# Submitting Bug Reports

If you find a bug related to one of these Helm charts, please submit a report to the appropriate project's Jira issue tracker:

* [Percona Operator for MySQL](https://jira.percona.com/projects/K8SPXC)
* [Percona Operator for MongoDB](https://jira.percona.com/projects/K8SPSMDB)
* [Percona Operator for PostgreSQL](https://jira.percona.com/projects/K8SPG)
* [Percona Monitoring and Management](https://jira.percona.com/projects/PMM)

Learn more about submitting bugs, new feature ideas, and improvements in the [Contribution Guide](CONTRIBUTING.md).
