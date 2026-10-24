# {{GENERATED_HEADER}}
#
# Dev overlay, on top of compose.yaml.
#   - One app container on the dev image, with the code bind-mounted. Cron and
#     consumers share that image.
#   - Mail always goes to Mailpit, whatever the database says, so an imported prod
#     database can't send real mail (FINDINGS F-10).
#   - The tools have no host ports. Caddy serves them on subdomains of STORE_DOMAIN,
#     and Caddy itself binds to 127.0.0.1 (FINDINGS F-21):
#       https://logs.<domain>    Dozzle (container logs, including the Magento log files)
#       https://mail.<domain>    Mailpit
#       https://pma.<domain>     phpMyAdmin
#       https://mq.<domain>      RabbitMQ management
#       https://search.<domain>  OpenSearch Dashboards (profile search-ui)

x-logging: &logging
  driver: json-file
  options:
    max-size: "${LOG_MAX_SIZE:-10m}"
    max-file: "${LOG_MAX_FILE:-5}"

# What every dev PHP role adds to the abstract {{PROJECT}}-php.
x-dev-php: &dev-php
  scale: 1
  image: {{PROJECT}}-app:dev
  volumes:
    - {{MAGENTO_ROOT}}:/app
  environment:
    SMTP_HOST: {{PROJECT}}-mailpit
    SMTP_PORT: "1025"
    SMTP_AUTH: none
    SMTP_SSL: none
    SMTP_USER: ""
    SMTP_PASSWORD: ""
  extra_hosts:
    - "host.docker.internal:host-gateway"
  depends_on:
    {{PROJECT}}-mariadb:
      condition: service_healthy
    {{PROJECT}}-valkey-session:
      condition: service_healthy
    {{PROJECT}}-valkey-cache:
      condition: service_healthy
    {{PROJECT}}-rabbitmq:
      condition: service_healthy
    {{PROJECT}}-opensearch:
      condition: service_healthy

services:

  {{PROJECT}}-app:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *dev-php
    container_name: {{PROJECT}}-app
    # Replaces the abstract service's `never`: build the dev image when it's missing.
    pull_policy: missing
    build:
      context: {{MAGENTO_ROOT}}
      dockerfile: {{DEPLOY_DIR}}/Dockerfile
      target: dev
      additional_contexts:
        deploy: {{DEPLOY_DIR}}
      args:
        PHP_VERSION: ${PHP_VERSION:-8.5}
        UID: ${HOST_UID:-1000}
        GID: ${HOST_GID:-1000}
    command: ["web"]
    environment:
      SMTP_HOST: {{PROJECT}}-mailpit
      SMTP_PORT: "1025"
      SMTP_AUTH: none
      SMTP_SSL: none
      SMTP_USER: ""
      SMTP_PASSWORD: ""
      FRANKENPHP_WATCH: ${FRANKENPHP_WATCH:-1}
      XDEBUG_MODE: ${XDEBUG_MODE:-off}

  {{PROJECT}}-cron:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *dev-php
    container_name: {{PROJECT}}-cron
    # Built by the app service above. `never` stops Compose trying to pull a local tag.
    pull_policy: never
    command: ["cron"]
    # Cron serves no HTTP; the inherited health check doesn't apply.
    healthcheck:
      disable: true

  {{PROJECT}}-consumers:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *dev-php
    container_name: {{PROJECT}}-consumers
    pull_policy: never
    command: ["consumers"]
    healthcheck:
      disable: true

  # Caddy also joins the backend network, to reach the app (for the Varnish bypass)
  # and the tools.
  {{PROJECT}}-caddy:
    networks:
      - frontend
      - backend

  # Recreating the app gives it a new IP, and Varnish only resolves its backend when
  # the VCL loads. Restarting Varnish with the app keeps it on the live container
  # (FINDINGS F-02). Servers use bin/release's VCL reload instead.
  {{PROJECT}}-varnish:
    depends_on:
      {{PROJECT}}-app:
        condition: service_healthy
        restart: true

  # ---- Dev tools --------------------------------------------------------------

  {{PROJECT}}-log-tailer:
    image: alpine:3
    container_name: {{PROJECT}}-log-tailer
    restart: unless-stopped
    logging: *logging
    command: ["sh", "/usr/local/bin/tail.sh"]
    volumes:
      - {{MAGENTO_ROOT}}/var:/mnt/var:ro
      - {{DEPLOY_DIR}}/config/log-tailer/tail.sh:/usr/local/bin/tail.sh:ro
    network_mode: none

  {{PROJECT}}-dozzle:
    image: amir20/dozzle:${DOZZLE_TAG:-v11}
    container_name: {{PROJECT}}-dozzle
    restart: unless-stopped
    logging: *logging
    environment:
      # Only this project's containers, not everything on the Docker host.
      DOZZLE_FILTER: label=com.docker.compose.project={{PROJECT}}
      DOZZLE_NO_ANALYTICS: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - backend

  {{PROJECT}}-mailpit:
    image: axllent/mailpit:${MAILPIT_TAG:-v1}
    container_name: {{PROJECT}}-mailpit
    restart: unless-stopped
    logging: *logging
    environment:
      MP_SMTP_AUTH_ACCEPT_ANY: "1"
      MP_SMTP_AUTH_ALLOW_INSECURE: "1"
      MP_MAX_MESSAGES: "5000"
      MP_DATABASE: /data/mailpit.db
    volumes:
      - mailpit_data:/data
    networks:
      - backend

  {{PROJECT}}-phpmyadmin:
    image: phpmyadmin:${PHPMYADMIN_TAG:-5}
    container_name: {{PROJECT}}-phpmyadmin
    restart: unless-stopped
    logging: *logging
    environment:
      PMA_HOST: {{PROJECT}}-mariadb
      # Logs straight in. Acceptable only because Caddy is reachable from 127.0.0.1 alone.
      PMA_USER: ${DB_USER:-magento}
      PMA_PASSWORD: ${DB_PASSWORD:?set DB_PASSWORD in .env}
      UPLOAD_LIMIT: 512M
    networks:
      - backend
    depends_on:
      {{PROJECT}}-mariadb:
        condition: service_healthy

  {{PROJECT}}-opensearch-dashboards:
    profiles: ["search-ui"]
    image: opensearchproject/opensearch-dashboards:${DASHBOARDS_TAG:-3}
    container_name: {{PROJECT}}-opensearch-dashboards
    restart: unless-stopped
    logging: *logging
    volumes:
      - {{STACK_DIR}}/opensearch/opensearch_dashboards.yml:/usr/share/opensearch-dashboards/config/opensearch_dashboards.yml:ro
      - {{STACK_DIR}}/opensearch/certs:/usr/share/opensearch-dashboards/config/certs:ro
    networks:
      - backend
    depends_on:
      {{PROJECT}}-opensearch:
        condition: service_healthy

volumes:
  mailpit_data: {}
