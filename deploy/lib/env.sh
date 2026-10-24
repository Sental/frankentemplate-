# shellcheck shell=bash
# =============================================================================
# .env creation and filling for deploy/setup. Sourced after deploy/bin/_lib.sh.
#
# The rule: setup fills gaps and never overwrites a value that's already set. The only
# values it overwrites are ones you pass explicitly (--domain, --set KEY=VALUE, ...),
# and values it captures from an install or from an env.php you name with
# --from-env-php.
# =============================================================================

# rand_alnum N: N random letters and digits. It reads a fixed amount from
# /dev/urandom first, so no command in the pipeline is ever cut off by SIGPIPE
# (which pipefail would turn into a failure).
rand_alnum() {
    local n=$1 s
    s=$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    [ "${#s}" -ge "$n" ] || die "couldn't read enough randomness from /dev/urandom"
    printf '%s' "${s:0:$n}"
}

# A password that meets OpenSearch's policy (upper, lower, digit and symbol). The
# fixed ".Os1" suffix guarantees each class; the 24 random characters before it carry
# the entropy. The symbol is from -_.@%+= because the OpenSearch health check puts
# the password inside double quotes.
rand_opensearch_password() { printf '%s.Os1' "$(rand_alnum 24)"; }

# A password for Magento's admin, which needs letters and digits.
rand_admin_password() { printf '%s7a' "$(rand_alnum 20)"; }

env_init() {
    if [ ! -f "$ENV_FILE" ]; then
        install -m 0600 "$DEPLOY_DIR/.env.example" "$ENV_FILE"
        info "created $ENV_FILE from deploy/.env.example (mode 0600)"
    fi
}

# env_default KEY VALUE: sets KEY only if it's empty.
env_default() {
    [ -n "$(env_get "$1")" ] || env_set "$1" "$2"
}

# env_secret KEY GENERATOR: generates KEY with GENERATOR only if it's empty.
env_secret() {
    local key=$1 generator=$2
    if [ -z "$(env_get "$key")" ]; then
        env_set "$key" "$("$generator")"
        info "generated $key"
    fi
}

secret_db() { rand_alnum 32; }
secret_mq() { rand_alnum 32; }

# The secrets every environment needs. CRYPT_KEY and the other install values aren't
# here: the installer generates them, or --from-env-php imports them.
env_generate_secrets() {
    env_secret DB_PASSWORD secret_db
    env_secret DB_ROOT_PASSWORD secret_db
    env_secret RABBITMQ_PASSWORD secret_mq
    env_secret OPENSEARCH_ADMIN_PASSWORD rand_opensearch_password
    env_secret OPENSEARCH_MAGENTO_PASSWORD rand_opensearch_password
    env_secret OPENSEARCH_DASHBOARDS_PASSWORD rand_opensearch_password
}

# env_apply_sets KEY=VALUE...: the --set options. Explicit, so they overwrite.
env_apply_sets() {
    local pair
    for pair in "$@"; do
        [[ "$pair" == *=* ]] || die "--set needs KEY=VALUE (got '$pair')"
        env_set "${pair%%=*}" "${pair#*=}"
    done
}

# env_validate: stops on a .env the stack can't run with, naming the value.
env_validate() {
    local key value
    for key in OPENSEARCH_ADMIN_PASSWORD OPENSEARCH_MAGENTO_PASSWORD OPENSEARCH_DASHBOARDS_PASSWORD; do
        value=$(env_get "$key")
        [ -n "$value" ] || die "$key is empty"
        [[ "$value" =~ [A-Z] && "$value" =~ [a-z] && "$value" =~ [0-9] && "$value" =~ [^A-Za-z0-9] && ${#value} -ge 8 ]] \
            || die "$key doesn't meet OpenSearch's policy: 8+ characters, with upper, lower, digit and symbol"
        [[ "$value" =~ [\"\$\`\\\'] ]] && die "$key may not contain a quote, \$, backtick or backslash (the OpenSearch health check quotes it)"
    done
    for key in DB_PASSWORD DB_ROOT_PASSWORD RABBITMQ_PASSWORD STORE_DOMAIN; do
        [ -n "$(env_get "$key")" ] || die "$key is empty"
    done
    value=$(env_get STORE_DOMAIN)
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || die "STORE_DOMAIN must be a plain hostname (got '$value')"
    return 0
}

# env_read_env_php IMAGE FILE: prints "KEY<TAB>base64" lines for FILE, using
# deploy/lib/read-env-php.php inside IMAGE (any stack app image: it has PHP and the
# core cache type list).
env_read_env_php() {
    local image=$1 file=$2
    docker run --rm --entrypoint php \
        -v "$(readlink -f "$file"):/tmp/env.php:ro" \
        -v "$DEPLOY_DIR/lib/read-env-php.php:/tmp/read-env-php.php:ro" \
        "$image" /tmp/read-env-php.php /tmp/env.php
}

# env_import_lines: reads "KEY<TAB>base64" lines on stdin and writes them into .env.
# Empty values are skipped, so an env.php without a cache prefix doesn't blank one.
env_import_lines() {
    local key encoded value count=0
    while IFS=$'\t' read -r key encoded; do
        [ -n "$key" ] || continue
        value=$(printf '%s' "$encoded" | base64 -d)
        [ -n "$value" ] || continue
        env_set "$key" "$value"
        count=$((count + 1))
    done
    info "took $count value(s) from env.php into .env"
}

# env_import_env_php IMAGE FILE: --from-env-php. It takes over an existing store's
# immutable values. They must be copied, never regenerated: a new crypt key makes
# every encrypted config value unreadable.
env_import_env_php() {
    local image=$1 file=$2
    [ -f "$file" ] || die "--from-env-php: no such file: $file"
    env_read_env_php "$image" "$file" | env_import_lines
}
