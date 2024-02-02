# Use the chart `prom-rds-exporter` in the EKS

## 1. Create IAM role

Go to the IAM console and create a role name `prom-rds-exporter`, with:

- Attach 2 policies to this role:
    - `AmazonRDSReadOnlyAccess`
    - `CloudWatchReadOnlyAccess`

- Edit `Trust relationships` with below content. Replace:
    - `region`: with your cluster's region
    - `XXXXXXXXXXXX`: with your AWS account ID
    - `XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX`: with your EKS cluster's OIDC provider ID. Refer to this doc: [https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)

```json
{
	"Version": "2012-10-17",
	"Statement": [
		{
			"Effect": "Allow",
			"Principal": {
				"Federated": "arn:aws:iam::XXXXXXXXXXXX:oidc-provider/oidc.eks.region.amazonaws.com/id/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
			},
			"Action": "sts:AssumeRoleWithWebIdentity",
			"Condition": {
				"StringEquals": {
					"oidc.eks.region.amazonaws.com/id/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:aud": "sts.amazonaws.com",
					"oidc.eks.region.amazonaws.com/id/XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:sub": "system:serviceaccount:prom-rds-exporter:prom-rds-exporter"
				}
			}
		}
	]
}
```

## 2. Enable Enhanced for the RDS instances

Follow this doc: [https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.Enabling.html](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.OS.Enabling.html)

## 3. Install Helm chart

- Update the role in the file [values.yaml](./values.yaml) at the line `58` and `85`.

```yaml
...
aws:
  role: arn:aws:iam::xxxxxxxxxxxx:role/prom-rds-exporter
...
```

```yaml
...
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::xxxxxxxxxxxx:role/prom-rds-exporter
...
```

- Update the configurations for your RDS instances.

```yaml
...
config: |-
  # This is the default configuration for prom-rds-exporter
  instances:
    - region: us-east-2
      instance: rds-name
      disable_basic_metrics: true
      disable_enhanced_metrics: false
...
```

- Connect to your EKS cluster and run this command to install the Helm chart.

```sh
# Install the chart
helm install prom-rds-exporter prom-rds-exporter/ --namespace prom-rds-exporter --values prom-rds-exporter/values.yaml

# Update the Helm chart when you update the file values.yaml
helm upgrade prom-rds-exporter prom-rds-exporter/ --namespace prom-rds-exporter --values prom-rds-exporter/values.yaml

# Uninstall the Helm chart from your cluster
helm uninstall prom-rds-exporter -n prom-rds-exporter
```

## 4. Check the result

- Check the pod is running.

```sh
kubectl get pods -n prom-rds-exporter
```

You should see something like this.

```console
time="2023-04-03T08:05:41Z" level=info msg="Starting RDS exporter (version=, branch=, revision=)" source="main.go:30"
time="2023-04-03T08:05:41Z" level=info msg="Build context (go=go1.19, user=, date=)" source="main.go:31"
time="2023-04-03T08:05:41Z" level=info msg="Creating sessions..." component=sessions source="sessions.go:48"
Region     Instance            Resource ID                    Interval
us-east-2  rds-name            db-XXXXXXXXXXXXXXXXXXXXXXXXXX  1m0s
time="2023-04-03T08:05:41Z" level=info msg="Using 1 sessions." component=sessions source="sessions.go:166"
time="2023-04-03T08:05:41Z" level=info msg="Updating enhanced metrics every 1m0s." component=enhanced source="collector.go:49"
time="2023-04-03T08:05:41Z" level=info msg="Basic metrics   : http://:9042/basic" source="main.go:65"
time="2023-04-03T08:05:41Z" level=info msg="Enhanced metrics: http://:9042/enhanced" source="main.go:66"
```

- Forwarding the service to your local machine with this command.

```sh
kubectl port-forward service/prom-rds-exporter 9042:9042 -n prom-rds-exporter
```

Then you can go to your browser and type this links to see the metrics:

- [http://localhost:9042/basic](http://localhost:9042/basic): see the basic metrics

- [http://localhost:9042/enhanced](http://localhost:9042/enhanced): see the enhanced metrics
