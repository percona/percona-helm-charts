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

Install Percona Everest to the `everest-system` namespace:
```bash
helm repo add percona https://percona.github.io/percona-helm-charts/
helm install everest percona/everest --version 1.1.1 --namespace everest-system --create-namespace
```

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
