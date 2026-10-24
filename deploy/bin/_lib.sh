# shellcheck shell=bash
# =============================================================================
# Shared helpers for deploy/bin/*. Sourced, never run directly.
#
# STACK_ROOT is the directory holding .env and the rendered compose files: the
# parent of the `bin` symlink deploy/setup creates. The scripts are meant to be
# called as <root>/bin/<name>. To call them by another path, set STACK_ROOT.
#
# .env is never `source`d. It holds values bash can't parse (spaces, `$`): INSTALL_DATE
# alone, "Sat, 14 Feb 2026 09:02:44 +0000", breaks a sourced .env. Compose reads it
# itself; scripts read single keys with env_get.
# =============================================================================
set -euo pipefail

if [ -z "${STACK_ROOT:-}" ]; then
    # Logical path (no -P): the `bin` symlink's parent, not deploy/.
    STACK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
readonly STACK_ROOT
readonly ENV_FILE="$STACK_ROOT/.env"
# The real deploy/ directory, wherever the symlink points.
DEPLOY_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck disable=SC2034 # used by the scripts that source this file (render, build, hooks); shellcheck can't see them when it lints this file alone
readonly DEPLOY_DIR

die()  { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$(basename "$0")" "$*" >&2; }
info() { printf '%s: %s\n' "$(basename "$0")" "$*" >&2; }

require_env_file() {
    [ -f "$ENV_FILE" ] || die "no .env in $STACK_ROOT. Run deploy/setup first, or call this as <project root>/bin/$(basename "$0")."
}

# dotenv_get FILE KEY [DEFAULT]: the value of KEY in a dotenv file, parsed the way
# Compose parses it. One pair of surrounding quotes is stripped; an unquoted value
# loses a trailing ` # comment`. Missing or empty gives DEFAULT.
dotenv_get() {
    local file=$1 key=$2 default=${3:-} value
    if [ -f "$file" ] && value=$(KEY="$key" awk '
        BEGIN { key = ENVIRON["KEY"]; found = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
            if (index(line, key "=") == 1) { found = 1; value = substr(line, length(key) + 2) }
        }
        END {
            if (!found) exit 1
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) {
                value = substr(value, 2, length(value) - 2)
            } else {
                sub(/[[:space:]]+#.*$/, "", value)
                sub(/[[:space:]]+$/, "", value)
            }
            print value
        }' "$file"); then
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return 0
        fi
    fi
    printf '%s' "$default"
}

env_get() {
    require_env_file
    dotenv_get "$ENV_FILE" "$@"
}

# env_set KEY VALUE: writes KEY=VALUE into .env, replacing an existing line or
# appending one. The file's mode is kept (setup creates it 0600), and the new file
# is renamed into place. Values containing spaces or shell-special characters are
# single-quoted, which Compose reads literally.
env_set() {
    local key=$1 value=$2 quoted tmp
    require_env_file
    case "$value" in
        *"'"*|*$'\n'*) die "env_set: the value for $key may not contain a single quote or a newline" ;;
    esac
    quoted=$value
    if [[ "$value" =~ [[:space:]\$\"\#\\\`] ]]; then
        quoted="'$value'"
    fi
    tmp="$ENV_FILE.tmp.$$"
    cp -p "$ENV_FILE" "$tmp"
    KEY="$key" LINE="$key=$quoted" awk '
        BEGIN { key = ENVIRON["KEY"]; line = ENVIRON["LINE"]; done = 0 }
        {
            stripped = $0
            sub(/^[[:space:]]*/, "", stripped)
            if (index(stripped, key "=") == 1) {
                if (!done) { print line; done = 1 }
                next
            }
            print
        }
        END { if (!done) print line }' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

# PROJECT_NAME starts every service, container and hostname: <project>-<service>. So it
# must fit in a hostname label: lowercase letters and digits with single hyphens
# between them, and at most 41 characters, which keeps the longest name,
# <project>-opensearch-dashboards, within a label's 63. No underscores: they aren't
# valid in a hostname, and OpenSearch's TLS rejects them in the name a client sends.
project() {
    local name
    name=$(env_get PROJECT_NAME)
    if ! [[ "$name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || [ "${#name}" -gt 41 ]; then
        die "PROJECT_NAME must be lowercase letters and digits, with single hyphens between them, starting with a letter, at most 41 characters (got '$name'). It's part of every hostname, and a hostname can't contain an underscore."
    fi
    printf '%s' "$name"
}

stack_env() { env_get STACK_ENV dev; }

is_dev() { [ "$(stack_env)" = "dev" ]; }

# dev_profile_on NAME: true when DEV_PROFILES (comma separated, default search-ui;
# `none` for none) includes NAME.
dev_profile_on() {
    local profiles
    profiles=$(env_get DEV_PROFILES search-ui)
    [[ ",${profiles// /}," == *",$1,"* ]]
}

require_dev() {
    is_dev || die "dev only: STACK_ENV is '$(stack_env)'"
}

# The Magento root as an absolute path. MAGENTO_ROOT may be relative to STACK_ROOT.
magento_root() {
    local root
    root=$(env_get MAGENTO_ROOT src)
    case "$root" in
        /*) printf '%s' "$root" ;;
        *)  printf '%s' "$STACK_ROOT/$root" ;;
    esac
}

# The app service in use: <project>-app in dev, <project>-app-<colour> on a server.
app_service() {
    if is_dev; then
        printf '%s-app' "$(project)"
    else
        printf '%s-app-%s' "$(project)" "$(env_get ACTIVE_COLOR blue)"
    fi
}

# Maps a short service name (app, cron, mariadb, valkey-session, ...) to its full name,
# <project>-<name>. Names that already carry the project prefix are passed through
# unchanged.
service() {
    local name=$1 prefix
    prefix="$(project)-"
    case "$name" in
        app)          app_service ;;
        "$prefix"*)   printf '%s' "$name" ;;
        *)            printf '%s%s' "$prefix" "$name" ;;
    esac
}

# map_args ARGS...: fills the global array MAPPED with ARGS, service names mapped
# through `service` and flags (anything starting with -) unchanged.
map_args() {
    local arg
    MAPPED=()
    for arg in "$@"; do
        case "$arg" in
            -*) MAPPED+=("$arg") ;;
            *)  MAPPED+=("$(service "$arg")") ;;
        esac
    done
}

# Runs docker compose against this stack, with every file passed explicitly. The
# result doesn't depend on which directory Compose would read COMPOSE_FILE from.
compose() {
    local files file
    local -a list=() args=()
    files=$(env_get COMPOSE_FILE)
    [ -n "$files" ] || die "COMPOSE_FILE is empty in .env: run bin/render"
    IFS=':' read -r -a list <<< "$files"
    for file in "${list[@]}"; do
        args+=(-f "$STACK_ROOT/$file")
    done
    docker compose --project-directory "$STACK_ROOT" --env-file "$ENV_FILE" "${args[@]}" "$@"
}

# caddy_reload: makes a running edge re-read the rendered Caddyfile, without dropping
# connections. A running Caddy never notices a new file on its own, and `compose up`
# doesn't recreate it for one. Run bin/render first. When Caddy isn't running, there's
# nothing to reload: it reads the file when it starts.
caddy_reload() {
    if [ -n "$(compose ps -q --status running "$(service caddy)")" ]; then
        compose exec -T "$(service caddy)" caddy reload --config /etc/caddy/stack/Caddyfile --adapter caddyfile
    else
        info "Caddy isn't running; it reads the new Caddyfile when it starts"
    fi
}

# -T when there's no terminal, so the same command works interactively and in pipes.
tty_flag() {
    if [ -t 0 ] && [ -t 1 ]; then printf ''; else printf -- '-T'; fi
}

# Runs a command in the app container as www-data. PHP never runs as root: the files
# it created would be root's, and the www-data workers couldn't write them.
php_exec() {
    local tty
    tty=$(tty_flag)
    # shellcheck disable=SC2086 # $tty is empty or exactly -T
    compose exec $tty -u www-data "$(app_service)" "$@"
}
