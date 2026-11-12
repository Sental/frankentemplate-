# syntax=docker/dockerfile:1.29
# =============================================================================
# Magento / Mage-OS on FrankenPHP: one Dockerfile, three targets.
#
#   dev    the published build image (moving tag) plus the stack's config, Xdebug
#          enabled, and www-data remapped to your UID. The code is bind-mounted.
#   build  the published build image (dated tag). Installs dependencies, compiles DI
#          and deploys static content.
#   prod   the published runtime image (dated tag) plus the stack's config and the
#          build output. This is what servers run.
#
# The images come from sental90/mageos-frankenphp-docker: FrankenPHP, the PHP extensions,
# supervisor and logrotate (runtime), plus git, Node, Composer and Xdebug (build). Nothing
# here installs anything, so editing a stack file only redoes its COPY.
#
# PHP_VERSION (8.3, 8.4 or 8.5; setup passes it from .env) picks the images. Dev follows
# the moving tag, so it always has the newest image for its version. build and prod use
# the dated tags below, one pair per version: staging and production move only when a
# line is bumped to a newer datetime, and staging builds on it before production does.
# Adding a PHP version is two more lines.
#
# The build context is the Magento root. The stack's own files (config/, hooks/) come
# from a second, named context called `deploy` (this directory), so this Dockerfile works
# whether deploy/ sits inside the Magento repo or next to it:
#
#   docker build --build-context deploy=<deploy dir> -f <deploy dir>/Dockerfile \
#       --target prod --secret id=composer_auth,src=<auth.json> <magento root>
#
# Compose passes the named context through `additional_contexts`, and CI through
# build-push-action's `build-contexts`.
# =============================================================================

ARG PHP_VERSION=8.5

# The dated images, one runtime and one build per PHP version, published together.
FROM sental90/mageos-frankenphp-docker:8.3-runtime-202611042023 AS base-runtime-8.3
FROM sental90/mageos-frankenphp-docker:8.3-build-202611042023 AS base-build-8.3
FROM sental90/mageos-frankenphp-docker:8.4-runtime-202611042023 AS base-runtime-8.4
FROM sental90/mageos-frankenphp-docker:8.4-build-202611042023 AS base-build-8.4
FROM sental90/mageos-frankenphp-docker:8.5-runtime-202611042024 AS base-runtime-8.5
FROM sental90/mageos-frankenphp-docker:8.5-build-202611042024 AS base-build-8.5

# -----------------------------------------------------------------------------
# The stack's own files, laid out where they belong; dev and prod copy them in one step.
# The ini files aren't here: their directory is the image's $PHP_INI_DIR, which a scratch
# stage doesn't have.
FROM scratch AS stack
COPY --from=deploy config/frankenphp/Caddyfile /etc/frankenphp/Caddyfile
COPY --from=deploy config/app/supervisord-consumers.conf /etc/stack/supervisord-consumers.conf
COPY --from=deploy config/app/logrotate.conf /etc/stack/logrotate.conf
COPY --from=deploy config/app/generate-env-php.php /usr/local/lib/stack/generate-env-php.php
COPY --from=deploy config/app/core-cache-types.php /usr/local/lib/stack/core-cache-types.php
COPY --from=deploy --chmod=0755 config/app/entrypoint.sh /usr/local/bin/stack-entrypoint

# -----------------------------------------------------------------------------
FROM sental90/mageos-frankenphp-docker:${PHP_VERSION}-build AS dev

ARG UID=1000
ARG GID=1000

# Files the container writes into the bind-mounted code then belong to you, not
# to uid 33, so your editor and git never meet a file they can't write.
RUN groupmod -o -g "$GID" www-data \
    && usermod -o -u "$UID" -g "$GID" www-data

COPY --from=stack / /
COPY --from=deploy config/app/php.ini $PHP_INI_DIR/php.ini
# The dev OPcache settings: JIT off, which Xdebug needs.
COPY --from=deploy config/app/opcache.dev.ini $PHP_INI_DIR/conf.d/zz-opcache.ini
# The image only installs Xdebug; this ini loads it.
COPY --from=deploy config/app/xdebug.ini $PHP_INI_DIR/conf.d/zz-xdebug.ini

# opengento's pub/worker.php answers every request with a 500 unless this is set.
# Xdebug is loaded but idle until bin/xdebug switches the mode.
ENV FRANKENPHP_WORKER_ENABLE=1 \
    XDEBUG_MODE=off

WORKDIR /app
ENTRYPOINT ["stack-entrypoint"]
CMD ["web"]

# -----------------------------------------------------------------------------
# None of the stack's config comes in here: an edit to it mustn't rerun composer install
# or the compile. Composer raises its own memory limit, and the two compile steps set
# theirs. It runs on the same PHP build as prod's runtime image (the build image is built
# on it), so compiled output can never disagree with the PHP that executes it.
FROM base-build-${PHP_VERSION} AS build

ARG THEME_PATHS=""
ARG LOCALES="en_US"
ARG SCD_JOBS=1
ARG HOOK_ENV=""

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
# environment variable, so they never reach a layer. Written into the build context,
# they'd end up in the image and in every registry it's pushed to.
RUN --mount=type=secret,id=composer_auth,required=false \
    if [ -f /run/secrets/composer_auth ]; then export COMPOSER_AUTH="$(cat /run/secrets/composer_auth)"; fi; \
    composer install --no-dev --no-interaction --no-progress --prefer-dist --optimize-autoloader

RUN if [ -f /usr/local/lib/stack/hooks/post-composer.sh ]; then \
        env $HOOK_ENV bash /usr/local/lib/stack/hooks/post-composer.sh; \
    fi

# Any change to the code invalidates everything from here on (COPY keys on the files'
# contents), while the vendor layer above stays cached.
COPY . .

RUN set -e; for theme in $THEME_PATHS; do \
        (cd "$theme" && npm ci --no-audit --no-fund && npm run build); \
        rm -rf "$theme/node_modules"; \
    done

RUN php -d memory_limit=-1 bin/magento setup:di:compile --no-interaction
RUN php -d memory_limit=-1 bin/magento setup:static-content:deploy \
        --no-interaction -f -s standard -j "$SCD_JOBS" $LOCALES

# -----------------------------------------------------------------------------
FROM base-runtime-${PHP_VERSION} AS prod

COPY --from=stack / /
COPY --from=deploy config/app/php.ini $PHP_INI_DIR/php.ini
COPY --from=deploy config/app/opcache.ini $PHP_INI_DIR/conf.d/zz-opcache.ini

# opengento's pub/worker.php answers every request with a 500 unless this is set.
ENV FRANKENPHP_WORKER_ENABLE=1

WORKDIR /app
ENTRYPOINT ["stack-entrypoint"]
CMD ["web"]

COPY --from=build --chown=www-data:www-data /build /app

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost/health_check.php || exit 1
