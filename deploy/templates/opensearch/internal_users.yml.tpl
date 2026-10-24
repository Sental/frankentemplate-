# {{GENERATED_HEADER}}
#
# OpenSearch's internal users. bin/render fills in the bcrypt hashes deploy/setup made
# from the passwords in .env. OpenSearch reads this file itself only when it first
# creates its security index; bin/opensearch-security applies it after that, and setup
# runs it every time. So this file wins: a password changed through the security REST
# API is reverted on the next setup run. To change one, set it in .env, delete
# .stack/opensearch/hashes.env, then re-run deploy/setup.
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "{{OPENSEARCH_ADMIN_HASH}}"
  reserved: true
  backend_roles:
    - "admin"
  description: "The stack's administrator: all_access, through roles_mapping.yml"

kibanaserver:
  hash: "{{OPENSEARCH_DASHBOARDS_HASH}}"
  reserved: true
  description: "OpenSearch Dashboards' server user (dev only)"

{{OPENSEARCH_MAGENTO_USER}}:
  hash: "{{OPENSEARCH_MAGENTO_HASH}}"
  reserved: false
  description: "Magento and ElasticSuite: the magento role, through roles_mapping.yml"
