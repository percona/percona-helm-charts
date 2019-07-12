# pxc-operator: A chart for installing the Percona XtraDB Cluster Operator

This Helm Chart will deploy the Percona XtraDB Cluster Operator on Kubernetes.

To deploy the Operator clone down this repository and run:

```bash
$ helm install .
```

Operators need to be provided a namespace to watch for CRD requests, by default it will watch the namespace the CRD is installed into, if you want to watch a different namespace you can do the following:

```bash
$ helm install . --set watchNamespace=my-namespace
```

If you need to install the Operator more than once you should disable CRD creation like so:

```bash
$ helm install . --set createCRD=false
```

See [values.yaml](./values.yaml) for a more comprehensive list of settings that can be used to customize the configuration.
