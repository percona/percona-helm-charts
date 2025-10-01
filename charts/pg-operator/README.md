# Percona Operator for PostgreSQL
This helm chart deploys the Kubernetes Operator to manage Percona Distribution for PostgreSQL.

Useful links:
- [Operator Github repository](https://github.com/percona/percona-postgresql-operator/)
- [Operator Documentation](https://www.percona.com/doc/kubernetes-operator-for-postgresql/index.html)

A job will be created based on `helm` `install`, `upgrade`, or `uninstall`. After the
job has completed the RBAC will be cleaned up.

## Pre-requisites
* Kubernetes 1.30+
* At least `v3.2.3` version of helm

# Installation
This chart will deploy the Operator Pod for the further PostgreSQL creation in Kubernetes.
NOTE:
```
The PG Operator v2 is not directly compatible with old v1 so it is advised to always specify `--version`
when installing pg-operator or pg-db charts to not accidentally cause upgrade to v2 if you were using v1
previously.
```

## Installing the chart
To install the chart with the `pg-operator` release name using a dedicated namespace (recommended):

```sh
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install my-operator percona/pg-operator --version 2.7.0 --namespace my-namespace --create-namespace
```

## Configuration
The following shows the configurable parameters that are relevant to the Helm
Chart.

| Parameter            | Description                                                                        | Default                                               |
| -------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `image`              | PG Operator Container image full path                                              | `docker.io/percona/percona-postgresql-operator:2.7.0` |
| `imagePullPolicy`    | PG Operator Container pull policy                                                  | `Always`                                              |
| `resources`          | Resource requests and limits                                                       | `{}`                                                  |
| `nodeSelector`       | Labels for Pod assignment                                                          | `{}`                                                  |
| `logStructured`      | Force PG operator to print JSON-wrapped log messages                               | `false`                                               |
| `logLevel`           | PG Operator logging level                                                          | `INFO`                                                |
| `disableTelemetry`   | Disable sending PG Operator telemetry data to Percona                              | `false`                                               |
| `podAnnotations`     | Add annotations to the Operator Pod                                                | `{}`                                                  |
| `watchNamespace`     | Set this variable if the target cluster namespace differs from operators namespace | ``                                                    |
| `watchAllNamespaces` | K8S Cluster-wide operation                                                         | `false`                                               |

## Deploy the database
To deploy Percona Operator for PostgreSQL cluster with disabled telemetry run the following command:

```sh
helm install my-db percona/pg-db --version 2.7.0 --namespace my-namespace
```

See more about Percona Operator for PostgreSQL deployment in its chart [here](https://github.com/percona/percona-helm-charts/tree/main/charts/pg-db) or in the [Helm chart installation guide](https://www.percona.com/doc/kubernetes-operator-for-postgresql/helm.html).

# Need help?

**Commercial Support**  | **Community Support** |
:-: | :-: |
| <br/>Enterprise-grade assistance for your mission-critical database deployments in containers and Kubernetes. Get expert guidance for complex tasks like multi-cloud replication, database migration and building platforms.<br/><br/>  | <br/>Connect with our engineers and fellow users for general questions, troubleshooting, and sharing feedback and ideas.<br/><br/>  | 
| **[Get Percona Support](https://hubs.ly/Q02ZTH8Q0)** | **[Visit our Forum](https://forums.percona.com/)** |
