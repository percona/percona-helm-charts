# Helm Charts Template Testing

## Setup
To set up the environment for testing Helm charts, follow these steps:
Activate the Poetry shell:
```
poetry shell
```

Install dependencies:
```
poetry install
```

## Seting env vars
To validate against the current Kubernetes (k8s) cluster API, set the following environment variable:
```
export VALIDATE=true
```

## Running all the tests
To run all tests, navigate to the tests/ directory and execute:
```
pytest . 
```

## Running a Single Test File
To run tests from a specific file, use the following command:
```
pytest test_ps_operator.py
```

## Running a Single Test Class
To run tests from a specific class within a file, use the following command:
```
pytest test_ps_operator.py::TestHelmDefaultValuesAgainstBundle
```

## To increase verbosity
To increase the verbosity of the test output, use the following commands:
``` 
pytest . -v
```
or
``` 
pytest . -vv
```