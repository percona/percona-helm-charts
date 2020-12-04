# Overview

The Percona Kubernetes Operator for Percona Server for MongoDB automates the creation, modification, or deletion of items in your Percona Server for MongoDB environment. The Operator contains the necessary Kubernetes settings to maintain a consistent Percona Server for MongoDB instance.

The Percona Kubernetes Operators are based on best practices for the configuration of a Percona Server for MongoDB replica set. The Operator provides many benefits but saving time, a consistent environment are the most important.

## About Google Click to Deploy

Popular open stacks on Kubernetes packaged by Google.

## Architecture

![Architecture diagram](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/_images/operator.png)

A replica set consists of one primary server and several secondary ones, and the client application accesses the servers via a driver.

To provide high availability the Operator uses node affinity to run MongoDB instances on separate worker nodes if possible, and the database cluster is deployed as a single Replica Set with at least three nodes. If a node fails, the pod with the mongod process is automatically re-created on another node. If the failed node was hosting the primary server, the replica set initiates elections to select a new primary. If the failed node was running the Operator, Kubernetes will restart the Operator on another node, so normal operation will not be interrupted.

Client applications should use a mongo+srv URI for the connection. This allows the drivers (3.6 and up) to retrieve the list of replica set members from DNS SRV entries without having to list hostnames for the dynamically assigned nodes.

To provide data storage for stateful applications, Kubernetes uses Persistent Volumes. A PersistentVolumeClaim (PVC) is used to implement the automatic storage provisioning to pods. If a failure occurs, the Container Storage Interface (CSI) should be able to re-mount storage on a different node. The PVC StorageClass must support this feature.

# Installation

## Quick install with Google Cloud Marketplace

Get up and running with a few clicks! Install this app to a
Google Kubernetes Engine cluster using Google Cloud Marketplace. Follow the
[on-screen instructions](https://console.cloud.google.com/marketplace/details/percona/percona-server-mongodb-operator).

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
export CLUSTER=psmdb-cluster
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

### Install Percona Kubernetes Operator for Percona Server for MongoDB

Navigate to the `psmdb-operator` directory:

```shell
cd percona-helm-charts/charts/gcp-marketplace/psmdb-operator
```

#### Configure the environment variables

Choose an instance name and
[namespace](https://kubernetes.io/docs/concepts/overview/working-with-objects/namespaces/)
for the app. In most cases, you can use the `default` namespace.

```shell
export APP_INSTANCE_NAME=psmdb-operator
export NAMESPACE=default
```

Set up the image tag:

It is advised to use stable image reference which you can find on
[Marketplace Container Registry](https://marketplace.gcr.io/google/psmdb-operator).
Example:

```shell
export TAG="1.5.0"
```

Configure the container image:

```shell
export IMAGE_REGISTRY="marketplace.gcr.io"
export IMAGE_OPERATOR="google/percona/percona-server-mongodb-operator"
export IMAGE_MONGODB="${IMAGE_OPERATOR}/psmdb"
export IMAGE_BACKUP="${IMAGE_OPERATOR}/backup"
export IMAGE_PMM="${IMAGE_OPERATOR}/pmm"
export TAG_MONGODB="4.2"
```

Set the number of replicas for Percona Server for MongoDB:

```shell
export REPLICAS=3
```

For the persistent disk provisioning of the Percona Server for MongoDB StatefulSets, you will need to:

 * Set the persistent disk's size. The default disk size is "32Gi".

```shell
export MONGODB_DATADIR_SIZE="32Gi"
```

#### Create namespace in your Kubernetes cluster

If you use a different namespace than the `default`, run the command below to create a new namespace:

```shell
kubectl create namespace "$NAMESPACE"
```

##### Create dedicated Service accounts

Define the environment variables:

```shell
export OPERATOR_SERVICE_ACCOUNT="${APP_INSTANCE_NAME}-sa"
export CRD_SERVICE_ACCOUNT="${APP_INSTANCE_NAME}-crd-creator-job"
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
helm template ${APP_INSTANCE_NAME} chart/psmdb-operator \
  --namespace ${NAMESPACE} \
  --set operator.image.registry=${IMAGE_REGISTRY} \
  --set operator.image.repository=${IMAGE_OPERATOR} \
  --set operator.image.tag=${TAG} \
  --set psmdb42.image.repository=${IMAGE_MONGODB}-4.2 \
  --set psmdb40.image.repository=${IMAGE_MONGODB}-4.0 \
  --set psmdb36.image.repository=${IMAGE_MONGODB}-3.6 \
  --set backup.image.registry=${IMAGE_REGISTRY} \
  --set backup.image.repository=${IMAGE_BACKUP} \
  --set backup.image.tag=${TAG} \
  --set pmm.image.registry=${IMAGE_REGISTRY} \
  --set pmm.image.repository=${IMAGE_PMM} \
  --set pmm.image.tag=${TAG} \
  --set deployerHelm.image="gcr.io/cloud-marketplace-tools/k8s/deployer_helm:0.8.0" \
  --set operator.serviceAccountName=${OPERATOR_SERVICE_ACCOUNT} \
  --set CDRJobServiceAccount=${CRD_SERVICE_ACCOUNT} \
  --set psmdb.image.registry=${IMAGE_REGISTRY} \
  --set psmdb.image.tag=${TAG} \
  --set psmdb.image.version=${TAG_MONGODB} \
  --set psmdb.datadirSize=${MONGODB_DATADIR_SIZE} \
  --set psmdb.replicas=${REPLICAS} \
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

### Access Percona Server for MongoDB within the network

You can connect to Percona Server for MongoDB without exposing it to public access, using the
`mongo` command line interface. We recommend making all connection via the corresponding network service.

The user credentials are configured on application start up by the operator. More information about user management
could be found [here](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/users.html)

#### Connect to Percona Server for MongoDB using a client Pod

Run percona-client and connect its console output to your terminal (running it may require some time to deploy the correspondent Pod):

```shell
kubectl run -i --rm --tty percona-client --image=percona/percona-server-mongodb:4.2.8-8 --restart=Never \
            --env MONGO_USER=$(kubectl get secret/${APP_INSTANCE_NAME}-secrets -o jsonpath='{.data.MONGODB_USER_ADMIN_USER}' | base64 -d) \
            --env MONGO_PASSWORD=$(kubectl get secret/${APP_INSTANCE_NAME}-secrets -o jsonpath='{.data.MONGODB_USER_ADMIN_PASSWORD}' | base64 -d) \
            --env NAMESPACE=${NAMESPACE} \
            --env NAME=${APP_INSTANCE_NAME} \
            -- bash -il
#wait for shell and than run
mongo "mongodb+srv://${MONGO_USER}:${MONGO_PASSWORD}@${NAME}-rs0.${NAMESPACE}.svc.cluster.local/admin?replicaSet=rs0&ssl=false"
```

### Access Percona Server for MongoDB through an external IP address

By default, the application does not have an external IP address. To create an external IP address, run the following command:

```
kubectl patch psmdb "${APP_INSTANCE_NAME}" \
  --namespace "${NAMESPACE}" \
  --type=json \
  -p '[{"op":"replace","path":"/spec/replsets/0/expose/enabled","value":"true"}]'
```
It adds loadbalancer services to every pod available.

> **NOTE:** It might take some time for the external IP to be provisioned.

### Access the Percona Server for MongoDB service

**Option 1:** If you run your Percona Server for MongoDB cluster behind a LoadBalancer, you can get the external IP of the instance using the following command:

```shell
EXTERNAL_IP-0=$(kubectl get svc ${APP_INSTANCE_NAME}-rs0-0 \
  --namespace ${NAMESPACE} \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "${EXTERNAL_IP-0}"
```

If your number of mongodb replicas bigger than one, you can find additional external IPs
```shell
EXTERNAL_IP-1=$(kubectl get svc ${APP_INSTANCE_NAME}-rs0-1 \
  --namespace ${NAMESPACE} \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "${EXTERNAL_IP-1}"
...
EXTERNAL_IP-<N>=$(kubectl get svc ${APP_INSTANCE_NAME}-rs0-<N> \
  --namespace ${NAMESPACE} \
  --output jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "${EXTERNAL_IP-<N>}"
```


```bash
# connect to mongodb server
mongo "mongodb://<user>:<password@${EXTERNAL_IP-0}:27017/admin?ssl=false\&replicaSet=rs0"
# also multiple addresses could be used
mongo "mongodb://<user>:<password@${EXTERNAL_IP-0},${EXTERNAL_IP-1}...${EXTERNAL_IP-N}:27017/admin?ssl=false\&replicaSet=rs0"
```

# Scaling

## Scaling the cluster up or down

By default, Percona Server for MongoDB application is deployed using 3 replicas.
To change the number of replicas, use the following command:

```
kubectl patch psmdb "${APP_INSTANCE_NAME}" \
  --namespace "${NAMESPACE}" \
  --type=json \
  -p '[{"op":"replace","path":"/spec/replsets/0/size","value":'${REPLICAS}'}]'
```

Where `REPLICAS` is the number of replicas you want.

# Backup and Restore

The detailed set of steps for backup and restores you can find here [Backups and Restores documentation](https://www.percona.com/doc/kubernetes-operator-for-psmongodb/backups.html).

# Uninstall the Application

## Using the Google Cloud Platform Console

1. In the GCP Console, open [Kubernetes Applications](https://console.cloud.google.com/kubernetes/application).

1. From the list of applications, click **Percona Server MongoDB Operator**.

1. On the Application Details page, click **Delete**.

## Using the command line

### Prepare the environment

Set your installation name and Kubernetes namespace:

```shell
export APP_INSTANCE_NAME=psmdb-operator
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
export APP_INSTANCE_NAME=psmdb-operator
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