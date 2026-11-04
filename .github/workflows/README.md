# GitHub Actions workflows

This directory contains the workflows used to validate and release the Helm
charts in this repository.

## Workflow overview

| Workflow | Purpose | Trigger |
| --- | --- | --- |
| [`labeler.yaml`](./labeler.yaml) | Applies labels to pull requests based on the changed files. | Pull request opened or synchronized |
| [`release.yaml`](./release.yaml) | Packages and publishes changed Helm charts. | Push to `main` |
| [`test-chart-lint.yaml`](./test-chart-lint.yaml) | Lints changed PG, PS, PSMDB, PXC operator/database charts and the PMM chart. | Pull request changing a supported chart (excluding operator CRD-only changes) or the lint workflow itself |
| [`test-chart-install.yaml`](./test-chart-install.yaml) | Installs the PMM chart on Kind, then packages and uploads it. | Pull request changing the PMM chart |
| [`test-operator-crd.yaml`](./test-operator-crd.yaml) | Checks separate operator CRD charts for versioning, synchronization, installation, and removal. | Pull request changing operator metadata, embedded CRDs, or a `*-operator-crds` chart |
| [`test-chart-unit.yaml`](./test-chart-unit.yaml) | Runs Helm unit tests for changed PXC and PS operator/database charts, or all four suites when shared test files change. | Pull request changing a supported chart, `Makefile`, the unit-test workflow, or `detect-changes` |
| [`test-operator-deploy.yaml`](./test-operator-deploy.yaml) | Installs PSMDB, PXC, PS, and PG on Minikube; runs an independent PSMDB upgrade scenario. | Pull request targeting `main` and changing supported charts or lifecycle-test files, or an authorized same-repository PR comment |
| [`pmm-ha-pr-checks.yaml`](./pmm-ha-pr-checks.yaml) | Runs PMM-HA shell tests, linting, rendering checks, Helm unit tests, and installation tests. | Pull request changing PMM-HA files or the Makefile |

## Operator install and upgrade tests

The [`test-operator-deploy.yaml`](./test-operator-deploy.yaml) workflow
uses an installation matrix for `psmdb`, `pxc`, `ps`, and `pg`, and a separate
upgrade matrix limited to `psmdb`. PXC, PS, and PG install a separate
`<product>-operator-crds` chart first when it exists, then install the operator
with `--skip-crds`. Otherwise, the operator installs its embedded CRDs.
Operators watch all namespaces so they can reconcile database resources in
the `database` namespace used for installation.
All installation matrix entries invoke `scripts/test-operator-deploy.sh install`.
The helper installs the charts using Helm, waits for database readiness, and
runs `helm test`. The job cleanup deletes the test cluster. No Python or
chart-testing setup is needed in this workflow.

All products use the same readiness checks with a 7-minute timeout: the database
CR must be ready and its StatefulSets and Deployments must be reconciled, updated,
and ready. CR observed generation is also checked where supported (PS does not
expose this field). PG uses its native cluster label to select workloads.
While waiting, the helper prints CR status and pod status every 15 seconds and
fails early when a database container is in CrashLoopBackOff with at least three
restarts. On timeout, it also describes the database CR.

Minimal database values are stored in [`files/`](./files/) and loaded explicitly:

- [`minimal-ps-values.yaml`](./files/minimal-ps-values.yaml)
- [`minimal-pxc-values.yaml`](./files/minimal-pxc-values.yaml)
- [`minimal-pg-values.yaml`](./files/minimal-pg-values.yaml)
- [`minimal-psmdb-values.yaml`](./files/minimal-psmdb-values.yaml)

PS's configuration follows the operator's minimal CR: one MySQL instance, one HAProxy
instance, a 2 GiB data volume, and the required unsafe size flags. MySQL
auto-configuration, Router, Orchestrator, and backups are disabled; the log
collector stays enabled. Smaller resource requests and disabled host
anti-affinity keep this configuration suitable for the single-node CI cluster.
The detailed lifecycle checks below apply to PSMDB:

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
before upgrading the database chart with its new values. The database upgrade
uses `--reset-values` to apply the target chart defaults and test values.
Only when the target operator image comes from `perconalab`, the PSMDB upgrade
pins the observed baseline `mongo-init` image before upgrading the operator.
This prevents a development repository change from replacing database pods
during the operator-only stability check. The database upgrade removes this
temporary override with `--reset-values`. Released `percona` operator images
do not use this pin.
The test saves the previous images for a per-operator list of components and
passes that snapshot to the pin function. A separate operator case selects the
Helm fields to override. Initially only PSMDB's `mongo-init` is configured;
PMM and other components are not overridden, and upgrade coverage remains
limited to PSMDB.

The test configuration enables sharding with one replica set member, one config
server, and one mongos instance. The required replica set and mongos unsafe
flags are enabled for this single-node test configuration.

The tests use `percona/<operator>:<appVersion>` when that operator image exists.
For an unreleased operator version, they use `perconalab/<operator>:main`
instead.

Each job runs on Ubuntu 22.04 and creates its own Minikube cluster using
the Docker driver and containerd as the Kubernetes container runtime,
the newest stable Kubernetes version declared by that Minikube release's
`NewestKubernetesVersion` constant,
four CPUs, and 12 GB of memory. The resolved version is printed in each job's logs.
The latest stable Minikube release is resolved through the GitHub releases API
on each run. Its version is logged. CI authenticates the request with
`GH_TOKEN`; local runs can omit the token.
Both jobs explicitly install `kubectl` with the resolved Kubernetes version,
so they do not depend on tools preinstalled in GitHub runners or local `act`
container images.
Ubuntu 22.04 avoids the
Linux 6.19 through 7.0.13 kernels that are incompatible with PSMDB 8. The
install job has a 30-minute timeout; the upgrade job has a 40-minute timeout.
Cleanup runs regardless of job success or failure.

### Automatic pull request trigger

Pull requests targeting `main` automatically run both scenarios when any of
these paths change:

- `charts/psmdb-operator/**`, excluding `charts/psmdb-operator/crds/**`
- `charts/psmdb-operator-crds/**`
- `charts/psmdb-db/**`

Changes to either version helper or `disable-app-armor-profiles.sh` also
trigger the workflow and select all supported installation products and the
PSMDB upgrade scenario.

The install and upgrade jobs are independent. The upgrade scenario installs
the previous chart versions before upgrading them, so it does not depend on
the install job. For pull request events, the baseline SHA is the pull request
base SHA.
Each job computes `steps.tests.outputs.run` once from the detected jobs and
products, then reuses it to gate its setup and test steps.

Automatic runs retain the GitHub pull request merge checkout, so the tested
charts include changes already present in the base branch even when the pull
request head is behind it.

### Failure diagnostics

The version helpers are
[`latest-stable-minikube-version.sh`](./scripts/latest-stable-minikube-version.sh)
(latest stable release) and
[`latest-stable-kubernetes-version.sh`](./scripts/latest-stable-kubernetes-version.sh)
(newest supported Kubernetes for the supplied Minikube release). Both print
only the version to stdout; failures stop the job.

PS/PXC installation jobs run
[`disable-app-armor-profiles.sh`](./scripts/disable-app-armor-profiles.sh) before
creating Minikube. Ubuntu enables AppArmor by default, and installing its
MySQL package loads a profile attached to `/usr/sbin/mysqld`, as on GitHub's
Ubuntu runner images. That profile permits Ubuntu's MySQL file layout, not
all Percona paths. In our Azure reproduction, loading it caused audit denials
for `/etc/my.cnf` and `/usr/share/percona-server/english/errmsg.sys`, matching
the configuration discrepancies and missing administrative listener seen in CI.

The host profile attached to MySQL even when the node and database container
requested AppArmor `Unconfined`. A shell and `my_print_defaults` could still
read the configuration because they were not the confined MySQL executable.
Therefore container values alone did not remove this restriction. This
demonstrates the mechanism on Azure; the original CI process profile and audit
denials have not been captured.

The helper unloads only the MySQL profile, not AppArmor globally, and skips
host changes under `act`. It reduces isolation only on the disposable test
runner, leaves other profiles and seccomp unchanged, and does not change
production chart defaults. Do not use this workaround on production hosts.

On failure, both jobs collect Kubernetes resources, events, pod descriptions,
current and previous logs for regular and init containers, database logs stored
on disk, and Minikube problem logs. The resulting `cluster-logs` directory is
uploaded as an artifact before the cluster is deleted.
The collector defines per-product file patterns for PS/PXC MySQL logs and
configuration, PXC Galera state, PSMDB disk logs, and PG logs and configuration.
Files are read from their database containers into `<container>-files.txt`.
Configuration output includes only selected diagnostic directives, not full
configuration files or credentials. Patterns cover known paths; files at other
locations are not discovered automatically. Container logs are limited to 500
lines and disk logs to 2,000 lines per file. File collection errors are reported
without stopping the remaining diagnostics.

### Pull request comment commands

Add one of these commands to the pull request conversation:

| Command | Tests triggered |
| --- | --- |
| `/run-deploy-test` | All jobs for all supported operators |
| `/run-deploy-test psmdb` | All jobs for PSMDB |
| `/run-deploy-test install` | The install job for all supported operators |
| `/run-deploy-test upgrade` | The upgrade job for all supported operators |
| `/run-deploy-test psmdb install` | Only the PSMDB install job |
| `/run-deploy-test psmdb upgrade` | Only the PSMDB upgrade job |

The helper accepts commands from repository owners and members
(`OWNER` or `MEMBER`) only on same-repository pull requests. Fork pull requests
are rejected before any PR revision is fetched or checked out. Keep the command
on a single line with no additional content.

Currently supported values:

- Installation operators: `psmdb`, `pxc`, `ps`, `pg`
- Upgrade operators: `psmdb`
- Jobs: `install`, `upgrade`

Unsupported operators and jobs are ignored.

The workflow fetches the open pull request's merge revision and validates its
SHA and both parents against the API's merge, base, and head SHAs before checking
it out. Missing or mismatched merge revisions fail explicitly; conflicting pull
requests must be updated before testing. The pull request base SHA remains the
upgrade baseline. GitHub only delivers `issue_comment`
events to a workflow that already exists on the default branch.

## Workflow helper scripts

The shared workflow scripts are stored in
[`scripts/`](./scripts/):

- [`detect-changes.sh`](./scripts/detect-changes.sh) detects changed charts and can
  either filter supported charts or select the corresponding operators.
- [`detect-comment.sh`](./scripts/detect-comment.sh) validates pull request comment
  commands, fetches and validates the PR merge, and selects the requested operators
  and jobs.
- [`test-operator-deploy.sh`](./scripts/test-operator-deploy.sh) performs the
  Helm install and upgrade scenarios.
