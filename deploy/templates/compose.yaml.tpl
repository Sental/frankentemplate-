# {{GENERATED_HEADER}}
#
# Services shared by every environment: the edge (Caddy), Varnish, the data services,
# and {{PROJECT}}-php, the abstract service every PHP role extends. The PHP roles live
# in the overlay for each mode:
#   compose.dev.yaml     {{PROJECT}}-app, -cron and -consumers on a dev image, code bind-mounted
#   compose.server.yaml  {{PROJECT}}-app-blue and -app-green (blue/green), -cron, -consumers
#
# Service keys, container names and hostnames are all <project>-<service>, with hyphens.
# An underscore isn't valid in a hostname, and OpenSearch's TLS (Java) rejects one in the
# server name a client sends, which fails the handshake. Volume and network keys keep
# Compose's own <project>_<key> naming: they're never hostnames.
#
# Nothing here is hardcoded to one project: bin/render substitutes the project name,
# paths and a few computed values, and every other value comes from .env.
name: {{PROJECT}}

x-logging: &logging
  # Bounded logs for every container. Docker's default json-file driver grows
  # without limit (FINDINGS F-17).
  driver: json-file
  options:
    max-size: "${LOG_MAX_SIZE:-10m}"
    max-file: "${LOG_MAX_FILE:-5}"

services:

  # ---------------------------------------------------------------------------
  # Abstract PHP service. scale: 0, so it never runs on its own; the PHP roles in
  # the overlays `extends` it and set scale: 1. Its environment is everything
  # generate-env-php.php builds env.php from.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-php:
    # A placeholder: never built, never pulled. Each role sets its real image.
    image: {{PROJECT}}-app:abstract
    pull_policy: never
    scale: 0
    init: true
    restart: unless-stopped
    logging: *logging
    networks:
      - backend
    environment:
      PROJECT_NAME: {{PROJECT}}
      STACK_ENV: ${STACK_ENV:-dev}
      MAGE_MODE: ${MAGE_MODE:-production}
      ADMIN_FRONT_NAME: ${ADMIN_FRONT_NAME:-admin}
      # Empty until installed: the entrypoint then writes no env.php.
      CRYPT_KEY: ${CRYPT_KEY:-}
      INSTALL_DATE: ${INSTALL_DATE:-}
      GRAPHQL_ID_SALT: ${GRAPHQL_ID_SALT:-}
      CACHE_ID_PREFIX: ${CACHE_ID_PREFIX:-}
      MAGENTO_CACHE_TYPES_EXTRA: ${MAGENTO_CACHE_TYPES_EXTRA:-}
      MAGENTO_CACHE_DISABLED: ${MAGENTO_CACHE_DISABLED:-}
      MAGENTO_PRELOAD_KEYS: ${MAGENTO_PRELOAD_KEYS:-GLOBAL_PLUGIN_LIST,DB_IS_UP_TO_DATE}
      MAGENTO_BASE_URL: ${MAGENTO_BASE_URL:-}
      FPC_BACKEND: ${FPC_BACKEND:-varnish}
      MAGENTO_CONSUMERS: ${MAGENTO_CONSUMERS:-}
      CONSUMER_MAX_MESSAGES: ${CONSUMER_MAX_MESSAGES:-1000}
      CRON_GROUPS: ${CRON_GROUPS:-default index}
      DB_QUERY_LOG: ${DB_QUERY_LOG:-disabled}
      MAX_REQUESTS: ${MAX_REQUESTS:-0}
      STORE_DOMAIN: ${STORE_DOMAIN:?set STORE_DOMAIN in .env}
      STORE_ALIASES: ${STORE_ALIASES:-}
      # Service hosts, named <project>-<service>.
      DB_HOST: {{PROJECT}}-mariadb
      DB_NAME: ${DB_NAME:-magento}
      DB_USER: ${DB_USER:-magento}
      DB_PASSWORD: ${DB_PASSWORD:?set DB_PASSWORD in .env}
      SESSION_HOST: {{PROJECT}}-valkey-session
      SESSION_PORT: "6379"
      CACHE_HOST: {{PROJECT}}-valkey-cache
      CACHE_PORT: "6379"
      AMQP_HOST: {{PROJECT}}-rabbitmq
      AMQP_PORT: "5672"
      RABBITMQ_USER: ${RABBITMQ_USER:-magento}
      RABBITMQ_PASSWORD: ${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD in .env}
      RABBITMQ_VHOST: ${RABBITMQ_VHOST:-/}
      OPENSEARCH_HOST: {{PROJECT}}-opensearch
      OPENSEARCH_PORT: "9200"
      OPENSEARCH_HTTPS: "1"
      OPENSEARCH_MAGENTO_USER: ${OPENSEARCH_MAGENTO_USER:-magento}
      OPENSEARCH_MAGENTO_PASSWORD: ${OPENSEARCH_MAGENTO_PASSWORD:?set OPENSEARCH_MAGENTO_PASSWORD in .env}
      OPENSEARCH_INDEX_PREFIX: ${OPENSEARCH_INDEX_PREFIX:-magento2}
      VARNISH_HOST: {{PROJECT}}-varnish
      VARNISH_BACKEND_HOST: {{VARNISH_BACKEND}}
      SMTP_HOST: ${SMTP_HOST:-}
      SMTP_PORT: ${SMTP_PORT:-587}
      SMTP_AUTH: ${SMTP_AUTH:-login}
      SMTP_SSL: ${SMTP_SSL:-tls}
      SMTP_USER: ${SMTP_USER:-}
      SMTP_PASSWORD: ${SMTP_PASSWORD:-}
    volumes:
      # The stack's private CA. The entrypoint adds it to the system trust store, so
      # ElasticSuite and core search can verify OpenSearch's certificate.
      - type: bind
        source: {{STACK_DIR}}/opensearch/certs/root-ca.pem
        target: /run/stack/opensearch-root-ca.pem
        read_only: true
        bind:
          create_host_path: false
    healthcheck:
      # Shallow on purpose. A deep check of / every few seconds would bypass the cache,
      # and an app bug would put the container into a restart loop. The deep check is
      # the release smoke test.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://localhost/health_check.php"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 120s

  # ---------------------------------------------------------------------------
  # Edge: TLS. Dev uses Caddy's local CA, servers use ACME. The Caddyfile is
  # rendered into .stack/caddy for each mode.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-caddy:
    image: caddy:${CADDY_TAG:-2-alpine}
    container_name: {{PROJECT}}-caddy
    restart: unless-stopped
    logging: *logging
    ports:
      - "${BIND_ADDRESS:-0.0.0.0}:${HTTP_PORT:-80}:80"
      - "${BIND_ADDRESS:-0.0.0.0}:${HTTPS_PORT:-443}:443"
      - "${BIND_ADDRESS:-0.0.0.0}:${HTTPS_PORT:-443}:443/udp"
    environment:
      STORE_DOMAIN: ${STORE_DOMAIN:?set STORE_DOMAIN in .env}
      ACME_EMAIL: ${ACME_EMAIL:-}
    command: ["caddy", "run", "--config", "/etc/caddy/stack/Caddyfile", "--adapter", "caddyfile"]
    volumes:
      # A directory, not the file: bin/render replaces the file by renaming a new
      # one into place, and a single-file bind mount would keep showing the old one.
      - {{STACK_DIR}}/caddy:/etc/caddy/stack:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - frontend

  # ---------------------------------------------------------------------------
  # Varnish: the full page cache. Its VCL is rendered with the admin path and the
  # active app (deploy/templates/varnish).
  #
  # Never publish Varnish's port. Its purge ACL trusts the private address ranges,
  # which is safe only while Caddy, which refuses PURGE and BAN, is the one way in.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-varnish:
    image: varnish:${VARNISH_TAG:-8-alpine}
    container_name: {{PROJECT}}-varnish
    restart: unless-stopped
    logging: *logging
    environment:
      VARNISH_SIZE: ${VARNISH_SIZE:-256m}
      VARNISH_VCL_FILE: /etc/varnish/stack/default.vcl
    # Magento's X-Magento-Tags header can outgrow Varnish's 8 KB limit on large
    # category pages, which then fail with a 503 (FINDINGS F-42). These are Adobe's
    # recommended values; raise them gradually if a 503 still appears.
    command: ["-p", "http_resp_hdr_len=65536", "-p", "http_resp_size=98304", "-p", "workspace_backend=98304"]
    volumes:
      - {{STACK_DIR}}/varnish:/etc/varnish/stack:ro
    networks:
      - frontend
      - backend
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/.varnish-health || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 3

  # ---------------------------------------------------------------------------
  # MariaDB
  # ---------------------------------------------------------------------------
  {{PROJECT}}-mariadb:
    image: mariadb:${MARIADB_TAG:-12}
    container_name: {{PROJECT}}-mariadb
    restart: unless-stopped
    logging: *logging
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD:?set DB_ROOT_PASSWORD in .env}
      MARIADB_DATABASE: ${DB_NAME:-magento}
      MARIADB_USER: ${DB_USER:-magento}
      MARIADB_PASSWORD: ${DB_PASSWORD:?set DB_PASSWORD in .env}
      # Runs mariadb-upgrade when a newer image starts on older data. A major-version
      # tag means a pull can move 12.x forward, so this has to be on.
      MARIADB_AUTO_UPGRADE: "1"
    command: ["--innodb-buffer-pool-size=${MARIADB_BUFFER_POOL:-1G}"]
    volumes:
      # A host path in MARIADB_DATA becomes a bind mount; empty means the named volume.
      - ${MARIADB_DATA:-mariadb_data}:/var/lib/mysql
      - {{DEPLOY_DIR}}/config/mariadb:/etc/mysql/conf.d:ro
    networks:
      - backend
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s

  # ---------------------------------------------------------------------------
  # Valkey for sessions: persistent (AOF), and evicts only keys that have a TTL,
  # so a full instance never drops a live session for cache data.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-valkey-session:
    image: valkey/valkey:${VALKEY_TAG:-9-alpine}
    container_name: {{PROJECT}}-valkey-session
    restart: unless-stopped
    logging: *logging
    # AOF on: a restart must not log out every customer and admin (FINDINGS F-13).
    command: ["valkey-server", "--appendonly", "yes", "--appendfsync", "everysec", "--save", "",
              "--maxmemory", "${VALKEY_SESSION_MEMORY:-256mb}", "--maxmemory-policy", "volatile-lru"]
    volumes:
      - valkey_session_data:/data
    networks:
      - backend
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3

  # ---------------------------------------------------------------------------
  # Valkey for the cache: ephemeral, and any key may be evicted. On a server,
  # blue and green each have their own key prefix, so size it for both during a
  # release.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-valkey-cache:
    image: valkey/valkey:${VALKEY_TAG:-9-alpine}
    container_name: {{PROJECT}}-valkey-cache
    restart: unless-stopped
    logging: *logging
    command: ["valkey-server", "--save", "", "--appendonly", "no",
              "--maxmemory", "${VALKEY_CACHE_MEMORY:-512mb}", "--maxmemory-policy", "allkeys-lru"]
    networks:
      backend:
        # The Mage-OS installer (bin/magento install) looks for a host called redis.
        aliases:
          - redis
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 3

  # ---------------------------------------------------------------------------
  # RabbitMQ
  # ---------------------------------------------------------------------------
  {{PROJECT}}-rabbitmq:
    image: rabbitmq:${RABBITMQ_TAG:-4.3-management-alpine}
    container_name: {{PROJECT}}-rabbitmq
    # The Erlang node is named after the hostname. With a container-generated
    # hostname, every recreate started an empty broker and every consumer exited.
    hostname: rabbitmq
    restart: unless-stopped
    logging: *logging
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER:-magento}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:?set RABBITMQ_PASSWORD in .env}
      RABBITMQ_DEFAULT_VHOST: ${RABBITMQ_VHOST:-/}
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
    networks:
      backend:
        # The installer's detector looks for a host called rabbitmq.
        aliases:
          - rabbitmq
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s

  # ---------------------------------------------------------------------------
  # OpenSearch: security on, TLS on both layers, analysis-phonetic built in
  # (deploy/config/opensearch). Certificates and users come from deploy/setup.
  # ---------------------------------------------------------------------------
  {{PROJECT}}-opensearch:
    build:
      context: {{DEPLOY_DIR}}/config/opensearch
      args:
        OPENSEARCH_TAG: ${OPENSEARCH_TAG:-3}
    image: {{PROJECT}}-opensearch:${OPENSEARCH_TAG:-3}
    container_name: {{PROJECT}}-opensearch
    restart: unless-stopped
    logging: *logging
    environment:
      # Variables named like settings become -E options to OpenSearch.
      cluster.name: {{PROJECT}}
      node.name: {{PROJECT}}-opensearch
      OPENSEARCH_JAVA_OPTS: "-Xms${OPENSEARCH_HEAP:-1g} -Xmx${OPENSEARCH_HEAP:-1g}"
      # The stack brings its own certificates and users; never install the demo ones.
      DISABLE_INSTALL_DEMO_CONFIG: "true"
      # Only the health check reads this.
      OPENSEARCH_ADMIN_PASSWORD: ${OPENSEARCH_ADMIN_PASSWORD:?set OPENSEARCH_ADMIN_PASSWORD in .env}
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - opensearch_data:/usr/share/opensearch/data
      - {{DEPLOY_DIR}}/config/opensearch/opensearch.yml:/usr/share/opensearch/config/opensearch.yml:ro
      - {{STACK_DIR}}/opensearch/certs:/usr/share/opensearch/config/certs:ro
      # The same three files as a directory, for bin/opensearch-security, which applies
      # them to the running cluster. A directory mount shows bin/render's newest files;
      # the single-file mounts below keep the old ones until the container is recreated.
      - {{STACK_DIR}}/opensearch/security:/run/stack/opensearch-security:ro
      # OpenSearch reads these three only when it first creates its security index.
      # They're single-file mounts, so a later bin/render needs a container recreate to
      # be seen, and it still has no effect once the index exists: bin/opensearch-security
      # is how a change reaches an existing cluster.
      - type: bind
        source: {{STACK_DIR}}/opensearch/security/internal_users.yml
        target: /usr/share/opensearch/config/opensearch-security/internal_users.yml
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: {{STACK_DIR}}/opensearch/security/roles.yml
        target: /usr/share/opensearch/config/opensearch-security/roles.yml
        read_only: true
        bind:
          create_host_path: false
      - type: bind
        source: {{STACK_DIR}}/opensearch/security/roles_mapping.yml
        target: /usr/share/opensearch/config/opensearch-security/roles_mapping.yml
        read_only: true
        bind:
          create_host_path: false
    networks:
      backend:
        # The installer's detector looks for a host called opensearch. Every other
        # client uses {{PROJECT}}-opensearch; the certificate names both.
        aliases:
          - opensearch
    healthcheck:
      # OPENSEARCH_ADMIN_PASSWORD goes inside double quotes here, so it must not
      # contain a double quote, `$`, a backtick or a backslash (setup's generator
      # never produces them).
      test: ["CMD-SHELL", "curl -fsS --cacert /usr/share/opensearch/config/certs/root-ca.pem -u \"admin:$$OPENSEARCH_ADMIN_PASSWORD\" https://localhost:9200/_cluster/health | grep -qv '\"status\":\"red\"'"]
      interval: 20s
      timeout: 10s
      retries: 10
      start_period: 90s

# Docker assigns both subnets. Nothing in the stack depends on them: Varnish's purge ACL
# trusts the private ranges instead (deploy/templates/varnish).
networks:
  frontend: {}
  backend: {}

volumes:
  caddy_data: {}
  caddy_config: {}
  mariadb_data: {}
  valkey_session_data: {}
  rabbitmq_data: {}
  opensearch_data: {}
