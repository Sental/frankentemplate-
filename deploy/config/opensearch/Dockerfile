# OpenSearch with ElasticSuite's required plugin built in.
#
# Installing plugins into each new container at boot would make every recreate need
# network access and minutes of startup. Building them in once means a container starts
# the same way every time. Compose builds this image from the
# rendered compose file; OPENSEARCH_TAG pins the base image when needed.
ARG OPENSEARCH_TAG=3
FROM opensearchproject/opensearch:${OPENSEARCH_TAG}

# The `list` check keeps the build working if a future base image ships the plugin.
RUN /usr/share/opensearch/bin/opensearch-plugin list | grep -qx analysis-phonetic \
    || /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-phonetic
