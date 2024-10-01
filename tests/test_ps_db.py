import pytest
import yaml
import logging
from collections import defaultdict
from deepdiff import DeepDiff

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

CHART_PATH = "../charts/ps-db/"
VALUES_PATH = f"{CHART_PATH}values.yaml"
RELEASE_NAME = "release-default"
NAMESPACE = "default-ns"
OPERATOR_PROJECT_NAME = "percona-server-mysql-operator"


def values_file():
    with open(VALUES_PATH, "r") as file:
        return yaml.safe_load(file)


IMAGE_TAG = values_file()["crVersion"]
DEFAULT_LABELS = {
    "app.kubernetes.io/name": "ps-db",
    "helm.sh/chart": f"ps-db-{IMAGE_TAG}",
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
def cr_resources(get_resources):
    resources = get_resources(OPERATOR_PROJECT_NAME, IMAGE_TAG, "cr")
    return resources


class TestDefaultValuesAgainstCr:
    @pytest.fixture(autouse=True)
    def setup(self, cr_resources, helm_resources):
        self.bundle_dict = defaultdict(list)
        self.helm_dict = defaultdict(list)

        for item in cr_resources:
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

    @pytest.mark.xfail(reason="many differences in helm template")
    def test_percona_server_mysql(self):
        expected_diff = {
            "dictionary_item_added": {
                "root[0]['metadata']['annotations']": {
                    "kubectl.kubernetes.io/last-applied-configuration": '{"apiVersion":"ps.percona.com/v1alpha1","kind":"PerconaServerMySQL"}\n',
                },
                "root[0]['metadata']['labels']": DEFAULT_LABELS,
                "root[0]['metadata']['namespace']": NAMESPACE,
            },
            "values_changed": {
                "root[0]['metadata']['name']": {
                    "new_value": f"{RELEASE_NAME}-ps-db",
                    "old_value": "cluster1",
                },
                "root[0]['spec']['secretsName']": {
                    "new_value": f"{RELEASE_NAME}-ps-db-secrets",
                    "old_value": "cluster1-secrets",
                },
                "root[0]['spec']['sslSecretName']": {
                    "new_value": f"{RELEASE_NAME}-ps-db-ssl",
                    "old_value": "cluster1-ssl",
                },
            },
        }
        self._compare_resources("PerconaServerMySQL", expected_diff)
