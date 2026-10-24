# shellcheck shell=bash
# =============================================================================
# Getting a database for deploy/setup: either the Mage-OS installer (a fresh store)
# or a dump (an existing store).
#
# The installer route:
#   1. install_preseed   writes the installer's resume file with the stack's services
#                        and credentials (deploy/lib/preseed-installer.php)
#   2. install_handoff   runs `bin/magento install` interactively, in a one-off app
#                        container
#   3. install_capture   copies the values the installer generated (crypt key,
#                        install date, ...) from env.php into .env. From then on
#                        .env owns env.php.
#
# A failed install leaves env.php, tables and the maintenance flag behind, and a stale
# env.php is read back into the next attempt: bin/magento loads env.php when it starts,
# before the installer deletes it, so the retry ran with the old run's values. So:
#   - install_handoff records what's about to change in .stack/install/pending, and
#     moves any env.php to .stack/install/env.php.before, before bin/magento starts.
#   - When the installer fails, setup offers to put everything back (install_cleanup).
#   - If that's declined, or setup never got to ask (no terminal, Ctrl-C), the next run
#     sees the pending file and offers the same clean-up before anything else.
# The pending file is the proof that the leftovers are the failed install's own: setup
# writes it only for a database it has just checked is empty, so the clean-up may drop
# that database and nothing else.
# =============================================================================

resume_file() { printf '%s/var/.mageos-install-config.json' "$(magento_root)"; }

# db_table_count: how many tables Magento's database has. 0 means empty.
db_table_count() {
    "$STACK_ROOT/bin/mysql" -N -B -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()' \
        | tr -d '[:space:]'
}

# install_preseed ADMIN_PASSWORD SAMPLE_DATA(0|1) HYVA(0|1) LOCALE CURRENCY TIMEZONE
# HYVA_PROJECT_KEY and HYVA_API_TOKEN come from the environment when HYVA is 1.
install_preseed() {
    local admin_password=$1 sample=$2 hyva=$3 locale=$4 currency=$5 timezone=$6
    local -a vars=()
    local name

    # Exported and passed with `-e NAME`, so the values never appear in a process list.
    export PRESEED_DB_HOST PRESEED_DB_NAME PRESEED_DB_USER PRESEED_DB_PASSWORD \
        PRESEED_ADMIN_EMAIL PRESEED_ADMIN_USER PRESEED_ADMIN_PASSWORD PRESEED_ADMIN_FRONT_NAME \
        PRESEED_BASE_URL PRESEED_LOCALE PRESEED_CURRENCY PRESEED_TIMEZONE \
        PRESEED_OPENSEARCH_HOST PRESEED_OPENSEARCH_PREFIX PRESEED_OPENSEARCH_USER PRESEED_OPENSEARCH_PASSWORD \
        PRESEED_CACHE_HOST PRESEED_AMQP_HOST PRESEED_AMQP_USER PRESEED_AMQP_PASSWORD PRESEED_AMQP_VHOST \
        PRESEED_SAMPLE_DATA PRESEED_HYVA PRESEED_HYVA_PROJECT_KEY PRESEED_HYVA_API_TOKEN
    PRESEED_DB_HOST=$(service mariadb)
    PRESEED_DB_NAME=$(env_get DB_NAME magento)
    PRESEED_DB_USER=$(env_get DB_USER magento)
    PRESEED_DB_PASSWORD=$(env_get DB_PASSWORD)
    PRESEED_ADMIN_EMAIL="admin@$(env_get STORE_DOMAIN)"
    PRESEED_ADMIN_USER="admin"
    PRESEED_ADMIN_PASSWORD=$admin_password
    PRESEED_ADMIN_FRONT_NAME=$(env_get ADMIN_FRONT_NAME admin)
    PRESEED_BASE_URL=$(env_get MAGENTO_BASE_URL)
    PRESEED_LOCALE=$locale
    PRESEED_CURRENCY=$currency
    PRESEED_TIMEZONE=$timezone
    PRESEED_OPENSEARCH_HOST=$(service opensearch)
    PRESEED_OPENSEARCH_PREFIX=$(env_get OPENSEARCH_INDEX_PREFIX magento2)
    PRESEED_OPENSEARCH_USER=$(env_get OPENSEARCH_MAGENTO_USER magento)
    PRESEED_OPENSEARCH_PASSWORD=$(env_get OPENSEARCH_MAGENTO_PASSWORD)
    PRESEED_CACHE_HOST=$(service valkey-cache)
    PRESEED_AMQP_HOST=$(service rabbitmq)
    PRESEED_AMQP_USER=$(env_get RABBITMQ_USER magento)
    PRESEED_AMQP_PASSWORD=$(env_get RABBITMQ_PASSWORD)
    PRESEED_AMQP_VHOST=$(env_get RABBITMQ_VHOST /)
    PRESEED_SAMPLE_DATA=$sample
    PRESEED_HYVA=$hyva
    PRESEED_HYVA_PROJECT_KEY=${HYVA_PROJECT_KEY:-}
    PRESEED_HYVA_API_TOKEN=${HYVA_API_TOKEN:-}

    for name in $(compgen -v PRESEED_); do vars+=(-e "$name"); done
    compose run --rm --no-deps -T \
        -v "$DEPLOY_DIR/lib/preseed-installer.php:/tmp/preseed-installer.php:ro" \
        "${vars[@]}" "$(service app)" php /tmp/preseed-installer.php
}

install_guidance() {
    cat >&2 <<'EOF'

----------------------------------------------------------------------------------
Handing over to Mage-OS's installer (bin/magento install). The stack's services and
credentials are pre-filled, so most answers are "yes":

  Resume previous installation?             Yes
  Use saved ... configuration?              Yes, at each stage
                                            (No lets you change that stage's values)
  Configure cron?                           No  (the cron service runs Magento's cron)
  Configure email / SMTP?                   No  (env.php points mail at Mailpit)
  Disable Two-Factor Authentication?        No  (MageOS_WorkerMode depends on it, so
                                                 disabling it fails; harmless)

Redis is pre-set to "off" on purpose. The stack configures both Valkey instances in
env.php itself, on the next container start.
----------------------------------------------------------------------------------

EOF
}

# install_handoff CHOICE: the interactive installer. The resume file holds passwords, so
# it's removed afterwards whatever happens; a re-run of setup writes a fresh one. When
# the installer fails, it offers the clean-up (CHOICE repair answers yes).
install_handoff() {
    local choice=${1:-} status=0
    install_pending_begin
    install_guidance
    compose run --rm --no-deps "$(service app)" php bin/magento install || status=$?
    rm -f "$(resume_file)"
    if [ "$status" -ne 0 ]; then
        install_offer_cleanup "the install has failed (exit $status); its output is above." "$choice"
        die "cleaned up. Fix what the installer reported, then re-run the same deploy/setup command: it starts the installer again."
    fi
    install_pending_done
}

# -----------------------------------------------------------------------------
# The pending file, and the clean-up after a failed install
# -----------------------------------------------------------------------------
install_state_dir() { printf '%s/.stack/install' "$STACK_ROOT"; }
install_pending_file() { printf '%s/pending' "$(install_state_dir)"; }

# install_pending: true when a failed install in this MAGENTO_ROOT and database hasn't
# been cleaned up. A pending file for another root or database is reported and left.
install_pending() {
    local file root db
    file=$(install_pending_file)
    [ -f "$file" ] || return 1
    root=$(dotenv_get "$file" root)
    db=$(dotenv_get "$file" db)
    if [ "$root" != "$(project_root_path)" ] || [ "$db" != "$(env_get DB_NAME magento)" ]; then
        warn "$file records a failed install in $root (database $db), but MAGENTO_ROOT or DB_NAME has changed since, so it's left alone. Delete it once you've dealt with that install yourself."
        return 1
    fi
}

# install_pending_begin: records the state the installer starts from, then moves any
# env.php aside so bin/magento can't load it.
install_pending_begin() {
    local dir env_php maintenance=0 tables
    dir=$(install_state_dir)
    env_php="$(magento_root)/app/etc/env.php"
    [ -e "$dir/env.php.before" ] \
        && die "$dir/env.php.before is left from an install that was neither finished nor cleaned up. It holds that env.php: move it somewhere else, then re-run setup."
    [ -f "$(magento_root)/var/.maintenance.flag" ] && maintenance=1
    tables=$(db_table_count)
    mkdir -p "$dir"
    printf 'root=%s\ndb=%s\ntables_before=%s\nmaintenance=%s\n' \
        "$(project_root_path)" "$(env_get DB_NAME magento)" "$tables" "$maintenance" > "$(install_pending_file)"
    if [ -f "$env_php" ]; then
        mv "$env_php" "$dir/env.php.before"
        chmod 0600 "$dir/env.php.before"
        info "moved the existing env.php to $dir/env.php.before: bin/magento loads env.php when it starts, so the installer would have run with its old values. A clean-up after a failed install puts it back."
    fi
}

# install_pending_done: the install succeeded. Any env.php it replaced is kept.
install_pending_done() {
    local dir kept
    dir=$(install_state_dir)
    if [ -f "$dir/env.php.before" ]; then
        kept="$dir/env.php.replaced-$(date -u +%Y%m%d-%H%M%S)"
        mv "$dir/env.php.before" "$kept"
        info "the env.php this install replaced is kept at $kept. It holds that store's crypt key: to set the stack up from it instead, use --import with --from-env-php. Otherwise delete it."
    fi
    rm -f "$(install_pending_file)"
}

# install_offer_cleanup CONTEXT CHOICE: says what the clean-up would undo and asks.
# CHOICE repair answers yes. Returns once cleaned up; anything else stops setup.
install_offer_cleanup() {
    local context=$1 choice=$2 root db tables answer
    local -a undo=()
    root=$(magento_root)
    db=$(env_get DB_NAME magento)
    tables=$(db_table_count)
    if [ -f "$(install_state_dir)/env.php.before" ]; then
        undo+=("  - env.php:      removes the one the failed install wrote, and restores the previous one")
    elif [ -f "$root/app/etc/env.php" ]; then
        undo+=("  - env.php:      removes the one the failed install wrote (there was none before)")
    fi
    if [ "$tables" != "0" ]; then
        undo+=("  - database:     drops and recreates '$db', which has $tables tables from the failed install (it had none before)")
    fi
    if [ "$(dotenv_get "$(install_pending_file)" maintenance 0)" = "0" ] && [ -f "$root/var/.maintenance.flag" ]; then
        undo+=("  - maintenance:  turns it off (the installer turned it on)")
    fi
    [ ${#undo[@]} -gt 0 ] || undo+=("  - nothing to undo: no env.php, the database is empty, maintenance is off")

    warn "$context"
    printf '%s\n' "Clean up, to prepare for a retry? This puts things back as they were before the installer ran:" "${undo[@]}" >&2
    if [ "$choice" != repair ]; then
        [ -t 0 ] || die "nothing has been cleaned up. Re-run deploy/setup in a terminal to be asked, or with --repair to clean up and retry."
        read -r -p "Clean up? [Y/n] " answer
        case "$answer" in
            ""|y|Y|yes|Yes) ;;
            *) die "left as it failed, so you can look at it. The next deploy/setup run offers the same clean-up." ;;
        esac
    fi
    install_cleanup
}

# install_cleanup: puts back what the failed install changed. Only called while
# install_pending holds, so the database is provably the failed install's own.
install_cleanup() {
    local dir root db file
    dir=$(install_state_dir)
    root=$(magento_root)
    db=$(env_get DB_NAME magento)
    file=$(install_pending_file)
    [ "$(dotenv_get "$file" tables_before)" = "0" ] \
        || die "$file says the database wasn't empty before the install, so setup won't drop it. Check it yourself, then delete $file."

    rm -f "$root/app/etc/env.php"
    if [ -f "$dir/env.php.before" ]; then
        mv "$dir/env.php.before" "$root/app/etc/env.php"
        info "restored the previous env.php"
    fi
    if [ "$(dotenv_get "$file" maintenance 0)" = "0" ]; then
        rm -f "$root/var/.maintenance.flag"
    fi
    if [ "$(db_table_count)" != "0" ]; then
        # Only a plain name goes into the SQL: anything but letters, digits and
        # underscores is refused, not escaped.
        [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] \
            || die "DB_NAME '$db' has characters setup won't put into a DROP DATABASE. Drop and recreate it yourself, then delete $file."
        info "dropping and recreating database '$db'"
        # What setup:install's own --cleanup-database does, as the same user.
        "$STACK_ROOT/bin/mysql" -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\`"
    fi
    rm -f "$file"
    info "cleaned up: the installer can run again"
}

# install_capture: takes what the installer generated into .env, then shows what
# changes when the stack regenerates env.php from .env on the next start.
install_capture() {
    local env_php
    env_php="$(magento_root)/app/etc/env.php"
    [ -f "$env_php" ] || die "the installer finished, but there's no $env_php"
    compose run --rm --no-deps -T --entrypoint php \
        -v "$DEPLOY_DIR/lib/read-env-php.php:/tmp/read-env-php.php:ro" \
        "$(service app)" /tmp/read-env-php.php /app/app/etc/env.php | env_import_lines
    info "on the next start, env.php is regenerated from .env. What changes from the installer's version (secrets masked):"
    compose run --rm --no-deps -T --entrypoint php "$(service app)" \
        /usr/local/lib/stack/generate-env-php.php --diff || true
}

# install_import FILE: loads a .sql or .sql.gz dump into an empty database.
install_import() {
    local file=$1 tables
    [ -f "$file" ] || die "--import: no such file: $file"
    tables=$(db_table_count)
    [ "$tables" = "0" ] \
        || die "the database already has $tables tables. --import loads only into an empty database (bin/stop -v deletes the volumes; mind MARIADB_DATA)."
    info "importing $file"
    case "$file" in
        *.gz) gunzip -c "$file" | "$STACK_ROOT/bin/mysql" ;;
        *)    "$STACK_ROOT/bin/mysql" < "$file" ;;
    esac
}
