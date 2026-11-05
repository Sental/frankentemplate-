#!/usr/bin/env bash
# =============================================================================
# prod-build-check.sh MAGENTO_ROOT PHP_VERSION: checks that a project is ready for a
# production image build. bin/build runs it, and so does CI (.github/workflows/image.yml).
#
# A build has no database, so static content deploy reads the stores and themes from
# app/etc/config.php: its scopes, themes and i18n sections, which a project gets from
# `bin/magento app:config:dump scopes themes i18n` in dev. Without them the build fails
# minutes in, at static content deploy, with "The default website isn't defined"; this
# check fails in seconds instead.
#
# PHP reads the file, in the published runtime image for PHP_VERSION, so formatting can't
# fool it. It only asks whether each section exists: an empty i18n is valid.
# =============================================================================
set -euo pipefail

usage="usage: prod-build-check.sh <magento root> <php version, e.g. 8.5>"
root=${1:?$usage}
php=${2:?$usage}

fail() {
    printf 'prod-build-check: %s\n' "$*" >&2
    exit 1
}

[ -f "$root/app/etc/config.php" ] \
    || fail "no $root/app/etc/config.php: a production image is built from a project that's been set up in dev"
# Docker mounts only absolute paths.
config="$(cd "$root/app/etc" && pwd)/config.php"

# PHP's own errors go to stdout, so a failure's message is in $missing; Docker's go to
# stderr, above it.
# shellcheck disable=SC2016 # the $ belongs to PHP
if ! missing=$(docker run --rm --entrypoint php -v "$config:/tmp/config.php:ro" \
    "sental90/mageos-frankenphp-docker:$php-runtime" -r '
        $config = include "/tmp/config.php";
        echo implode(" ", array_filter(["scopes", "themes", "i18n"], fn ($s) => !array_key_exists($s, $config)));
    '); then
    fail "couldn't read $config: $missing"
fi

[ -z "$missing" ] || fail "app/etc/config.php is missing these sections: $missing. A build has no database, so static content deploy reads the stores and themes from there. In dev, run bin/magento app:config:dump scopes themes i18n, then commit app/etc/config.php. Stores are then managed in code: see deploy/README.md, The app image."

printf 'prod-build-check: %s has scopes, themes and i18n\n' "$config" >&2
