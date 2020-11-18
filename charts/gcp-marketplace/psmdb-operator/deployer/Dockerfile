ARG MARKETPLACE_TOOLS_TAG
FROM marketplace.gcr.io/google/debian9 AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends gettext

ADD chart/psmdb-operator /tmp/chart
RUN cd /tmp && tar -czvf /tmp/psmdb-operator.tar.gz chart

ADD apptest/deployer/psmdb-operator /tmp/test/chart
RUN cd /tmp/test && tar -czvf /tmp/test/psmdb-operator.tar.gz chart/

ADD schema.yaml /tmp/schema.yaml

ARG REGISTRY
ARG TAG
ARG PSMDB_36
ARG PSMDB_40
ARG PSMDB_42

RUN cat /tmp/schema.yaml \
    | env -i "REGISTRY=$REGISTRY" "TAG=$TAG" "PSMDB_36=$PSMDB_36" "PSMDB_40=$PSMDB_40" "PSMDB_42=$PSMDB_42" envsubst \
    > /tmp/schema.yaml.new \
    && mv /tmp/schema.yaml.new /tmp/schema.yaml
RUN cat /tmp/schema.yaml

ADD apptest/deployer/schema.yaml /tmp/apptest/schema.yaml
RUN cat /tmp/apptest/schema.yaml \
    | env -i "REGISTRY=$REGISTRY" "TAG=$TAG" envsubst \
    > /tmp/apptest/schema.yaml.new \
    && mv /tmp/apptest/schema.yaml.new /tmp/apptest/schema.yaml

FROM gcr.io/cloud-marketplace-tools/k8s/deployer_helm:$MARKETPLACE_TOOLS_TAG
COPY --from=build /tmp/psmdb-operator.tar.gz /data/chart/
COPY --from=build /tmp/test/psmdb-operator.tar.gz /data-test/chart/
COPY --from=build /tmp/schema.yaml /data/
COPY --from=build /tmp/apptest/schema.yaml /data-test/

ENV WAIT_FOR_READY_TIMEOUT 1800
ENV TESTER_TIMEOUT 1800
