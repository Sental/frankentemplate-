# {{GENERATED_HEADER}}
#
# Custom roles. Built-in static roles (all_access, kibana_server, ...) don't need defining.
_meta:
  type: "roles"
  config_version: 2

# Magento and ElasticSuite: full control of their own indices and nothing else. They
# create a new index per reindex, swap the alias, then delete the old generation, so
# they need every action on indices matching the prefix.
#
# Plus reading alias names on every index. Both look an alias up by name alone, which
# OpenSearch resolves against all indices: core's IndexNameResolver::getIndexFromAlias()
# sends HEAD /_alias/<name> during every reindex, and ElasticSuite's admin Indices page
# sends GET /_alias. Without it, the reindex fails with a 403 on indices:admin/aliases/get.
# It reads alias names only, never documents or mappings.
#
# If a reindex fails with a security_exception, the log names the missing permission:
# add it here, then run bin/opensearch-security, because OpenSearch reads this file only
# when it first creates its security index. While diagnosing, mapping the user to
# all_access in roles_mapping.yml tells you whether the role is the problem.
magento:
  reserved: false
  cluster_permissions:
    - "cluster_composite_ops"
    - "cluster_monitor"
    - "indices:admin/template/*"
    - "indices:admin/index_template/*"
  index_permissions:
    - index_patterns:
        - "{{OPENSEARCH_INDEX_PREFIX}}*"
      allowed_actions:
        - "indices_all"
    - index_patterns:
        - "*"
      allowed_actions:
        - "indices:admin/aliases/get"
