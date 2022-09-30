# Percona Operator for Percona Server

Percona Operator for PS allows users to deploy and manage Percona Server Clusters based on async and group replication on Kubernetes.
Useful links:
- [Operator Github repository](https://github.com/percona/percona-server-mysql-operator)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-mysql/ps/index.html)

## Pre-requisites
* Kubernetes 1.20+
* Helm v3

# Installation

This chart will deploy the Operator Pod for the further Percona Server creation in Kubernetes.

## Installing the chart

To install the chart with the `ps` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-operator percona/ps-operator --version 0.3.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `image.repository`              | PS Operator Container image name                                              | `percona/percona-server-mysql-operator`   |
| `image.tag`                     | PS Operator Container image tag                                               | `0.3.0`                                   |
| `image.pullPolicy`              | PS Operator Container pull policy                                             | `Always`                                  |
| `image.pullSecrets`             | PS Operator Pod pull secret                                                   | `[]`                                      |
| `replicaCount`                  | PS Operator Pod quantity                                                      | `1`                                       |
| `tolerations`                   | List of node taints to tolerate                                               | `[]`                                      |
| `resources`                     | Resource requests and limits                                                  | `{}`                                      |
| `nodeSelector`                  | Labels for Pod assignment                                                     | `{}`                                      |
| `env.logStructured`             | Enable JSON format for logs                                                   | `false`                                   |
| `env.logLevel`                  | Set appropriate log level (INFO, DEBUG, ERROR)                                | `INFO`                                    |


Specify parameters using `--set key=value[,key=value]` argument to `helm install`

Alternatively a YAML file that specifies the values for the parameters can be provided like this:

```sh
helm install ps-operator -f values.yaml percona/ps-operator
```

## Deploy the database

To deploy Percona Server run the following command:

```sh
helm install my-db percona/ps-db
```

See more about Percona Server deployment in its chart [here](https://github.com/percona/percona-helm-charts/tree/main/charts/ps-db) or in the [Helm chart installation guide](https://www.percona.com/doc/kubernetes-operator-for-mysql/helm.html).
