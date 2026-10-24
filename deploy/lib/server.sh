# shellcheck shell=bash
# =============================================================================
# Host provisioning for `deploy/setup server`, on Ubuntu or Debian.
#
# Each step checks first and acts only if it has to, so a re-run changes nothing
# that's already right. With --stack-only, no step installs or changes anything: each
# one only checks, every unmet prerequisite is collected, and setup stops listing
# them all.
# =============================================================================

UNMET=()

# server_need DESCRIPTION: records an unmet prerequisite (--stack-only) or stops.
server_need() {
    if [ "${STACK_ONLY:-0}" = "1" ]; then
        UNMET+=("$1")
    else
        die "$1"
    fi
}

server_report_unmet() {
    [ "${#UNMET[@]}" -eq 0 ] && return 0
    printf 'setup: --stack-only installs nothing, and these prerequisites are missing:\n' >&2
    printf '  - %s\n' "${UNMET[@]}" >&2
    printf 'Run setup server without --stack-only to install them, or fix them by hand.\n' >&2
    exit 1
}

server_require_root() {
    [ "$(id -u)" -eq 0 ] || die "setup server must run as root (sudo -E deploy/setup server ...), unless --stack-only"
}

server_os() {
    [ -r /etc/os-release ] || die "can't identify the OS (/etc/os-release is missing)"
    # shellcheck disable=SC1091 # a system file, read for ID and the codename only
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) printf '%s' "$ID" ;;
        *) die "setup server supports Ubuntu and Debian (this is '${ID:-unknown}'). Install Docker yourself and use --stack-only." ;;
    esac
}

# Docker Engine and the compose plugin, from Docker's own apt repository
# (https://docs.docker.com/engine/install/ubuntu/), not the distro's older packages.
server_docker() {
    if docker version --format '{{.Server.Version}}' >/dev/null 2>&1 \
        && docker compose version >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        info "Docker Engine $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short): present"
        return 0
    fi
    if [ "${STACK_ONLY:-0}" = "1" ]; then
        server_need "Docker Engine with the compose and buildx plugins"
        return 0
    fi
    local os codename
    os=$(server_os)
    # shellcheck disable=SC1091
    codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
    info "installing Docker Engine from download.docker.com ($os $codename)"
    apt-get update -q
    apt-get install -y -q ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$os/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$os
Suites: $codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -q
    apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
}

# vm.max_map_count for OpenSearch, persisted in /etc/sysctl.d.
server_sysctl() {
    local current
    current=$(cat /proc/sys/vm/max_map_count)
    if [ "$current" -ge 262144 ] && grep -qs 'vm.max_map_count' /etc/sysctl.d/*.conf /etc/sysctl.conf; then
        info "vm.max_map_count=$current, persisted: present"
        return 0
    fi
    if [ "${STACK_ONLY:-0}" = "1" ]; then
        [ "$current" -ge 262144 ] || server_need "vm.max_map_count >= 262144 (now $current)"
        return 0
    fi
    printf 'vm.max_map_count = 262144\n' > /etc/sysctl.d/99-opensearch.conf
    sysctl -q --system
    info "vm.max_map_count set to 262144 (/etc/sysctl.d/99-opensearch.conf)"
}

# server_deploy_user USER [PUBKEY_FILE]: the user CI deploys as, in the docker group.
server_deploy_user() {
    local user=$1 key=${2:-} home
    if id "$user" >/dev/null 2>&1; then
        info "deploy user '$user': present"
    elif [ "${STACK_ONLY:-0}" = "1" ]; then
        server_need "the deploy user '$user'"
        return 0
    else
        useradd -m -s /bin/bash "$user"
        info "created user '$user' (no password; SSH keys only)"
    fi
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        :
    elif [ "${STACK_ONLY:-0}" = "1" ]; then
        server_need "'$user' in the docker group"
    else
        usermod -aG docker "$user"
        info "added '$user' to the docker group"
    fi
    [ -n "$key" ] || return 0
    [ "${STACK_ONLY:-0}" = "1" ] && return 0
    [ -f "$key" ] || die "--deploy-key: no such file: $key"
    home=$(getent passwd "$user" | cut -d: -f6)
    install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
    touch "$home/.ssh/authorized_keys"
    if ! grep -qxF "$(cat "$key")" "$home/.ssh/authorized_keys"; then
        cat "$key" >> "$home/.ssh/authorized_keys"
        info "added the key from $key to $user's authorized_keys"
    fi
    chown "$user:$user" "$home/.ssh/authorized_keys"
    chmod 0600 "$home/.ssh/authorized_keys"
}

# The firewall: SSH, HTTP and HTTPS (and HTTP/3). SSH is allowed BEFORE ufw is
# enabled, so enabling it can't lock you out. Docker publishes only Caddy's ports, so
# nothing else is reachable even though Docker bypasses ufw for published ports.
server_firewall() {
    [ "${NO_FIREWALL:-0}" = "1" ] && { info "firewall: skipped (--no-firewall)"; return 0; }
    if ! command -v ufw >/dev/null 2>&1; then
        if [ "${STACK_ONLY:-0}" = "1" ]; then
            warn "ufw isn't installed; firewall not checked"
            return 0
        fi
        apt-get install -y -q ufw
    fi
    local status
    status=$(ufw status 2>/dev/null | head -n1)
    if [ "${STACK_ONLY:-0}" = "1" ]; then
        [[ "$status" == *active* && "$status" != *inactive* ]] || warn "ufw isn't active"
        return 0
    fi
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 443/udp >/dev/null
    if [[ "$status" == *inactive* ]]; then
        ufw --force enable >/dev/null
        info "ufw enabled: 22, 80, 443 (tcp) and 443 (udp) allowed"
    else
        info "ufw active; 22, 80 and 443 allowed"
    fi
}

# server_data_dirs DATA_DIR: owned the way each container needs. MariaDB runs as uid
# 999; Magento in the prod image as www-data, uid 33.
server_data_dirs() {
    local data=$1
    if [ "${STACK_ONLY:-0}" = "1" ]; then
        local d
        for d in mysql media var; do
            [ -d "$data/$d" ] || server_need "the data directory $data/$d"
        done
        return 0
    fi
    install -d -m 0750 -o 999 -g 999 "$data/mysql"
    install -d -m 2775 -o 33 -g 33 "$data/media" "$data/var"
    info "data directories under $data: present"
}
