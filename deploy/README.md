# deploy/: the stack

Everything the stack is made of lives here. The project root holds only what setup generates from it.
For a first run, start with the [main README](../README.md).

## What's in here

| Path | |
| --- | --- |
| `setup` | the one entry point: `deploy/setup dev` and `deploy/setup server` |
| `bin/` | the day-to-day commands; setup links the project root's `bin` here |
| `lib/` | setup's own code, plus the few scripts it runs inside the app image |
| `templates/` | compose, Caddy, Varnish and OpenSearch files, rendered with values from `.env` |
| `config/` | files used as they are: PHP, FrankenPHP, MariaDB, OpenSearch and the log tailer |
| `Dockerfile` | the app image, with `dev`, `build` and `prod` targets (see [The app image](#the-app-image)) |
| `.env.example` | every setting, documented; setup creates `.env` from it |
| `hooks/` | project-specific build and release steps ([README](hooks/README.md)) |
| `patches/` | patches setup adds to a new project ([README](patches/README.md)) |
| `secrets/` | encrypted copies of servers' `.env` files ([README](secrets/README.md)) |

## The app image

The Dockerfile installs nothing. It builds on published images from
[`sental90/mageos-frankenphp-docker`](https://github.com/Sental/mageos-frankenphp-docker): `runtime`
(FrankenPHP, the PHP extensions, supervisor, logrotate) and `build` (`runtime` plus git, Node, Composer, and
Xdebug installed but not enabled). It adds only the stack's config, and so an edit to a file in `config/`
rebuilds in seconds.

| Target | Built on | |
| --- | --- | --- |
| `dev` | `<php>-build`, the moving tag | the stack's config, Xdebug loaded (`config/app/xdebug.ini`) and idle, `www-data` as your UID |
| `build` | `<php>-build-<datetime>` | `composer install`, theme builds, `di:compile`, static content deploy |
| `prod` | `<php>-runtime-<datetime>` | the stack's config plus `build`'s output: what servers run |

- **`PHP_VERSION` in `.env` (8.3, 8.4 or 8.5) picks the images.** Switching needs no Dockerfile edit: change
  it, then run `bin/build`.
- **Dev follows the moving tag.** setup and `bin/build` pull the newest image first. Each dev build is
  tagged `<project>-app:dev-<UTC datetime>`, recorded as `DEV_IMAGE_TAG` in `.env`, and the older dev tags
  are removed, except the one just replaced, which stays for a rollback.
- **`build` and `prod` use dated tags, one pair of lines per PHP version** at the top of the Dockerfile.
  Staging and production move to a newer image only when those lines are bumped, and staging builds on it
  before production does.
- **A prod image is built from a project that's been set up in dev,** not from a new one. A build has no
  database, so static content deploy reads the stores and themes from `app/etc/config.php`. Put them there
  once, in dev, and commit the file:

  ```bash
  bin/magento app:config:dump scopes themes i18n
  ```

  `bin/build <tag>` checks for the three sections first, and stops with this command if one is missing;
  without them, static content deploy fails minutes in with "The default website isn't defined".
- **Once `scopes` is dumped, stores are managed in code.** `app:config:import` (which `setup:upgrade` runs)
  makes the database match `config.php`, and deletes any website, store or store view that isn't in it. It
  runs whenever the `scopes` section has changed. So after creating a store in the admin, run the dump
  again and commit it, or the next deploy that changes `scopes` removes the store.

## What setup generates in the project root

All of these are in the root `.gitignore`. Never commit them.

| Path | |
| --- | --- |
| `.env` | every value the stack runs on, including passwords and Magento's crypt key. Mode 0600. |
| `compose.yaml`, plus `compose.dev.yaml` or `compose.server.yaml` | rendered from `templates/`, so don't edit them |
| `.stack/caddy/`, `.stack/varnish/` | the rendered Caddyfile and VCL |
| `.stack/opensearch/` | certificates, the CA's private key (never mounted anywhere), password hashes and the security files |
| `.stack/new-project`, `.stack/install/` | setup's record of a new project or an install that hasn't finished (see [When something fails](#when-something-fails)) |
| `bin` | a link to `deploy/bin` |

`bin/render` regenerates the rendered files from `.env` and the templates. `bin/start` runs it for you.

## Names

Every service, container and hostname is `<project>-<service>`, where `<project>` is `PROJECT_NAME` from
`.env`. Commands take the short name: `bin/log mariadb`, `bin/restart app cron`.

| Short name | |
| --- | --- |
| `app` | the FrankenPHP app. On a server, it means the active colour, `app-blue` or `app-green`. |
| `cron`, `consumers` | Magento's cron and queue consumers, in the app image |
| `caddy`, `varnish` | the edge and the full-page cache |
| `mariadb`, `valkey-session`, `valkey-cache`, `rabbitmq`, `opensearch` | the data services |
| `log-tailer`, `dozzle`, `mailpit`, `phpmyadmin`, `opensearch-dashboards` | dev only |

`PROJECT_NAME` is lowercase letters and digits with single hyphens between them, at most 41 characters,
so that the longest name still fits in a hostname. There are no underscores anywhere, because a
hostname can't contain one. OpenSearch's TLS rejects a server name with an underscore, which fails every
connection.

## setup

`deploy/setup dev` sets up a dev machine, and `deploy/setup server --env staging|production` sets up a
server. `--help` on either lists every option. setup is safe to run again: every step checks before it
acts, and `.env` values are filled in but never overwritten, except the ones you pass.

On a dev machine, what setup does depends on what it finds:

| It finds | It does |
| --- | --- |
| no Magento in `MAGENTO_ROOT` (default `src/`) | creates a Mage-OS project ready for worker mode, then runs the installer |
| a project and an empty database | runs the installer |
| `--import FILE --from-env-php FILE` | loads the dump, keeping the store's crypt key and the other fixed values from its `env.php` |
| an installed store (`CRYPT_KEY` and `INSTALL_DATE` in `.env`) | starts it |

## Commands

| Command | |
| --- | --- |
| `bin/start [service…]` | render, start (or recreate, so `.env` changes apply), then reload Caddy |
| `bin/stop [-v]` | stop and remove the containers. `-v` also deletes the volumes, after you type the project name. |
| `bin/restart [service…]` | restart in place, keeping the container's config. In worker mode, PHP changes need `bin/restart app`. |
| `bin/status` | containers, state and health |
| `bin/log [service…]` | follow logs (default: the app). `TAIL=n` sets how many earlier lines to show first. |
| `bin/render` | regenerate the rendered files from `.env` and the templates |
| `bin/magento …` | bin/magento as www-data. It warns before changes that won't survive a restart. |
| `bin/composer …`, `bin/npm …` | dev only. `bin/npm` runs in the first `THEME_PATHS` entry, or in `NPM_DIR`. |
| `bin/n98 …` | n98-magerun2 |
| `bin/bash`, `bin/root` | a shell in the app container as www-data, or as root. Run PHP from `bin/bash`. |
| `bin/peek [--tail n] [--grep re] [--ls] path` | read a file inside the app container |
| `bin/mysql`, `bin/mysqldump` | the MariaDB client and dump tool, as the Magento user |
| `bin/cache-flush` | flush Magento's caches and ban everything in Varnish |
| `bin/deploy` | dev: setup:upgrade, di:compile, theme builds, static content for `LOCALES`, cache flush, PHP restart |
| `bin/phpunit …` | PHPUnit, from `dev/tests/unit` |
| `bin/consumers list\|status\|restart` | which consumers exist and which `MAGENTO_CONSUMERS` runs, Supervisor's view, a restart |
| `bin/xdebug on [mode]\|off\|status` | dev: Xdebug, triggered per request |
| `bin/varnish on\|off\|status` | dev: send the store through Varnish, or straight to the app |
| `bin/watch on\|off\|status` | dev: restart the workers whenever code changes |
| `bin/trust` | WSL: Windows hosts entries and trust for Caddy's local CA, behind one UAC prompt |
| `bin/opensearch-security` | apply the rendered OpenSearch users, roles and mappings to the running cluster |
| `bin/secrets init\|encrypt\|decrypt …` | encrypted copies of servers' `.env` ([README](secrets/README.md)) |
| `bin/build [tag]` | rebuild the dev image, or build a prod image the way CI does |

## Configuration: .env and env.php

- **`.env` is the only place to change anything.** `env.php` is regenerated from it every time a PHP
  container starts. So an edit to `env.php` lasts until the next restart, and so do
  `bin/magento cache:enable/disable` and `config:set --lock-env`.
- **After changing `.env`,** run `bin/start <service>`, which recreates the container with the new
  values. `bin/restart` keeps the old ones.
- **Rendered files** (the Caddyfile, the VCL, the compose files) change only through `bin/render`, and
  `bin/start` renders. Caddy never notices a new Caddyfile by itself, so `bin/start` also reloads it.
- **Worker threads and memory.** `FRANKENPHP_WEB_WORKERS`, `FRANKENPHP_STATIC_WORKERS` and
  `FRANKENPHP_MEDIA_WORKERS` set how many PHP threads each FrankenPHP worker runs. setup writes 4/4/2 in
  dev and 8/4/2 on servers. Every thread boots its own Magento, so these set both the first-start time and
  the app's memory.
  - **On servers,** `APP_MEM_LIMIT` (for each app colour), `CRON_MEM_LIMIT` and `CONSUMERS_MEM_LIMIT` cap
    the containers. `setup server` warns when the caps add up to more than the host's RAM during a release.
  - `.env.example` has the sizing rule.

## Dev URLs

| URL | |
| --- | --- |
| `https://<domain>/` | the store, through Varnish (`bin/varnish off` bypasses it) |
| `https://logs.<domain>/` | Dozzle: every container's log, including the Magento log files |
| `https://mail.<domain>/` | Mailpit: all outgoing mail lands here, whatever the database says |
| `https://pma.<domain>/` | phpMyAdmin |
| `https://mq.<domain>/` | RabbitMQ management (`RABBITMQ_USER` and `RABBITMQ_PASSWORD`) |
| `https://search.<domain>/` | OpenSearch Dashboards (`admin` and `OPENSEARCH_ADMIN_PASSWORD`) |

Caddy listens on 127.0.0.1 only. Dashboards runs only while `DEV_PROFILES` includes `search-ui`, which is
the default. Set `DEV_PROFILES=none` to save its memory. `search.` then explains that it's off and how to
turn it on.

## OpenSearch security

Security and TLS are on, even in dev. setup generates a private CA and the node and admin certificates
in `.stack/opensearch/`, and three users:

- `admin`, the administrator
- `kibanaserver`, for Dashboards
- `magento`, which can do everything on indices under `OPENSEARCH_INDEX_PREFIX`, plus read alias names
  everywhere

OpenSearch reads its users and roles itself only when it first creates its security index. After that,
`bin/opensearch-security` applies them, and setup runs it on every run. **The files win:** a change made
through Dashboards or the security REST API is reverted on the next setup run.

- **To change a password:** set it in `.env`, delete `.stack/opensearch/hashes.env`, then re-run setup.
- **To change a role:** edit `templates/opensearch/roles.yml.tpl`, then run `bin/opensearch-security`.
- **If the project name changes,** setup issues a new node certificate for `<project>-opensearch` from the
  same CA.

## When something fails

- **A new project stopped partway:** re-run setup.
  - If it stopped while adding worker mode, it offers to repair the project or create it again.
  - If create-project itself didn't finish, it offers only to create it again.
  - Without a terminal, `--repair` or `--recreate` gives the answer.
  - setup never offers to delete a project it didn't create.
- **The installer failed:** setup asks whether to clean up. That removes the `env.php` the failed install
  wrote (and restores the previous one), drops and recreates the database it filled, and turns
  maintenance mode off. If you say no, or setup never got to ask, the next run asks first. Without a
  terminal, `--repair` answers yes.
- **An installer step timed out** ("exceeded the timeout of 30 seconds"): the installer gives its
  post-install steps fixed time limits, and a timeout stops the whole install, even though
  `setup:install` has finished. `var/log/stack-install-timing.log`, in the Magento root, has one
  section per installer run. It shows when each step started and ended. For each step it also logs, every
  2 s, whether the step was on a CPU (state `R`), waiting on the disk (`D`) or waiting on something else
  (`S`), its CPU time and I/O, and the machine's load and pressure. If the installer ran as a user other
  than www-data or root, the log and the terminal say so.
- **`search.` shows a 503:** Dashboards is off (`DEV_PROFILES`).
- **`search.` shows a 502 with a message:** it's on but not answering yet. Try `bin/status` and
  `bin/log opensearch-dashboards`.
- **OpenSearch won't start:** check `vm.max_map_count`. setup prints how to set it.
- **A reindex fails with a 403 from OpenSearch:** its log names the missing permission. Add it to the
  `magento` role, then run `bin/opensearch-security`.
- **The admin password is lost** (setup stopped after the install, or it scrolled away): use "Forgot your
  password?" on the admin login. The reset link goes to `ADMIN_EMAIL`, and in dev it lands in Mailpit.
- **Ports 80 and 443 are taken:** pass `--http-port` and `--https-port` to setup.
- **A container runs but can't reach the others after a failed start** (for example, `search.` gives a 502
  while Dashboards is up): a failed start can drop a container's networks (moby/moby#51758). Before
  every `up`, the commands here remove a container that was created but never started, so it's created
  again. One that had run before needs `bin/start <service> --force-recreate`.
