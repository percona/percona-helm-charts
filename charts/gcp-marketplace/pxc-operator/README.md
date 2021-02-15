# Overview

The Percona Kubernetes Operator for Percona XtraDB Cluster automates the creation, modification, or deletion of items in your Percona Server for MySQL running with the XtraDB storage engine, and Percona XtraBackup with the Galera library to enable synchronous multi-primary replication. The Operator contains the necessary Kubernetes settings to maintain a consistent Percona XtraDB Cluster instance.

The Percona Kubernetes Operators are based on best practices for the configuration of a Percona XtraDB Cluster. The Operator provides many benefits but saving time, a consistent environment are the most important.

## About Google Click to Deploy

Popular open stacks on Kubernetes packaged by Google.

## Architecture

![Architecture diagram](https://www.percona.com/doc/kubernetes-operator-for-pxc/_images/operator.png)

Being a regular MySQL Server instance, each node contains the same set of data synchronized accross nodes. The recommended configuration is to have at least 3 nodes. In a basic setup with this amount of nodes, Percona XtraDB Cluster provides high availability, continuing to function if you take any of the nodes down. Additionally load balancing can be achieved with the ProxySQL daemon, which accepts incoming traffic from MySQL clients and forwards it to backend MySQL servers.

To provide data storage for stateful applications, Kubernetes uses Persistent Volumes. A PersistentVolumeClaim (PVC) is used to implement the automatic storage provisioning to pods. If a failure occurs, the Container Storage Interface (CSI) should be able to re-mount storage on a different node. The PVC StorageClass must support this feature (Kubernetes and OpenShift support this in versions 1.9 and 3.9 respectively).

The Operator functionality extends the Kubernetes API with PerconaXtraDBCluster object, and it is implemented as a golang application. Each PerconaXtraDBCluster object maps to one separate Percona XtraDB Cluster setup. The Operator listens to all events on the created objects. When a new PerconaXtraDBCluster object is created, or an existing one undergoes some changes or deletion, the operator automatically creates/changes/deletes all needed Kubernetes objects with the appropriate settings to provide a proper Percona XtraDB Cluster operation.

# Installation

## Quick install with Google Cloud Marketplace

Get up and running with a few clicks! Install this app to a
Google Kubernetes Engine cluster using Google Cloud Marketplace. Follow the
[on-screen instructions](https://console.cloud.google.com/marketplace/details/percona/percona-xtradb-cluster-operator).

## Command line instructions

### Prerequisites

#### Set up command-line tools

You'll need the following tools in your development environment. If you are using Cloud Shell, these tools are installed in your environment.

- [gcloud](https://cloud.google.com/sdk/gcloud/)
- [kubectl](https://kubernetes.io/docs/reference/kubectl/overview/)
- [docker](https://docs.docker.com/install/)
- [git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
- [helm](https://helm.sh/)

Configure `gcloud` as a Docker credential helper:

```shell
gcloud auth configure-docker
```

#### Create a Google Kubernetes Engine (GKE) cluster

Create a new cluster from the command line:

```shell
export CLUSTER=pxc-cluster
export ZONE=us-west1-a

gcloud container clusters create "$CLUSTER" --zone "$ZONE"
```

Configure `kubectl` to connect to the new cluster.

```shell
gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE"
```

#### Clone this repo

Clone this repo and the associated tools repo:

```shell
git clone --recursive https://github.com/percona/percona-helm-charts
```

#### Install the Application resource definition

An Application resource is a collection of individual Kubernetes components,
such as Services, Deployments, and so on, that you can manage as a group.

To set up your cluster to understand Application resources, run the following command:

```shell
kubectl apply -f "https://raw.githubusercontent.com/GoogleCloudPlatform/marketplace-k8s-app-tools/master/crd/app-crd.yaml"
```

You need to run this command once.

The Application resource is defined by the
[Kubernetes SIG-apps](https://github.com/kubernetes/community/tree/master/sig-apps) community. The source code can be found on
[github.com/kubernetes-sigs/application](https://github.com/kubernetes-sigs/application).

### Install Percona Kubernetes Operator for Percona XtraDB Cluster

Navigate to the `pxc-operator` directory:

```shell
cd percona-helm-charts/charts/gcp-marketplace/pxc-operator
```

#### Configure the environment variables

Choose an instance name and
[namespace](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
for the app. In most cases, you can use the `default` namespace.

```shell
export APP_INSTANCE_NAME=pxc-operator
export NAMESPACE=default
```

Set up the image tag:

It is advised to use stable image reference which you can find on
[Marketplace Container Registry](https://marketplace.gcr.io/google/pxc-operator).
Example:

```shell
export TAG="1.7.0"
```

Configure the container image:

```shell
export IMAGE_REGISTRY="marketplace.gcr.io"
export IMAGE_OPERATOR="google/percona-public/percona-xtradb-cluster-operator"
export IMAGE_PROXYSQL="${IMAGE_OPERATOR}/proxysql"
export IMAGE_HAPROXY="${IMAGE_OPERATOR}/haproxy"
export IMAGE_LOGCOLLECTOR="${IMAGE_OPERATOR}/logcollector"
export IMAGE_PXC_80="${IMAGE_OPERATOR}/pxc80"
export IMAGE_BACKUP_80="${IMAGE_OPERATOR}/pxc80backup"
export IMAGE_PXC_57="${IMAGE_OPERATOR}/pxc57"
export IMAGE_BACKUP_57="${IMAGE_OPERATOR}/pxc57backup"
export TARGET_PXC_VERSION="8.0.21-12.1"
```

Set the number of nodes for Percona Xtradb Cluster:

```shell
export REPLICAS=3
```

For the persistent disk provisioning of the Percona Xtradb Cluster StatefulSet, you will need to:

 * Set the persistent disk's size. The default disk size is "32Gi".

```shell
export PXC_DATADIR_SIZE="32Gi"
```

#### Create namespace in your Kubernetes cluster

If you use a different namespace than the `default`, run the command below to create a new namespace:

```shell
kubectl create namespace "$NAMESPACE"
```

##### Create dedicated Service accounts

Define the environment variables:

```shell
export OPERATOR_SERVICE_ACCOUNT="${APP_INSTANCE_NAME}-operator-serviceaccountname"
export CRD_SERVICE_ACCOUNT="${APP_INSTANCE_NAME}-cdrjobserviceaccount"
```

Expand the manifest to create Service accounts:

```shell
cat resources/service-accounts.yaml \
  | envsubst '${NAMESPACE} \
              ${OPERATOR_SERVICE_ACCOUNT} \
              ${CRD_SERVICE_ACCOUNT}' \
    > "${APP_INSTANCE_NAME}_sa_manifest.yaml"
```

Create the accounts on the cluster with `kubectl`:

```shell
kubectl apply -f "${APP_INSTANCE_NAME}_sa_manifest.yaml" \
    --namespace "${NAMESPACE}"
```

#### Expand the manifest template

Use `helm template` to expand the template. We recommend that you save the
expanded manifest file for future updates to the application.

```shell
helm template ${APP_INSTANCE_NAME} chart/pxc-operator \
  --namespace ${NAMESPACE} \
  --set operator.image.registry=${IMAGE_REGISTRY} \
  --set operator.image.repository=${IMAGE_OPERATOR} \
  --set operator.image.tag=${TAG} \
  --set logcollector.image.registry=${IMAGE_REGISTRY} \
  --set logcollector.image.repository=${IMAGE_LOGCOLLECTOR} \
  --set logcollector.image.tag=${TAG} \
  --set proxysql.image.registry=${IMAGE_REGISTRY} \
  --set proxysql.image.repository=${IMAGE_PROXYSQL} \
  --set proxysql.image.tag=${TAG} \
  --set haproxy.image.registry=${IMAGE_REGISTRY} \
  --set haproxy.image.repository=${IMAGE_HAPROXY} \
  --set haproxy.image.tag=${TAG} \
  --set pxc80.image.registry=${IMAGE_REGISTRY} \
  --set pxc80.image.repository=${IMAGE_PXC_80} \
  --set pxc80.image.tag=${TAG} \
  --set pxc80backup.image.registry=${IMAGE_REGISTRY} \
  --set pxc80backup.image.repository=${IMAGE_BACKUP_80} \
  --set pxc80backup.image.tag=${TAG} \
  --set pxc57.image.registry=${IMAGE_REGISTRY} \
  --set pxc57.image.repository=${IMAGE_PXC_57} \
  --set pxc57.image.tag=${TAG} \
  --set pxc57backup.image.registry=${IMAGE_REGISTRY} \
  --set pxc57backup.image.repository=${IMAGE_BACKUP_57} \
  --set pxc57backup.image.tag=${TAG} \
  --set pxc.version=${TARGET_PXC_VERSION} \
  --set pxc.datadir.size=${PXC_DATADIR_SIZE} \
  --set pxc.replicas=${REPLICAS} \
  --set deployerHelm.image="gcr.io/cloud-marketplace-tools/k8s/deployer_helm:0.8.0" \
  --set operator.serviceAccountName=${OPERATOR_SERVICE_ACCOUNT} \
  --set CDRJobServiceAccount=${CRD_SERVICE_ACCOUNT} \
  > ${APP_INSTANCE_NAME}_manifest.yaml
```

#### Apply the manifest to your Kubernetes cluster

Use `kubectl` to apply the manifest to your Kubernetes cluster:

```shell
kubectl apply -f "${APP_INSTANCE_NAME}_manifest.yaml" --namespace "${NAMESPACE}"
```

#### View the app in the Google Cloud Platform Console

To get the Console URL for your app, run the following command:

```shell
echo "https://console.cloud.google.com/kubernetes/application/${ZONE}/${CLUSTER}/${NAMESPACE}/${APP_INSTANCE_NAME}"
```

To view the app, open the URL in your browser.

### Access Percona XtraDB Cluster within the network

You can connect to Percona XtraDB Cluster without exposing it to public access, using the
`mysql` command line interface. We recommend making all connection via the corresponding network service.

The user credentials are configured on application start up by the operator. More information about user management
could be found [here](https://www.percona.com/doc/kubernetes-operator-for-pxc/users.html)

#### Connect to Percona XtraDB Cluster using a client Pod

Run percona-client and connect its console output to your terminal (running it may require some time to deploy the correspondent Pod):

```shell
kubectl run -i --rm --tty percona-client --image=percona:8.0 --restart=Never \
            --env MYSQL_PASSWORD=$(kubectl get secret/${APP_INSTANCE_NAME}-secrets -o jsonpath='{.data.root}' | base64 -d) \
            --env NAMESPACE=${NAMESPACE} \
            --env NAME=${APP_INSTANCE_NAME} \
            -- bash -il
#wait for shell and than run
mysql -h ${NAME}-haproxy -uroot -p${MYSQL_PASSWORD}
```

# Scaling

## Scaling the cluster up or down

By default, Percona XtraDB Cluster application is deployed using 3 replicas.
To change the number of replicas, use the following command:

```
kubectl patch pxc "${APP_INSTANCE_NAME}" \
  --namespace "${NAMESPACE}" \
  --type=json \
  -p '[{"op":"replace","path":"/spec/pxc/size","value":'${REPLICAS}'}]'
```

Where `REPLICAS` is the number of replicas you want.

# Backup and Restore

The detailed set of steps for backup and restores you can find here [Backups and Restores documentation](https://www.percona.com/doc/kubernetes-operator-for-pxc/backups.html).

# Uninstall the Application

## Using the Google Cloud Platform Console

1. In the GCP Console, open [Kubernetes Applications](https://console.cloud.google.com/kubernetes/application).

1. From the list of applications, click **Percona Kubernetes Operator for Percona XtraDB Cluster**.

1. On the Application Details page, click **Delete**.

## Using the command line

### Prepare the environment

Set your installation name and Kubernetes namespace:

```shell
export APP_INSTANCE_NAME=pxc-operator
export NAMESPACE=default
```

### Delete the resources

> **NOTE:** We recommend using a `kubectl` version that is the same as the version of your cluster. Using the same versions of `kubectl` and the cluster helps avoid unforeseen issues.

To delete the resources, use the expanded manifest file used for the
installation.

Run `kubectl` on the expanded manifest file:

```shell
kubectl delete -f ${APP_INSTANCE_NAME}_manifest.yaml --namespace $NAMESPACE
```

Otherwise, delete the resources using types and a label:

```shell
kubectl delete application \
  --namespace $NAMESPACE \
  --selector app.kubernetes.io/name=$APP_INSTANCE_NAME
```

### Delete the persistent volumes of your installation

By design, the removal of StatefulSets in Kubernetes does not remove
PersistentVolumeClaims that were attached to their Pods. This prevents your
installations from accidentally deleting stateful data.

To remove the PersistentVolumeClaims with their attached persistent disks, run
the following `kubectl` commands:

```shell
# specify the variables values matching your installation:
export APP_INSTANCE_NAME=pxc-operator
export NAMESPACE=default

kubectl delete persistentvolumeclaims \
  --namespace $NAMESPACE \
  --selector app.kubernetes.io/name=$APP_INSTANCE_NAME
```

### Delete the GKE cluster

Optionally, if you don't need the deployed application or the GKE cluster,
delete the cluster using this command:

```shell
gcloud container clusters delete "$CLUSTER" --zone "$ZONE"
```