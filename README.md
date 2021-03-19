[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

# Percona Helm Charts

[Percona](https://www.percona.com/) is commited to simplify the deployment and management of databases on Kubernetes. [Helm](https://helm.sh/) enables users to package, run, share and manage even complex applications.
This repository contains Helm charts for the following Percona products.

* [Percona XtraDB Cluster Operator](charts/pxc-operator/)
* [Percona XtraDB Cluster](charts/pxc-db/)
* [Percona Server for MongoDB Operator](charts/psmdb-operator/)
* [Percona Server for MongoDB](charts/psmdb-db/)

Read more about Percona Kubernetes Operators [here](https://www.percona.com/software/percona-kubernetes-operators).

## Installing Charts from this Repository

You will need [Helm v3](https://github.com/helm/helm) for the installation.

See detailed installation instructions in the README file of each chart:

* [Percona XtraDB Cluster Operator](pxc-operator/README.md)
* [Percona XtraDB Cluster](pxc-db/README.md)
* [Percona Server for MongoDB Operator](psmdb-operator/README.md)
* [Percona Server for MongoDB](psmdb-db/README.md)

# Contributing

Percona welcomes and encourages community contributions to help improve Percona Kubernetes Operators as well as other Percona's projects.

See the [Contribution Guide](CONTRIBUTING.md) for more information.

# Submitting Bug Reports

If you find a bug related to one of these Helm charts, please submit a report to the appropriate project's Jira issue tracker:

* [Percona XtraDB Cluster Operator](https://jira.percona.com/projects/K8SPXC/)
* [Percona XtraDB Cluster](https://jira.percona.com/projects/PXC)
* [Percona Server for MongoDB Operator](https://jira.percona.com/projects/K8SPSMDB)
* [Percona Server for MongoDB](https://jira.percona.com/projects/PSMDB)

Learn more about submitting bugs, new features ideas and improvements in the [Contribution Guide](CONTRIBUTING.md).
