# {{GENERATED_HEADER}}
#
# Which users hold which roles. This replaces the image's default mapping entirely,
# so only these three mappings exist.
_meta:
  type: "rolesmapping"
  config_version: 2

all_access:
  reserved: false
  backend_roles:
    - "admin"
  description: "The stack's admin user"

kibana_server:
  reserved: true
  users:
    - "kibanaserver"

magento:
  reserved: false
  users:
    - "{{OPENSEARCH_MAGENTO_USER}}"
