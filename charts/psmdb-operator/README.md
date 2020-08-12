# psmdb-operator: A chart for installing the Percona Kubernetes operator for MongoDB

This is an implementation of PSMDB operator Deployment and other stuff could be found here:
* <https://github.com/percona/percona-server-mongodb-operator>

## Pre Requisites
* Kubernetes 1.11+
* PV support on underlying infrastructure (only if you are provisioning persistent volume).
* Requires at least `v2.4.0` version of helm to support

## Deloyment Details
* <https://kubernetes.io/docs/concepts/workloads/controllers/deployment/>

## Chart Details
This chart will do the following:
* Deploy PSMDB operator pod for the further MongoDB creation inside K8S

### Installing the Chart
To install the chart with the release name `psmdb` using a dedicated namespace(recommended):

```sh
helm repo add percona https://percona-lab.github.io/percona-helm-charts/
helm install percona/psmdb-operator --version 0.1.9 --namespace my-namespace
```

The chart can be customized using the following configurable parameters:

| Parameter                       | Description                                                                   | Default                                   |
| ------------------------------- | ------------------------------------------------------------------------------| ------------------------------------------|
| `image.repository`              | PSMDB operator container image name                                           | `percona/percona-server-mongodb-operator` |
| `image.tag`                     | PSMDB operator container image tag                                            | `1.4.0`                                   |
| `image.pullPolicy`              | PSMDB operator container pull policy                                          | `Always`                                  |
| `image.pullSecrets`             | PSMDB operator pod pull secret                                                | `[]`                                      |
| `replicaCount`                  | PSMDB operator pod quantity                                                   | `1`                                       |
| `tolerations`                   | List of node taints to tolerate                                               | `[]`                                      |
| `resources`                     | Resource requests and limits                                                  | `{}`                                      |
| `nodeSelector`                  | Labels for pod assignment                                                     | `{}`                                      |
| `watchNamespace`                | Set if you want to specify a namespace to watch                               | `""`                                      |
| `nameOverride`                  | Set if you want to use a different operator name                              | `""`                                      |
| `fullnameOverride`              | Set if DO NOT want to see chart name in the operators' name                   | `""`                                      |
| `createCRD`                     | set to false if you don't want the helm chart to automatically create the CRD | `true`                                    |
| `env.resyncPeriod`              | Period for syncing operator with DB                                           | `5s`                                      |
| `env.logVerbose`                | Enable/Disable operator verbose logging                                       | `false`                                   |

Specify parameters using `--set key=value[,key=value]` argument to `helm install`

Alternatively a YAML file that specifies the values for the parameters can be provided like this:

```sh
helm install --name psmdb-operator -f values.yaml percona/psmdb-operator
```