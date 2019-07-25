# pxc-cluster: A chart for installing Percona XtraDB Operator managed Databases

This Helm Chart will deploy Percona XtraDB Operator managed Databases on Kubernetes.

You must already have the Percona XtraDB Operator installed before you use this.

To deploy clone down this repository and run:

```bash
$ helm install .
```

See [values.yaml](./values.yaml) for a comprehensive list of settings that can be used to customize the configuration.

## Examples

### Deploy a Cluster without a MySQL Proxy, no backups, no persistent disks

This is great for a dev cluster as it doesn't require a persistent disk and doesn't bother with a proxy, backups, or TLS.

```bash
$ helm install -n dev  --namespace pxc . \
    --set proxysql.enabled=false --set pxc.disableTLS=true \
    --set pxc.persistence.enabled=false --set backup-enabled=false
```

### Deploy a cluster with certificates provided by Cert Manager

First you need a working cert-manager installed with appropriate Issuers set up. Check out the [JetStack Helm Chart](https://hub.helm.sh/charts/jetstack/cert-manager) to do that.

By setting `pxc.certManager=true` we're signaling the Helm chart to not create secrets,which will in turn let the operator know to request appropriate `certificate` resources to be filled by cert-manager.

```bash
$ helm install -n dev  --namespace pxc . --set pxc.certManager=true
```

### Deploy a production grade cluster

The pxc-database chart contains an example production values file that should set you
well on your path to running a production database. It is not fully production grade as
there are some requirements for you to provide your own secrets for passwords and TLS to be truly production ready, but it does provide comments on how to do those parts.

```bash
$ helm install -n prod --file production-values.yaml --namespace pxc .
```
