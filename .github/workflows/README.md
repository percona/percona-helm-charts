# GitHub Actions workflows

This directory contains the workflows used to validate and release the Helm
charts in this repository.

## Workflow overview

| Workflow | Purpose | Trigger |
| --- | --- | --- |
| [`labeler.yaml`](./labeler.yaml) | Applies labels to pull requests based on the changed files. | Pull request opened or synchronized |
| [`release.yaml`](./release.yaml) | Packages and publishes changed Helm charts. | Push to `main` |
| [`test-chart-lint.yaml`](./test-chart-lint.yaml) | Lints changed PG, PS, PSMDB, PXC operator/database charts and the PMM chart. | Pull request changing a supported chart, excluding operator CRD-only changes |
| [`test-chart-install.yaml`](./test-chart-install.yaml) | Installs the PMM chart on Kind, then packages and uploads it. | Pull request changing the PMM chart |
| [`test-operator-crd.yaml`](./test-operator-crd.yaml) | Checks separate operator CRD charts for versioning, synchronization, installation, and removal. | Pull request changing operator metadata, embedded CRDs, or a `*-operator-crds` chart |
| [`test-operator-template.yaml`](./test-operator-template.yaml) | Runs Helm unit tests only for changed PXC and PS operator/database charts. | Pull request changing a supported chart |
| [`test-operator-upgrade.yaml`](./test-operator-upgrade.yaml) | Runs independent PSMDB install and upgrade scenarios on Minikube. | Pull request targeting `main` and changing supported PSMDB charts or lifecycle-test files, or an authorized PR comment |
| [`test-pmm-ha.yaml`](./test-pmm-ha.yaml) | Runs PMM-HA shell tests, linting, rendering checks, Helm unit tests, and installation tests. | Pull request changing PMM-HA files or the Makefile |

## Operator install and upgrade tests

The [`test-operator-upgrade.yaml`](./test-operator-upgrade.yaml) workflow
currently supports PSMDB and runs two independent jobs:

- `install-test`: installs the current CRD, operator, and database charts.
- `upgrade-test`: reads chart versions from `BASE_SHA`, installs those versions
  from the Percona Helm repository, and upgrades them using the checked-out
  charts. Those baseline chart versions must be published in the repository.

For both jobs, the workflow:

1. Installs the CRD chart and waits for its CRDs to become established.
2. Installs the cluster-wide operator in the `operator` namespace.
3. Installs the database chart in the `database` namespace.
4. Waits for the database custom resource to observe its latest generation and
   become ready, with all StatefulSets and Deployments fully updated and ready.

The upgrade job also verifies that the operator Deployment becomes ready, then
waits 60 seconds and checks that no database pod was replaced or restarted
before upgrading the database chart with its new values.

The test configuration enables sharding with one replica set member, one config
server, and one mongos instance. The required replica set and mongos unsafe
flags are enabled for this single-node test configuration.

The tests use `percona/<operator>:<appVersion>` when that operator image exists.
For an unreleased operator version, they use `perconalab/<operator>:main`
instead.

Each job runs on Ubuntu 22.04 and creates its own Minikube cluster using
Kubernetes `v1.34.0`, four CPUs, and 12 GB of memory. Ubuntu 22.04 avoids the
Linux 6.19 through 7.0.13 kernels that are incompatible with PSMDB 8. The
install job has a 30-minute timeout; the upgrade job has a 40-minute timeout.
Cleanup runs regardless of job success or failure.

### Automatic pull request trigger

Pull requests targeting `main` automatically run both scenarios when any of
these paths change:

- `charts/psmdb-operator/**`, excluding `charts/psmdb-operator/crds/**`
- `charts/psmdb-operator-crds/**`
- `charts/psmdb-db/**`

The install and upgrade jobs are independent. The upgrade scenario installs
the previous chart versions before upgrading them, so it does not depend on
the install job. For pull request events, the baseline SHA is the pull request
base SHA.

### Failure diagnostics

On failure, both jobs collect Kubernetes resources, events, pod descriptions,
current and previous logs for regular and init containers, database logs stored
on disk, and Minikube problem logs. The resulting `cluster-logs` directory is
uploaded as an artifact before the cluster is deleted.

### Pull request comment commands

Add one of these commands to the pull request conversation:

| Command | Tests triggered |
| --- | --- |
| `/run-test-upgrade` | All jobs for all supported operators |
| `/run-test-upgrade psmdb` | All jobs for PSMDB |
| `/run-test-upgrade install` | The install job for all supported operators |
| `/run-test-upgrade upgrade` | The upgrade job for all supported operators |
| `/run-test-upgrade psmdb install` | Only the PSMDB install job |
| `/run-test-upgrade psmdb upgrade` | Only the PSMDB upgrade job |

The helper accepts commands from repository owners and members
(`OWNER` or `MEMBER`). Keep the command on a single line with no additional
content.

Currently supported values:

- Operators: `psmdb`
- Jobs: `install`, `upgrade`

Unsupported operators and jobs are ignored.

The workflow resolves and checks out the pull request head, and uses the pull
request base SHA as the upgrade baseline. GitHub only delivers `issue_comment`
events to a workflow that already exists on the default branch.

## Workflow helper scripts

The shared workflow scripts are stored in
[`scripts/`](./scripts/):

- [`detect-changes`](./scripts/detect-changes) detects changed charts and can
  either filter supported charts or select the corresponding operators.
- [`detect-comment`](./scripts/detect-comment) validates pull request comment
  commands, fetches the selected PR head, and selects the requested operators
  and jobs.
- [`test-operator-with-helm`](./scripts/test-operator-with-helm) performs the
  Helm install and upgrade scenarios.
