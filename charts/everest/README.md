# Percona Everest
This helm chart deploys the components needed for Percona Everest.

Useful links:
- [Everest Github repository](https://github.com/percona/everest)
- [Everest Documentation](https://docs.percona.com/everest/index.html)

> NOTE: This Helm chart is currently in technical preview.

## Pre-requisites
* Kubernetes 1.27+
* At least `v3.2.3` version of helm

# Usage

## Installation

Insall Percona Everest in the `everest-system` namespace:

1. Create the `everest-system` namespace:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
    name: everest-system
    labels:
        everest.percona.com/namespace: ""
EOF
```
> NOTE: We recommend creating the `everest-system` namespace as a separate step. This is because specifying the `--create-namespace` flag with `helm install` does not support setting labels on the namespace.

2. Install the Helm chart:
```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install everest percona/everest --version 1.1.1 --namespace everest-system
```

> NOTE: Installing in any namespace other than `everest-system` can cause the installation to fail.

This command may take a couple of minutes to complete. Upon completion, you should see the following output:
```bash
NAME: everest
LAST DEPLOYED: Wed Sep 11 13:54:08 2024
NAMESPACE: everest-system
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

## Retrieving admin credentials
Upon installation, an `admin` user is created for you. To retrieve the password for the `admin` user, run the following command:
```bash
kubectl get secret everest-accounts -n everest-system -o jsonpath='{.data.users\.yaml}' | base64 --decode  | yq '.admin.passwordHash'
```

## Uninstallation
```bash
helm uninstall everest -n everest-system
```

# Configuration

The table below lists the configurable parameters of the Everest chart and their default values.

| Parameter                      | Description                                                                   | Default                 |
|--------------------------------|-------------------------------------------------------------------------------|-------------------------|
| image                          | Image to use for the Everest API server                                       | percona/everest         |
| olm.catalogSourceImage         | Name of the CatalogSource image that is used for installing all operators     | percona/everest-catalog |
| telemetry                      | If set, reports Telemetry information and usage data back to Percona          | true                    |
| vmOperator.channel             | Name of the OLM bundle channel to use for installing VictoriaMetrics operator | stable-v0               |
| everestOperator.channel        | Name of the OLM bundle channel to use for installing the Everest Operator     | stable-v0               |
| namespaces.[*].name            | Namespace where databases and database operators will be installed            |                         |
| namespaces.[*].mongodb.enabled | If set, PSMDB operator is installed in this namespace                         |                         |
| namespaces.[*].mongodb.channel | Name of the OLM bundle channel to use for installing PSMDB operator           | stable-v1               |
| namespaces.[*].pxc.enabled     | If set, PXC operator is installed in this namespace                           |                         |
| namespaces.[*].pxc.channel     | Name of the OLM bundle channel to use for installing PXC operator             | stable-v1               |
| namespaces.[*].pg.enabled      | If set, PG operator is installed in this namespace                            |                         |
| namespaces.[*].pg.channel      | Name of the OLM bundle channel to use for installing PG operator              | stable-v2               |
