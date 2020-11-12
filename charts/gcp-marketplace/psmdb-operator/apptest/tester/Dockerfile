FROM gcr.io/cloud-marketplace-tools/testrunner:0.1.2

RUN apt-get update && apt-get install -y gnupg wget jq
RUN wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | apt-key add -
RUN echo "deb http://repo.mongodb.org/apt/debian stretch/mongodb-org/4.4 main" | tee /etc/apt/sources.list.d/mongodb-org-4.4.list
RUN apt-get update && apt-get install -y --no-install-recommends \
    mongodb-org-shell \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q -O /bin/kubectl \
        https://storage.googleapis.com/kubernetes-release/release/v1.16.10/bin/linux/amd64/kubectl \
    && chmod 755 /bin/kubectl

COPY tests/* /tests/
COPY tester.sh /tester.sh

WORKDIR /
ENTRYPOINT ["/tester.sh"]