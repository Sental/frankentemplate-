# {{GENERATED_HEADER}}
#
# Server overlay (staging and production), on top of compose.yaml.
#
# Blue/green: two app services, only one of them active. COMPOSE_PROFILES (set by
# bin/render from ACTIVE_COLOR) starts only the active colour. A release starts the
# idle colour on the new image, smoke-tests it directly, points Varnish at it with a
# VCL reload, then stops the old one. Each colour pins its own image, so the old
# colour keeps running its own code until it's stopped.
#
# Cron and consumers run the active colour's image and cache namespace. bin/release
# recreates them after each switch.

x-server-php: &server-php
  scale: 1
  pull_policy: missing
  # Each app colour's cap. Cron and consumers set their own below: they run no
  # FrankenPHP workers, so their memory has nothing to do with the app's.
  mem_limit: ${APP_MEM_LIMIT:-3g}
  volumes:
    - ${DATA_DIR:?set DATA_DIR in .env}/media:/app/pub/media
    - ${DATA_DIR:?set DATA_DIR in .env}/var:/app/var
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

  {{PROJECT}}-app-blue:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *server-php
    profiles: ["blue"]
    container_name: {{PROJECT}}-app-blue
    image: ${APP_IMAGE_BLUE:-{{PROJECT}}-app:unset}
    command: ["web"]
    environment:
      # Gives this colour its own cache namespace (generate-env-php.php).
      STACK_COLOR: blue

  {{PROJECT}}-app-green:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *server-php
    profiles: ["green"]
    container_name: {{PROJECT}}-app-green
    image: ${APP_IMAGE_GREEN:-{{PROJECT}}-app:unset}
    command: ["web"]
    environment:
      STACK_COLOR: green

  {{PROJECT}}-cron:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *server-php
    container_name: {{PROJECT}}-cron
    image: ${APP_IMAGE_ACTIVE:-{{PROJECT}}-app:unset}
    # Two group loops (CRON_GROUPS) at once, each a bin/magento process.
    mem_limit: ${CRON_MEM_LIMIT:-2g}
    command: ["cron"]
    environment:
      STACK_COLOR: ${ACTIVE_COLOR:-blue}
    healthcheck:
      disable: true

  {{PROJECT}}-consumers:
    extends:
      file: compose.yaml
      service: {{PROJECT}}-php
    <<: *server-php
    container_name: {{PROJECT}}-consumers
    image: ${APP_IMAGE_ACTIVE:-{{PROJECT}}-app:unset}
    # One process per MAGENTO_CONSUMERS entry, under Supervisor.
    mem_limit: ${CONSUMERS_MEM_LIMIT:-2g}
    command: ["consumers"]
    environment:
      STACK_COLOR: ${ACTIVE_COLOR:-blue}
    healthcheck:
      disable: true

  # Varnish resolves its backend (the active colour) only when its VCL loads, and refuses
  # to load if the name doesn't resolve. Without this, a start could reach Varnish before
  # the app's container exists: the VCL failed, Docker restarted Varnish, and `up --wait`
  # failed setup. Docker knows a container's name as soon as it starts, so service_started
  # is enough; waiting for health would hold Varnish back for the app's whole boot. No `restart: true` as in dev: on a server a
  # colour switch is bin/release's VCL reload. Not covered: after a reboot Docker starts
  # the containers itself, without this order, and Varnish retries under its restart
  # policy until the app is up.
  {{PROJECT}}-varnish:
    depends_on:
      {{VARNISH_BACKEND}}:
        condition: service_started

  {{PROJECT}}-mariadb:
    mem_limit: ${MARIADB_MEM_LIMIT:-2g}

  {{PROJECT}}-opensearch:
    mem_limit: ${OPENSEARCH_MEM_LIMIT:-3g}
