#!/usr/bin/env bash
# =============================================================================
# Runs inside the dev app container (as www-data, in /app) to create a curated
# Mage-OS project. deploy/setup pipes this in: bash -s -- <step> [args]
#
#   create <version>  composer create-project of mage-os/project-community-edition.
#                     /app must be empty.
#   check             exits 0 if composer.json requires opengento/magento2-frankenphp-base
#                     (worker mode), 3 if it doesn't. Any other exit is an error, never
#                     a "no".
#   guard             refuses, before anything changes, a project whose own patches
#                     curate would break. Run it before copying the patch and curating.
#   curate            adds what FrankenPHP worker mode needs:
#                       - cweagans/composer-patches, with the opengento root-area patch
#                         (setup has already copied it to patches/composer/)
#                       - opengento/magento2-frankenphp-base: worker entry points in pub/
#                       - opengento/module-application 0.11.2: the worker runtime
#                       - mage-os/module-worker-mode: Magento's worker-mode fixes
#                     plus laravel/prompts, which `bin/magento install` needs, if the
#                     project doesn't already have it.
#   hyva              requires Hyvä (hyva-themes/magento2-default-theme) and
#                     mage-os/module-worker-mode-hyva, with HYVA_PROJECT_KEY and
#                     HYVA_API_TOKEN from the environment. setup runs it before the
#                     installer, so the installer's own require is a no-op.
#   sample-data       deploys Magento's sample data (sampledata:deploy). setup runs it
#                     before the installer, so setup:install installs it and the
#                     installer's own deploy finds nothing left to add.
#
# Composer runs here, never on the host.
# =============================================================================
set -euo pipefail
cd /app

step=${1:-}
case "$step" in
    create)
        version=${2:?create needs a Mage-OS version}
        composer create-project --no-interaction --repository-url=https://repo.mage-os.org/ \
            "mage-os/project-community-edition=$version" .
        ;;

    check)
        # shellcheck disable=SC2016 # PHP code: its $variables must reach PHP unexpanded
        php -r '
            $json = json_decode(file_get_contents("composer.json"), true, 512, JSON_THROW_ON_ERROR);
            exit(isset($json["require"]["opengento/magento2-frankenphp-base"]) ? 0 : 3);
        '
        ;;

    guard)
        # composer-patches 1.x reads a root extra.patches and then never reads
        # extra.patches-file, so adding our patch would silently stop every patch in that
        # file applying. And `composer require cweagans/composer-patches:^1.7` would
        # downgrade a project on 2.x, which reads patches differently. Only a plain 1.x
        # constraint (^1, ~1, 1.*, 1.7.3) passes; anything wider is refused, not guessed.
        # shellcheck disable=SC2016 # PHP code: its $variables must reach PHP unexpanded
        php -r '
            $json = json_decode(file_get_contents("composer.json"), true, 512, JSON_THROW_ON_ERROR);
            $problems = [];
            if (isset($json["extra"]["patches-file"])) {
                $problems[] = "extra.patches-file is set. composer-patches 1.x never reads that file once"
                    . " extra.patches exists, so every patch in it would stop applying.";
            }
            foreach (["require", "require-dev"] as $section) {
                $constraint = $json[$section]["cweagans/composer-patches"] ?? null;
                if ($constraint === null) {
                    continue;
                }
                foreach (preg_split("/\s*\|\|?\s*/", trim($constraint)) as $part) {
                    if (!preg_match("/^[\^~]?1(\.[0-9]+|\.\*)*$/", $part)) {
                        $problems[] = "$section has cweagans/composer-patches \"$constraint\". That is not a plain"
                            . " 1.x constraint, so setup cannot tell whether requiring ^1.7 would downgrade it from 2.x.";
                        break;
                    }
                }
            }
            if ($problems === []) {
                exit(0);
            }
            $lines = ["guard: adding worker mode automatically would break the patches of this project:"];
            foreach ($problems as $problem) {
                $lines[] = "  - $problem";
            }
            array_push($lines,
                "guard: nothing has changed. To add worker mode by hand, in this order:",
                "  1. add \"replace\": {\"magento/magento2-base\": \"*\"} to composer.json",
                "     (the opengento base package requires it, and mage-os/magento2-base does not replace it)",
                "  2. register deploy/patches/opengento_bootstrappool_root_area.diff against",
                "     opengento/module-application, wherever your patches are declared",
                "  3. bin/composer config allow-plugins.opengento/magento2-frankenphp-plugin true",
                "  4. bin/composer require opengento/magento2-frankenphp-base:^0.9.4 opengento/module-application:0.11.2 mage-os/module-worker-mode:^1.0",
                "then re-run setup.");
            fwrite(STDERR, implode("\n", $lines) . "\n");
            exit(1);
        '
        ;;

    curate)
        patch=patches/composer/opengento_bootstrappool_root_area.diff
        [ -f "$patch" ] || { echo "curate: $patch is missing; setup copies it before this step" >&2; exit 1; }

        composer config --no-interaction allow-plugins.cweagans/composer-patches true
        composer config --no-interaction allow-plugins.opengento/magento2-frankenphp-plugin true

        # Register the patch, and fail the install if any patch stops applying, rather
        # than shipping unpatched code.
        #
        # opengento/magento2-frankenphp-base requires magento/magento2-base. Every other
        # Mage-OS package replaces its magento/* name, but mage-os/magento2-base doesn't,
        # so without the root replace Composer can't resolve the package at all.
        # shellcheck disable=SC2016 # PHP code: its $variables must reach PHP unexpanded
        php -r '
            $file = "composer.json";
            $json = json_decode(file_get_contents($file), true, 512, JSON_THROW_ON_ERROR);
            $json["replace"]["magento/magento2-base"] = "*";
            $json["extra"]["composer-exit-on-patch-failure"] = true;
            $json["extra"]["patches"]["opengento/module-application"]
                ["Root path / resolves to the frontend, not adminhtml (deploy/patches/README.md)"]
                = "patches/composer/opengento_bootstrappool_root_area.diff";
            file_put_contents($file, json_encode($json, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
        '

        composer require --no-interaction \
            "cweagans/composer-patches:^1.7" \
            "opengento/magento2-frankenphp-base:^0.9.4" \
            "opengento/module-application:0.11.2" \
            "mage-os/module-worker-mode:^1.0"

        if [ ! -d vendor/laravel/prompts ]; then
            composer require --no-interaction --dev "laravel/prompts:*"
        fi
        ;;

    hyva)
        : "${HYVA_PROJECT_KEY:?hyva: HYVA_PROJECT_KEY is empty (a free key from the hyva.io dashboard)}"
        : "${HYVA_API_TOKEN:?hyva: HYVA_API_TOKEN is empty (a free key from the hyva.io dashboard)}"

        # The credentials reach auth.json from the environment through PHP, never as
        # command-line arguments. Other entries in auth.json are kept, and the file is
        # 0600 because it holds a token. The repository uses the installer's own name
        # and URL, so when its theme step runs it finds both and adds nothing.
        # shellcheck disable=SC2016 # PHP code: its $variables must reach PHP unexpanded
        php -r '
            $file = "auth.json";
            $auth = is_file($file) ? json_decode(file_get_contents($file), true, 512, JSON_THROW_ON_ERROR) : [];
            $auth["http-basic"]["hyva-themes.repo.packagist.com"] = [
                "username" => getenv("HYVA_PROJECT_KEY"),
                "password" => getenv("HYVA_API_TOKEN"),
            ];
            umask(0077);
            file_put_contents($file, json_encode($auth, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
            chmod($file, 0600);
        '
        composer config --no-interaction repositories.private-packagist composer \
            "https://hyva-themes.repo.packagist.com/${HYVA_PROJECT_KEY}/"
        composer require --no-interaction hyva-themes/magento2-default-theme "mage-os/module-worker-mode-hyva:^1.0"
        ;;

    sample-data)
        # Magento's own deploy, which works before an install (it registers through
        # cli_commands.php): it requires the sample-data package of every installed
        # module that suggests one. It exits non-zero if Composer fails (composer.json is
        # reverted) and if no module suggests sample data. Run again, the require changes
        # nothing.
        php bin/magento sampledata:deploy --no-interaction
        ;;

    *)
        echo "new-project.container.sh: unknown step '$step' (create, check, guard, curate, hyva or sample-data)" >&2
        exit 2
        ;;
esac
