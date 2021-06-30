# psmdb-operator: A chart for installing the Percona Kubernetes operator for MongoDB

This chart implements Percona Server MongoDB operator deployment. The Operator itself can be found here:
* <https://github.com/percona/percona-server-mongodb-operator>

## Pre-requisites
* Kubernetes 1.16+
* PV support on the underlying infrastructure - only if you are provisioning persistent volume(s).
* At least `v2.5.0` version of helm

## Deployment Details
* <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>

## Chart Details
This chart will:
* deploy a PSMDB Operator Pod for the further MongoDB creation in K8S.

### Installing the Chart
To install the chart with the `psmdb` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-operator percona/psmdb-operator --version 1.9.0 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `image.repository`              | PSMDB Operator Container image name                                           | `percona/percona-server-mongodb-operator` |
| `image.tag`                     | PSMDB Operator Container image tag                                            | `1.9.0`                                   |
| `image.pullPolicy`              | PSMDB Operator Container pull policy                                          | `Always`                                  |
| `image.pullSecrets`             | PSMDB Operator Pod pull secret                                                | `[]`                                      |
| `replicaCount`                  | PSMDB Operator Pod quantity                                                   | `1`                                       |
| `tolerations`                   | List of node taints to tolerate                                               | `[]`                                      |
| `resources`                     | Resource requests and limits                                                  | `{}`                                      |
| `nodeSelector`                  | Labels for Pod assignment                                                     | `{}`                                      |
| `watchNamespace`                | Set when a different from default namespace is needed to watch                | `""`                                      |

Specify parameters using `--set key=value[,key=value]` argument to `helm install`

Alternatively a YAML file that specifies the values for the parameters can be provided like this:

```sh
helm install psmdb-operator -f values.yaml percona/psmdb-operator
```
