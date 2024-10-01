import os
import yaml
import pytest
import requests
import logging
import subprocess

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger(__name__)

VALIDATE = os.getenv("VALIDATE", False)


@pytest.fixture(scope="class")
def helm_template():
    def _helm_template(chart_path, release_name, namespace, values):
        command = [
            "helm",
            "template",
            release_name,
            chart_path,
            "--namespace",
            namespace,
            "--values",
            values,
        ]
        if VALIDATE:
            command.append("--validate")
        try:
            output = subprocess.check_output(command)
            return list(yaml.full_load_all(output))
        except subprocess.CalledProcessError as e:
            pytest.fail(f"Command {e.cmd} returned non-zero exit status {e.returncode}")
        except Exception as e:
            pytest.fail(f"Unexpected error ocurred: {e}")

    return _helm_template


@pytest.fixture(scope="class")
def get_resources():
    def _get_resources(operator_project_name, version, resource):
        full_url = f"https://raw.githubusercontent.com/percona/{operator_project_name}/v{version}/deploy/{resource}.yaml"
        try:
            response = requests.get(full_url)
            response.raise_for_status()
            return list(yaml.safe_load_all(response.text))
        except requests.exceptions.RequestException as e:
            pytest.fail(f"Request for {resource} failed.\n {e}")
        except Exception as e:
            pytest.fail(f"Unexpected error ocurred: {e}")

    return _get_resources
