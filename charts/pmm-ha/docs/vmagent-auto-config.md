# VMAgent Automatic Configuration with Init Container

## Overview
This solution uses a Kubernetes Job with a post-install/post-upgrade Helm hook to automatically configure the VMAgent deployment with the correct VMAuth remoteWrite URL. The job reuses the existing `pmm-service-account` which has been granted deployment patch permissions.

## Components

### 1. ClusterRole Permissions (`templates/clusterrole.yaml`)
Added deployment permissions to the existing PMM ClusterRole:
```yaml
- apiGroups: ["apps"]
  resources:
  - deployments
  verbs:
  - get
  - list
  - patch
```

### 2. Configuration Script (`templates/vmagent-init-script.yaml`)
A ConfigMap containing the shell script that:
- Waits for the VMAgent deployment to be created (up to 2 minutes)
- Checks if the correct URL is already configured
- Patches the deployment to replace the placeholder URL with the actual VMAuth URL
- Waits for the rollout to complete

### 3. Configuration Job (`templates/vmagent-config-job.yaml`)
A Kubernetes Job that runs after install/upgrade:
```yaml
annotations:
  "helm.sh/hook": post-install,post-upgrade
  "helm.sh/hook-weight": "5"
  "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

The job:
- Uses the existing `pmm-service-account` (no new ServiceAccount needed)
- Runs the configuration script from the ConfigMap
- Automatically cleans up after successful completion
- Retries up to 10 times if it fails

### 4. Values Configuration (`values.yaml`)
VMAgent is configured with a placeholder URL that gets replaced:
```yaml
victoria-metrics-agent:
  replicaCount: 2
  remoteWrite:
    - url: "http://placeholder.local/api/v1/write"
```

## How It Works

1. **Helm Install/Upgrade**: The chart deploys all resources including VMAgent with placeholder URL
2. **Post-Hook Execution**: After main deployment, the configuration job starts
3. **Wait for VMAgent**: The job waits for the VMAgent deployment to exist
4. **Patch Deployment**: Replaces placeholder URL with actual VMAuth URL:
   - From: `http://placeholder.local/api/v1/write`
   - To: `http://{release}-victoria-metrics-cluster-vmauth.{namespace}.svc.cluster.local:8427/api/v1/write`
5. **Rollout**: Waits for VMAgent pods to restart with the correct URL
6. **Cleanup**: Job pod is deleted after successful completion

## Benefits

- ✅ Fully automatic - no manual intervention required
- ✅ Reuses existing ServiceAccount and RBAC
- ✅ Idempotent - safe to run multiple times
- ✅ Self-healing - automatically fixes configuration on every upgrade
- ✅ Clean - job pod auto-deletes after success
- ✅ Resilient - 10 retry attempts with backoff

## Testing

Test the template rendering:
```bash
helm template test . --set secret.create=true --show-only templates/vmagent-config-job.yaml
```

Deploy and watch the configuration:
```bash
helm upgrade --install pmm-ha . -n pmmha --set secret.create=true
kubectl logs -n pmmha job/pmm-ha-configure-vmagent -f
```

Verify the configuration:
```bash
kubectl get deployment pmm-ha-victoria-metrics-agent -n pmmha -o jsonpath='{.spec.template.spec.containers[0].args[0]}'
```

Expected output:
```
-remoteWrite.url=http://pmm-ha-victoria-metrics-cluster-vmauth.pmmha.svc.cluster.local:8427/api/v1/write
```
