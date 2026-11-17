# GitHub Actions workflows

These workflows validate and publish the Helm charts in this repository.

## Workflows

| Workflow | Purpose |
| --- | --- |
| [`labeler.yaml`](./labeler.yaml) | Labels pull requests based on changed files. |
| [`release.yaml`](./release.yaml) | Packages and publishes changed charts. |
| [`test-chart-lint.yaml`](./test-chart-lint.yaml) | Lints changed charts. |
| [`test-chart-install.yaml`](./test-chart-install.yaml) | Installs and packages the PMM chart. |
| [`test-operator-crd.yaml`](./test-operator-crd.yaml) | Validates operator CRD charts. |
| [`test-chart-unit.yaml`](./test-chart-unit.yaml) | Runs Helm unit tests. |
| [`test-operator-deploy.yaml`](./test-operator-deploy.yaml) | Runs operator install and upgrade tests. |
| [`pmm-ha-pr-checks.yaml`](./pmm-ha-pr-checks.yaml) | Runs PMM-HA checks and installation tests. |

## Operator deployment tests

[`test-operator-deploy.yaml`](./test-operator-deploy.yaml) runs installation
tests for `psmdb`, `pxc`, `ps`, and `pg`, with upgrade tests for `psmdb` and
`pg`. Jobs run independently on Minikube. Upgrade tests install the baseline
chart versions, then upgrade to the charts in the pull request. Failures upload
cluster diagnostics as an artifact.

Pull requests run install tests when supported files change. Automatic upgrade
tests run for pull requests targeting `main`. Repository members can also
request tests with a single-line pull request comment:

| Command | Scope |
| --- | --- |
| `/run-deploy-test` | All supported tests |
| `/run-deploy-test install` | Install tests |
| `/run-deploy-test upgrade` | Upgrade tests |
| `/run-deploy-test pg upgrade` | PG upgrade test |

Comment commands are accepted from repository owners and members on
same-repository pull requests. Fork pull requests are not supported.

## Helper scripts

- [`detect-changes.sh`](./scripts/detect-changes.sh) selects tests from changed files.
- [`detect-comment.sh`](./scripts/detect-comment.sh) validates comment commands and selects tests.
- [`test-operator-deploy.sh`](./scripts/test-operator-deploy.sh) runs Helm install and upgrade scenarios.
