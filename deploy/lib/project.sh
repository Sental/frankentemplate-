# shellcheck shell=bash
# =============================================================================
# New-project creation for `deploy/setup dev`, used when MAGENTO_ROOT has no
# composer.json, and the checks for a project that needs repairing.
# Composer runs in a one-off dev app container, never on the host.
# =============================================================================

# project_container_step STEP [ARGS]: runs one step of new-project.container.sh in a
# one-off dev app container, as www-data, with /app = MAGENTO_ROOT.
project_container_step() {
    compose run --rm --no-deps -T "$(service app)" bash -s -- "$@" \
        < "$DEPLOY_DIR/lib/new-project.container.sh"
}

# -----------------------------------------------------------------------------
# The state file
#
# .stack/new-project records a new project that setup started and hasn't finished:
# the Magento root's resolved path and the step it reached. project_new writes it
# before each step and removes it once the project has worker mode. It's the
# positive signal that the project is setup's own, so a re-run may offer to delete
# and recreate it. A project without one may be somebody's store, and is never
# offered for deletion.
# -----------------------------------------------------------------------------
project_state_file() { printf '%s/.stack/new-project' "$STACK_ROOT"; }

# MAGENTO_ROOT resolved, so the same directory always compares equal.
project_root_path() { realpath -m "$(magento_root)"; }

project_state_set() {
    mkdir -p "$STACK_ROOT/.stack"
    printf 'root=%s\nstep=%s\n' "$(project_root_path)" "$1" > "$(project_state_file)"
}

project_state_clear() { rm -f "$(project_state_file)"; }

# project_state_step: the step an unfinished new project in MAGENTO_ROOT reached, or
# nothing. A state file for another root gets a warning and is left alone.
project_state_step() {
    local file root
    file=$(project_state_file)
    [ -f "$file" ] || return 0
    root=$(dotenv_get "$file" root)
    if [ "$root" != "$(project_root_path)" ]; then
        warn "setup started a new project in $root and didn't finish it. MAGENTO_ROOT points elsewhere now, so it's left as it is: if you don't need it, delete it and $file."
        return 0
    fi
    dotenv_get "$file" step
}

# -----------------------------------------------------------------------------
# Creating, repairing and recreating
# -----------------------------------------------------------------------------

# project_new VERSION: a curated Mage-OS project, ready for FrankenPHP worker mode.
project_new() {
    local version=$1 root
    root=$(magento_root)
    if [ -d "$root" ] && [ -n "$(ls -A "$root" 2>/dev/null)" ]; then
        die "$root has files but no composer.json. Point MAGENTO_ROOT (or --magento-root) at a Magento project, or at an empty or missing directory for a new one."
    fi
    # Created by you, before any bind mount exists. If Docker created it for a mount, it
    # would belong to root, and nothing could write into it.
    mkdir -p "$root"

    project_state_set create
    info "creating a Mage-OS $version project in $root (composer create-project; this takes a few minutes)"
    project_container_step create "$version"

    project_state_set curate
    project_curate
    project_state_clear
}

# project_curate: adds FrankenPHP worker mode to the project in MAGENTO_ROOT. Safe to
# run again: each change to composer.json sets a value rather than appending one. The
# guard runs first, so a project it refuses is left exactly as it was.
project_curate() {
    local root
    root=$(magento_root)
    project_container_step guard

    # The patch goes in from the host: create-project needs an empty directory, so the
    # patch can't be put there earlier.
    mkdir -p "$root/patches/composer"
    cp "$DEPLOY_DIR/patches/opengento_bootstrappool_root_area.diff" "$root/patches/composer/"

    info "adding FrankenPHP worker mode: the opengento packages, mage-os/module-worker-mode and the root-area patch"
    project_container_step curate
}

# project_empty_root: deletes everything in MAGENTO_ROOT, keeping the directory
# itself (it may be a mount point, or a symlink's target). Only for a project setup
# started and didn't finish. It shows what goes and, in a terminal, asks you to type
# the project name; without one, --recreate was the confirmation.
project_empty_root() {
    local root count size answer
    root=$(project_root_path)
    [ -e "$root/.git" ] \
        && die "$root has a .git, so it's more than a new project setup didn't finish. Delete it yourself if you mean to, then re-run setup."
    count=$(find "$root" -mindepth 1 | wc -l)
    size=$(du -sh "$root" | cut -f1)
    warn "this deletes everything in $root: $count files and directories, $size"
    if [ -t 0 ]; then
        read -r -p "Type the project name to confirm: " answer
        [ "$answer" = "$(project)" ] || die "not confirmed; nothing deleted"
    fi
    find "$root" -mindepth 1 -delete
    info "emptied $root"
}

# project_resume STEP VERSION CHOICE: setup created the project in MAGENTO_ROOT and
# stopped at STEP. CHOICE is repair, recreate (from --repair/--recreate) or empty,
# which asks.
project_resume() {
    local step=$1 version=$2 choice=$3 root answer
    root=$(magento_root)
    case "$step" in
        create)
            warn "$root is a new project setup started, but composer create-project didn't finish. A partial create-project can't be resumed reliably, so it has to be created again."
            [ "$choice" = repair ] && die "--repair can't finish a create-project that stopped partway: use --recreate"
            if [ -z "$choice" ]; then
                [ -t 0 ] || die "run setup in a terminal to choose, or pass --recreate to delete the project and create it again"
                read -r -p "  d) delete it and create it again   q) stop, change nothing   [d/q]: " answer
                case "$answer" in
                    d|D) choice=recreate ;;
                    *)   die "stopped; nothing changed" ;;
                esac
            fi
            ;;
        curate)
            warn "$root is a new project setup started, but it stopped while adding worker mode."
            if [ -z "$choice" ]; then
                [ -t 0 ] || die "run setup in a terminal to choose, or pass --repair (re-run the worker-mode step) or --recreate (delete the project and create it again)"
                printf '%s\n' \
                    "  r) repair: re-run the worker-mode step, keeping the downloaded project" \
                    "  d) delete it and create it again" \
                    "  q) stop, change nothing" >&2
                read -r -p "Choose [r/d/q]: " answer
                case "$answer" in
                    r|R) choice=repair ;;
                    d|D) choice=recreate ;;
                    *)   die "stopped; nothing changed" ;;
                esac
            fi
            ;;
        *)
            die "$(project_state_file) records an unknown step '$step'. Check $root yourself, then delete that file."
            ;;
    esac

    case "$choice" in
        repair)
            project_curate
            project_state_clear
            ;;
        recreate)
            project_empty_root
            project_new "$version"
            ;;
    esac
}

# project_ensure_worker_mode CHOICE: for a project setup didn't create. The stack runs
# Magento in FrankenPHP worker mode only, so a project without it can't run here.
# Offers to add it (--repair adds it without asking). Never deletes anything.
project_ensure_worker_mode() {
    local choice=$1 status=0 answer
    project_container_step check || status=$?
    case "$status" in
        0) return 0 ;;
        3) ;;
        *) die "the worker-mode check of $(magento_root)/composer.json failed (exit $status; its error is above)" ;;
    esac

    warn "$(magento_root) has no FrankenPHP worker mode: its composer.json doesn't require opengento/magento2-frankenphp-base, and this stack runs Magento in worker mode only."
    [ "$choice" = recreate ] \
        && die "--recreate is only for a new project setup started and didn't finish; it never deletes yours. Pass --repair to add worker mode."
    if [ "$choice" != repair ]; then
        [ -t 0 ] || die "run setup in a terminal to choose, or pass --repair to add worker mode"
        printf '%s\n' \
            "Adding worker mode changes composer.json:" \
            "  - require: cweagans/composer-patches ^1.7, opengento/magento2-frankenphp-base ^0.9.4," \
            "    opengento/module-application 0.11.2, mage-os/module-worker-mode ^1.0" \
            "    (and laravel/prompts in require-dev, if it's missing)" \
            "  - replace: magento/magento2-base" \
            "  - extra.patches: the opengento root-area patch, copied to patches/composer/" \
            "  - extra.composer-exit-on-patch-failure: true, so a patch that stops applying fails the install" \
            "  - allow-plugins: cweagans/composer-patches, opengento/magento2-frankenphp-plugin" >&2
        read -r -p "  a) add worker mode   q) stop, change nothing   [a/q]: " answer
        case "$answer" in
            a|A) ;;
            *)   die "stopped; nothing changed" ;;
        esac
    fi
    project_curate
}

# project_add_hyva_worker_mode: after the installer has installed Hyvä.
project_add_hyva_worker_mode() {
    info "adding mage-os/module-worker-mode-hyva"
    project_container_step hyva
}
