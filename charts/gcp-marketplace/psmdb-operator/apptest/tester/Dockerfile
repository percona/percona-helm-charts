FROM gcr.io/cloud-marketplace-tools/testrunner:0.1.2

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    mysqladmin \
    && rm -rf /var/lib/apt/lists/*

# RUN apt-get autoremove
# RUN curl https://www.mongodb.org/static/pgp/server-4.4.asc  | sudo apt-key add -
# RUN echo "deb http://repo.mongodb.org/apt/debian stretch/mongodb-org/4.4 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
# RUN apt-get update
# RUN apt-get install mongodb-org-shell

COPY tests/basic-suite.yaml /tests/basic-suite.yaml
COPY tester.sh /tester.sh

WORKDIR /
ENTRYPOINT ["/tester.sh"]
