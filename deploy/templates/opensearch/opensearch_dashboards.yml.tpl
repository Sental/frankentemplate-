# {{GENERATED_HEADER}}
#
# OpenSearch Dashboards (dev only), reached at https://search.<STORE_DOMAIN>/.
# Log in as admin with OPENSEARCH_ADMIN_PASSWORD from .env.
server.host: "0.0.0.0"

opensearch.hosts: ["https://{{PROJECT}}-opensearch:9200"]
opensearch.ssl.verificationMode: full
opensearch.ssl.certificateAuthorities: ["/usr/share/opensearch-dashboards/config/certs/root-ca.pem"]
opensearch.username: "kibanaserver"
opensearch.password: {{OPENSEARCH_DASHBOARDS_PASSWORD_YAML}}
opensearch.requestHeadersAllowlist: ["securitytenant", "Authorization"]

opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
# Caddy serves Dashboards over HTTPS, so the session cookie can require it.
opensearch_security.cookie.secure: true
