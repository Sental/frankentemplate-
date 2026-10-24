# syntax=docker/dockerfile:1.7
# =============================================================================
# Magento / Mage-OS on FrankenPHP: one Dockerfile, four targets.
#
#   base   FrankenPHP, the PHP extensions and the stack's config. The runtime of
#          every PHP role: web, cron, consumers.
#   dev    base plus Composer, Node, git and Xdebug, with www-data remapped to your
#          UID. The code is bind-mounted; nothing is baked in.
#   build  base plus Composer and Node. Installs dependencies, compiles DI and deploys
#          static content. It runs on the same PHP build as runtime, so compiled
#          output can never disagree with the PHP that executes it.
#   prod   base plus the build output. This is what servers run.
#
# The build context is the Magento root. The stack's own files (config/, hooks/)
# come from a second, named context called `deploy` (this directory), so this
# Dockerfile works whether deploy/ sits inside the Magento repo or next to it:
#
#   docker build --build-context deploy=<deploy dir> -f <deploy dir>/Dockerfile \
#       --target prod --secret id=composer_auth,src=<auth.json> <magento root>
#
# Compose passes the named context through `additional_contexts`, and CI through
# build-push-action's `build-contexts`.
# =============================================================================

ARG PHP_VERSION=8.5

# -----------------------------------------------------------------------------
FROM dunglas/frankenphp:1-php${PHP_VERSION} AS base

# supervisor runs the queue consumers; logrotate keeps var/log bounded.
RUN apt-get update \
    && apt-get install -y --no-install-recommends supervisor logrotate \
    && rm -rf /var/lib/apt/lists/*

# install-php-extensions resolves each extension's system libraries and skips
# anything the base image already provides. Sodium (used to encrypt the SMTP
# password in env.php) is part of PHP core.
RUN install-php-extensions \
    bcmath gd intl pdo_mysql soap sockets xsl zip opcache \
    igbinary redis imagick pcntl ftp mbstring

COPY --from=deploy config/app/php.ini $PHP_INI_DIR/php.ini
COPY --from=deploy config/app/opcache.ini $PHP_INI_DIR/conf.d/zz-opcache.ini
COPY --from=deploy config/frankenphp/Caddyfile /etc/frankenphp/Caddyfile
COPY --from=deploy config/app/supervisord-consumers.conf /etc/stack/supervisord-consumers.conf
COPY --from=deploy config/app/logrotate.conf /etc/stack/logrotate.conf
COPY --from=deploy config/app/generate-env-php.php /usr/local/lib/stack/generate-env-php.php
COPY --from=deploy config/app/core-cache-types.php /usr/local/lib/stack/core-cache-types.php
COPY --from=deploy --chmod=0755 config/app/entrypoint.sh /usr/local/bin/stack-entrypoint

# opengento's pub/worker.php answers every request with a 500 unless this is set.
ENV FRANKENPHP_WORKER_ENABLE=1

WORKDIR /app
ENTRYPOINT ["stack-entrypoint"]
CMD ["web"]

# -----------------------------------------------------------------------------
FROM base AS dev

ARG UID=1000
ARG GID=1000

RUN apt-get update \
    && apt-get install -y --no-install-recommends git unzip nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# The dev OPcache settings (JIT off) must be in place before Xdebug is installed.
# install-php-extensions test-loads each extension; with base's prod JIT still on,
# PHP warns "JIT is incompatible with third party extensions that override
# zend_execute_ex()", and the tool counts that warning as a failed load.
COPY --from=deploy config/app/opcache.dev.ini $PHP_INI_DIR/conf.d/zz-opcache.ini
COPY --from=deploy config/app/xdebug.ini $PHP_INI_DIR/conf.d/zz-xdebug.ini
RUN install-php-extensions xdebug @composer

# Files the container writes into the bind-mounted code then belong to you, not
# to uid 33, so your editor and git never meet a file they can't write.
RUN groupmod -o -g "$GID" www-data \
    && usermod -o -u "$UID" -g "$GID" www-data

# Xdebug is loaded but idle until bin/xdebug switches the mode.
ENV XDEBUG_MODE=off

# -----------------------------------------------------------------------------
FROM base AS build

ARG THEME_PATHS=""
ARG LOCALES="en_US"
ARG SCD_JOBS=1
ARG HOOK_ENV=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends git unzip nodejs npm \
    && rm -rf /var/lib/apt/lists/*
RUN install-php-extensions @composer

WORKDIR /build

# Project-specific build steps: see deploy/hooks/README.md. HOOK_ENV carries their
# inputs as space-separated KEY=VALUE pairs.
COPY --from=deploy hooks/ /usr/local/lib/stack/hooks/
RUN if [ -f /usr/local/lib/stack/hooks/pre-composer.sh ]; then \
        env $HOOK_ENV bash /usr/local/lib/stack/hooks/pre-composer.sh; \
    fi

# Dependencies first, so this layer is reused until composer.lock changes.
# patches/ must exist, even if empty: cweagans/composer-patches reads it.
COPY composer.json composer.lock ./
COPY patches/ patches/
# The credentials arrive as a BuildKit secret and are only ever held in an
# environment variable, so they never reach a layer. Writing them into the build
# context is how they ended up in every pushed image (FINDINGS F-01).
RUN --mount=type=secret,id=composer_auth,required=false \
    if [ -f /run/secrets/composer_auth ]; then export COMPOSER_AUTH="$(cat /run/secrets/composer_auth)"; fi; \
    composer install --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader

RUN if [ -f /usr/local/lib/stack/hooks/post-composer.sh ]; then \
        env $HOOK_ENV bash /usr/local/lib/stack/hooks/post-composer.sh; \
    fi

# CI passes a hash of app/code and app/design: any change there busts the cache
# from this point on, while the vendor layer above stays cached.
ARG APP_CODE_HASH
COPY . .

RUN set -e; for theme in $THEME_PATHS; do \
        (cd "$theme" && npm ci --no-audit --no-fund && npm run build); \
        rm -rf "$theme/node_modules"; \
    done

RUN php -d memory_limit=-1 bin/magento setup:di:compile --no-interaction
RUN php -d memory_limit=-1 bin/magento setup:static-content:deploy \
        --no-interaction -f -s standard -j "$SCD_JOBS" $LOCALES

# -----------------------------------------------------------------------------
FROM base AS prod

COPY --from=build --chown=www-data:www-data /build /app

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost/health_check.php || exit 1
