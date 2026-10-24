# shellcheck shell=bash
# =============================================================================
# Checks deploy/setup makes before it changes anything. Each failure names what's
# wrong and how to fix it.
# =============================================================================

readonly MIN_COMPOSE_VERSION=2.24.0

version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

is_wsl() { grep -qi microsoft /proc/version 2>/dev/null; }

# preflight_docker: Docker, the compose plugin and buildx, all reachable.
preflight_docker() {
    command -v docker >/dev/null 2>&1 || die "docker isn't installed (on a server, setup server installs it)"
    docker info >/dev/null 2>&1 \
        || die "can't reach the Docker daemon: is Docker running, and is $(id -un) in the docker group?"
    local v
    v=$(docker compose version --short 2>/dev/null) || die "the docker compose plugin isn't installed"
    version_ge "${v#v}" "$MIN_COMPOSE_VERSION" \
        || die "docker compose $v is too old: $MIN_COMPOSE_VERSION or newer is needed (depends_on restart, scale: 0)"
    docker buildx version >/dev/null 2>&1 || die "docker buildx isn't installed (the Dockerfile needs BuildKit)"
}

# preflight_max_map_count: OpenSearch needs vm.max_map_count >= 262144. It's read
# inside a container: under Docker Desktop the value that counts belongs to Docker's
# VM, not the WSL distro.
preflight_max_map_count() {
    local n
    n=$(docker run --rm alpine:3 cat /proc/sys/vm/max_map_count)
    [ "$n" -ge 262144 ] && return 0
    if is_wsl; then
        die "Docker's VM has vm.max_map_count=$n; OpenSearch needs 262144. In PowerShell:
    wsl -d docker-desktop -u root sysctl -w vm.max_map_count=262144
To make it last, add this to %UserProfile%\\.wslconfig under [wsl2], then run wsl --shutdown:
    kernelCommandLine = \"sysctl.vm.max_map_count=262144\""
    fi
    die "vm.max_map_count is $n; OpenSearch needs 262144 (setup server sets it on a server)"
}
