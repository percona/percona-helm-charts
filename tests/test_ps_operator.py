import pytest
import yaml
import logging
from collections import defaultdict
from deepdiff import DeepDiff

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

CHART_PATH = "../charts/ps-operator/"
VALUES_PATH = f"{CHART_PATH}values.yaml"
RELEASE_NAME = "release-default"
NAMESPACE = "default-ns"
OPERATOR_PROJECT_NAME = "percona-server-mysql-operator"


def values_file():
    with open(VALUES_PATH, "r") as file:
        return yaml.safe_load(file)


IMAGE_TAG = values_file()["image"]["tag"]
DEFAULT_LABELS = {
    "app.kubernetes.io/name": "ps-operator",
    "helm.sh/chart": f"ps-operator-{IMAGE_TAG}",
    "app.kubernetes.io/instance": RELEASE_NAME,
    "app.kubernetes.io/version": IMAGE_TAG,
    "app.kubernetes.io/managed-by": "Helm",
}


@pytest.fixture(scope="class")
def helm_resources(helm_template):
    resources = helm_template(
        chart_path=CHART_PATH,
        release_name=RELEASE_NAME,
        namespace=NAMESPACE,
        values=VALUES_PATH,
    )
    return resources


@pytest.fixture(scope="class")
def bundle_resources(get_resources):
    resources = get_resources(OPERATOR_PROJECT_NAME, IMAGE_TAG, "bundle")[
        :-1
    ]  # FIXME: The last item is none
    return resources


class TestDefaultValuesAgainstBundle:
    @pytest.fixture(autouse=True)
    def setup(self, bundle_resources, helm_resources):
        self.bundle_dict = defaultdict(list)
        self.helm_dict = defaultdict(list)

        for item in bundle_resources:
            self.bundle_dict[item["kind"]].append(item)
        for item in helm_resources:
            self.helm_dict[item["kind"]].append(item)

    def _compare_resources(self, resource_type, expected_diff):
        diff = DeepDiff(
            self.bundle_dict[resource_type],
            self.helm_dict[resource_type],
            verbose_level=2,
        )
        assert diff == expected_diff

    def test_resource_quantity_should_be_equal(self, bundle_resources, helm_resources):
        assert (
            len(helm_resources) == len(bundle_resources) - 3
        )  # FIXME: Bundle has 3 CRDs which Helm does not have

    def test_deployment(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['namespace']": NAMESPACE,
                "root[0]['metadata']['labels']": DEFAULT_LABELS,
                "root[0]['spec']['selector']['matchLabels']['app.kubernetes.io/instance']": RELEASE_NAME,
                "root[0]['spec']['template']['metadata']['labels']['app.kubernetes.io/instance']": RELEASE_NAME,
            },
            "dictionary_item_removed": {
                "root[0]['spec']['template']['spec']['containers'][0]['resources']['limits']": {
                    "cpu": "200m",
                    "memory": "100Mi",
                },
                "root[0]['spec']['template']['spec']['containers'][0]['resources']['requests']": {
                    "cpu": "100m",
                    "memory": "20Mi",
                },
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['selector']['matchLabels']['app.kubernetes.io/name']": {
                    "new_value": "ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['template']['metadata']['labels']['app.kubernetes.io/name']": {
                    "new_value": "ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['template']['spec']['serviceAccountName']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
            },
        }
        self._compare_resources("Deployment", expected_diff)

    @pytest.mark.xfail(reason="resources not defined in helm template")
    def test_real_deployment(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['namespace']": NAMESPACE,
                "root[0]['metadata']['labels']": DEFAULT_LABELS,
                "root[0]['spec']['selector']['matchLabels']['app.kubernetes.io/instance']": RELEASE_NAME,
                "root[0]['spec']['template']['metadata']['labels']['app.kubernetes.io/instance']": RELEASE_NAME,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['selector']['matchLabels']['app.kubernetes.io/name']": {
                    "new_value": "ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['template']['metadata']['labels']['app.kubernetes.io/name']": {
                    "new_value": "ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['spec']['template']['spec']['serviceAccountName']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
            },
        }
        self._compare_resources("Deployment", expected_diff)

    def test_configmap(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['namespace']": NAMESPACE,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator-config",
                    "old_value": "percona-server-mysql-operator-config",
                },
            },
        }
        self._compare_resources("ConfigMap", expected_diff)

    def test_service_account(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['namespace']": NAMESPACE,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
            },
        }
        self._compare_resources("ServiceAccount", expected_diff)

    def test_role(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['labels']": DEFAULT_LABELS,
                "root[0]['metadata']['namespace']": NAMESPACE,
                "root[1]['metadata']['labels']": DEFAULT_LABELS,
                "root[1]['metadata']['namespace']": NAMESPACE,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator-leaderelection",
                    "old_value": "percona-server-mysql-operator-leaderelection",
                },
                "root[1]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
            },
        }
        self._compare_resources("Role", expected_diff)

    def test_rolebinding(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['labels']": DEFAULT_LABELS,
                "root[0]['metadata']['namespace']": NAMESPACE,
                "root[1]['metadata']['labels']": DEFAULT_LABELS,
                "root[1]['metadata']['namespace']": NAMESPACE,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator-leaderelection",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['roleRef']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator-leaderelection",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[0]['subjects'][0]['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
                "root[1]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator-leaderelection",
                },
                "root[1]['roleRef']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator-leaderelection",
                },
                "root[1]['subjects'][0]['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-operator",
                    "old_value": "percona-server-mysql-operator",
                },
            },
        }
        self._compare_resources("RoleBinding", expected_diff)
