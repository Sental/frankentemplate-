#!/usr/bin/env bash
# =============================================================================
# stack-entrypoint: the entrypoint for every PHP role in the stack.
#
#   web        FrankenPHP serving Magento (the default)
#   cron       one `bin/magento cron:run` loop per CRON_GROUPS entry, plus logrotate
#   consumers  Supervisor running one program per MAGENTO_CONSUMERS entry
#   <command>  anything else, run as given as www-data
#              (set STACK_RUN_AS=root to keep root, e.g. for a debugging shell)
#
# Each mode first does the privileged preparation as root (trusting the OpenSearch
# CA, creating and owning the writable directories, writing env.php), then drops to
# www-data. PHP never runs as root here: root-owned files in var/ and generated/ would
# break the www-data workers. Supervisor itself stays root so it can
# write to the container's stdout, but every program it starts runs as www-data.
# =============================================================================
set -euo pipefail

readonly MAGENTO_ROOT=/app
readonly APP_USER=www-data
readonly APP_HOME=/var/www
readonly CA_SOURCE=/run/stack/opensearch-root-ca.pem
readonly CA_TARGET=/usr/local/share/ca-certificates/stack-opensearch-root-ca.crt

log() { printf '[stack-entrypoint] %s\n' "$*" >&2; }

is_root() { [ "$(id -u)" -eq 0 ]; }

# The code is a Magento root once it has a composer.json. Until then (before
# `composer create-project` in a new project), touch nothing in /app.
is_magento_root() { [ -f "$MAGENTO_ROOT/composer.json" ]; }

# Magento counts as installed once .env carries its immutable values.
installed() { [ -n "${INSTALL_DATE:-}" ] && [ -n "${CRYPT_KEY:-}" ]; }

run_as_app() {
    if is_root; then
        setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups -- env HOME="$APP_HOME" "$@"
    else
        "$@"
    fi
}

exec_as_app() {
    if is_root; then
        exec setpriv --reuid="$APP_USER" --regid="$APP_USER" --init-groups -- env HOME="$APP_HOME" "$@"
    fi
    exec "$@"
}

# Wait forever with a reason. Used by roles that can't do anything useful yet.
# Sleeping beats exiting: an exit would put the container in a restart loop that
# hides the reason.
idle() {
    log "$*"
    exec sleep infinity
}

# -----------------------------------------------------------------------------
# Privileged preparation
# -----------------------------------------------------------------------------

trust_opensearch_ca() {
    [ -f "$CA_SOURCE" ] || return 0
    # ElasticSuite only offers a verify on/off switch, not a CA file, so the
    # stack's private CA must be in the system trust store for TLS verification.
    if ! cmp -s "$CA_SOURCE" "$CA_TARGET" 2>/dev/null; then
        cp "$CA_SOURCE" "$CA_TARGET"
        update-ca-certificates >/dev/null
        log "now trusting the OpenSearch CA from $CA_SOURCE"
    fi
}

ensure_dirs() {
    # FrankenPHP's embedded Caddy keeps state under XDG_CONFIG_HOME and XDG_DATA_HOME
    # (/config and /data in the image), and must be able to write it as www-data.
    install -d -o "$APP_USER" -g "$APP_USER" /config/caddy /data/caddy
    chown "$APP_USER:$APP_USER" "$APP_HOME"

    is_magento_root || return 0
    local dir
    for dir in var var/log var/cache var/session var/tmp var/report var/import var/export \
               generated generated/code generated/metadata pub/static pub/media; do
        # setgid, so directories created later inherit the group and stay group-writable.
        [ -d "$MAGENTO_ROOT/$dir" ] || install -d -o "$APP_USER" -g "$APP_USER" -m 2775 "$MAGENTO_ROOT/$dir"
    done
}

fix_ownership() {
    is_magento_root || return 0
    local dir paths=()
    for dir in var generated pub/static pub/media app/etc; do
        if [ -d "$MAGENTO_ROOT/$dir" ]; then paths+=("$MAGENTO_ROOT/$dir"); fi
    done
    [ "${#paths[@]}" -gt 0 ] || return 0
    # Only touch what www-data doesn't already own. A blanket chown -R gets slower
    # with every image uploaded, and delays every start.
    find "${paths[@]}" \( ! -user "$APP_USER" -o ! -group "$APP_USER" \) \
        -exec chown -h "$APP_USER:$APP_USER" {} +
}

prepare() {
    is_root || return 0
    trust_opensearch_ca
    ensure_dirs
    fix_ownership
}

write_env_php() {
    is_magento_root || return 0
    if ! installed; then
        log "CRYPT_KEY or INSTALL_DATE is empty, so Magento counts as not installed: env.php left as it is"
        return 0
    fi
    run_as_app php /usr/local/lib/stack/generate-env-php.php --write
}

# -----------------------------------------------------------------------------
# Modes
# -----------------------------------------------------------------------------

mode_web() {
    installed || log "warning: Magento isn't installed yet, so requests will fail until setup has run"
    if [ "${FRANKENPHP_WATCH:-0}" = "1" ]; then
        # Injected into each worker block of /etc/frankenphp/Caddyfile. Caddy expands
        # {$VAR} before it parses the file, so each line becomes its own directive.
        # Never watch files written at runtime (logs, caches): every write would restart
        # the workers.
        export FRANKENPHP_WORKER_EXTRA=$'watch /app/app/code/**/*.{php,xml}\nwatch /app/app/etc/*.php\nwatch /app/vendor/composer/installed.json'
        log "watch mode on: workers restart when code under app/code or app/etc changes"
    fi
    exec_as_app frankenphp run --config /etc/frankenphp/Caddyfile --adapter caddyfile
}

cron_loop() {
    local group=$1
    while :; do
        # Start on the minute boundary. A fixed `sleep 60` slips later by each run's
        # duration.
        sleep $(( 60 - $(date +%s) % 60 ))
        run_as_app php "$MAGENTO_ROOT/bin/magento" cron:run --group="$group" \
            || log "cron:run --group=$group exited $?"
    done
}

logrotate_loop() {
    while :; do
        sleep 86400
        run_as_app logrotate -s "$MAGENTO_ROOT/var/logrotate.state" /etc/stack/logrotate.conf \
            || log "logrotate exited $?"
    done
}

mode_cron() {
    installed || idle "cron waits for the install: recreate this container once setup has written CRYPT_KEY and INSTALL_DATE"
    trap 'trap - TERM INT; kill 0; exit 0' TERM INT
    local group pids=()
    for group in ${CRON_GROUPS:-default index}; do
        cron_loop "$group" &
        pids+=("$!")
    done
    logrotate_loop &
    pids+=("$!")
    log "cron running for groups: ${CRON_GROUPS:-default index}"
    # If any loop dies, exit, so Docker restarts the whole container rather than
    # leaving half of cron running.
    wait -n "${pids[@]}"
    log "a cron loop stopped; exiting so the container restarts"
    exit 1
}

mode_consumers() {
    installed || idle "consumers wait for the install: recreate this container once setup has written CRYPT_KEY and INSTALL_DATE"
    local conf=/tmp/supervisord.conf name program count=0
    local -a consumers=()
    cp /etc/stack/supervisord-consumers.conf "$conf"
    IFS=',' read -r -a consumers <<< "${MAGENTO_CONSUMERS:-}"
    for name in "${consumers[@]}"; do
        name="${name//[[:space:]]/}"
        [ -n "$name" ] || continue
        program="${name//[^A-Za-z0-9_-]/_}"
        cat >> "$conf" <<EOF

[program:${program}]
command=php ${MAGENTO_ROOT}/bin/magento queue:consumers:start ${name} --max-messages=${CONSUMER_MAX_MESSAGES:-1000}
directory=${MAGENTO_ROOT}
user=${APP_USER}
environment=HOME="${APP_HOME}"
autostart=true
autorestart=true
startsecs=5
startretries=10
stopwaitsecs=30
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || idle "MAGENTO_CONSUMERS is empty, so there are no consumers to run"
    log "running ${count} consumer(s): ${MAGENTO_CONSUMERS}"
    exec supervisord -c "$conf"
}

mode_command() {
    if [ "${STACK_RUN_AS:-app}" = "root" ]; then
        exec "$@"
    fi
    exec_as_app "$@"
}

main() {
    prepare
    write_env_php
    case "${1:-web}" in
        web)       mode_web ;;
        cron)      mode_cron ;;
        consumers) mode_consumers ;;
        *)         mode_command "$@" ;;
    esac
}

main "$@"
