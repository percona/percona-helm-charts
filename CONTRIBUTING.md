# Contributing to Percona Helm Charts

## Prerequisites

Before submitting code contributions, you should first complete the following prerequisites.

### 1. Sign the CLA

Before you can contribute, we kindly ask you to sign our [Contributor License Agreement](https://cla-assistant.percona.com/percona/percona-helm-charts) (CLA). You can do this using your GitHub account and one click.

### 2. Code of Conduct

Please make sure to read and observe the [Contribution Policy](code-of-conduct.md).

## Submitting a pull request

### 1. Making a bug report

Improvement and bugfix tasks for Percona's projects are tracked in Jira:

* [Percona Operator for MySQL (based on Percona XtraDB Cluster)](https://jira.percona.com/projects/K8SPXC)
* [Percona Operator for MySQL (based on Percona Server for MySQL)](https://jira.percona.com/projects/K8SPS)
* [Percona Operator for MongoDB](https://jira.percona.com/projects/K8SPSMDB)
* [Percona Operator for PostgreSQL](https://jira.percona.com/projects/K8SPG)
* [Percona Monitoring and Management](https://jira.percona.com/projects/PMM)

Although not mandatory, it is a good practice to examine already open Jira issues first. For bigger contributions, we suggest creating a Jira issue and discussing it with the engineering team and community before proposing any code changes.

Another good place to discuss Percona's projects with developers and other community members is the [community forum](https://forums.percona.com).

### 2. Contributing to the source tree

Contributions to the source tree should follow the workflow described below:

1. First, you need to [fork the repository on GitHub](https://docs.github.com/en/github/getting-started-with-github/fork-a-repo), clone your fork locally, and then [sync your local fork to upstream](https://docs.github.com/en/github/collaborating-with-issues-and-pull-requests/syncing-a-fork). After that, before starting to work on changes, make sure to always sync your fork with upstream.
2. Create a branch for changes you are planning to make. If there is a Jira ticket related to your contribution, it is recommended to name your branch in the following way: `<Jira issue number>-<short description>`, where the issue number is something like `K8SPXC-622`.

   Create the branch in your local repo as follows:

   ```
   git checkout -b K8SPXC-622-fix-feature-X
   ```

   When your changes are ready, make a commit, mentioning the Jira issue in the commit message, if any:

   ```
   git add .
   git commit -m "K8SPXC-622 fixed by ......"
   git push -u origin K8SPXC-622-fix-feature X
   ```

   For each change in a helm chart, please do not forget to bump the version of the chart. For example, in pxc-db chart you will need to change Chart.yaml as follows:

   ```
   apiVersion: v2
   appVersion: 1.11.0
   description: A Helm chart for installing Percona XtraDB Cluster Databases using the PXC Operator.
   name: pxc-db
   home: https://www.percona.com/doc/kubernetes-operator-for-pxc/kubernetes.html
   - version: 1.11.6
   + version: 1.11.7 <<< --- this is the change
   ```
   
   Bump patch version only, minor and major versions are changed only when the new version of the operator is released.


3. Create a pull request to the main repository on GitHub.
4. When the reviewer makes some comments, address any feedback that comes and update the pull request.
5. When your contribution is accepted, your pull request will be approved and merged to the main branch.

## Code review

Your contribution will be reviewed by other developers contributing to the project. The more complex your changes are, the more experts will be involved. You will receive feedback and recommendations directly on your pull request on GitHub, so keep an eye on your submission and be prepared to make further amendments. The developers might even provide some concrete suggestions on modifying your code to match the project’s expectations better.
