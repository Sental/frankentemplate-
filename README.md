# frankentemplate

A Docker stack that runs Mage-OS (or Magento Open Source) on FrankenPHP in worker mode, from a dev
machine to blue/green production servers. One command sets it up: `deploy/setup`.

> **Status: pre-release.** The dev path is tested on WSL2 with a new Mage-OS 3.6 project. `--hyva`,
> `--sample-data` and server mode are still being tested, and CI and blue/green releases are still being
> built.

## What you get

```text
browser ─▶ Caddy (TLS) ─▶ Varnish 8 ─▶ FrankenPHP app (PHP 8.5, worker mode)
                                        cron · consumers   (same image, their own containers)
                                        MariaDB 12 · Valkey 9 (sessions) · Valkey 9 (cache)
                                        RabbitMQ 4.3 · OpenSearch 3 (security and TLS on)
```

- **Dev:** Caddy's own local CA, so the store runs on real HTTPS at `https://<project>.test`. You also
  get Mailpit (all mail is caught), Dozzle (container and Magento logs), phpMyAdmin, RabbitMQ
  management, OpenSearch Dashboards, and toggles for Xdebug, the Varnish bypass and worker reloading.
- **Servers:** Let's Encrypt, two app colours for blue/green releases, and every secret in one `.env`,
  with an encrypted copy you can commit.
- **`env.php`** is generated from `.env` every time a PHP container starts, so configuration lives in one
  place.

## Requirements

- Linux, or Windows with WSL2.
- Docker Engine with the compose plugin, version 2.24.0 or newer, and buildx. `deploy/setup` checks
  them and says what's missing. On a server, `deploy/setup server` installs them.
- `vm.max_map_count` of at least 262144, which OpenSearch needs. setup checks it and tells you how to
  set it.
- Memory: OpenSearch's heap and MariaDB's buffer pool default to 1 GB each. On a smaller machine, add
  `--set OPENSEARCH_HEAP=512m --set MARIADB_BUFFER_POOL=512M` to the setup command.

## Quick start: a new store

```bash
git clone <this repository> myshop
cd myshop
deploy/setup dev --project myshop
```

That does four things:

1. **Creates the project.** A Mage-OS 3.6.0 project goes in `src/`, ready for worker mode: the opengento
   FrankenPHP packages, `mage-os/module-worker-mode` and one patch, described in
   [deploy/patches](deploy/patches/README.md).
2. **Hands over to Mage-OS's installer** (`bin/magento install`), with the stack's database, search,
   queue and cache already filled in. setup prints which answers to give first. If the install fails,
   setup offers to clean up so that a re-run starts again cleanly.
3. **Starts everything.** Then it prints the URLs and the admin password. The password is shown once and
   not stored anywhere.
4. **On WSL, runs `bin/trust`.** One UAC prompt adds the hosts entries to Windows and makes Windows trust
   Caddy's local CA.

Useful options (all of them: `deploy/setup dev --help`):

| Option | |
| --- | --- |
| `--domain shop.test` | the dev domain; the default is `<project>.test` |
| `--http-port 8080 --https-port 8443` | when 80 and 443 are taken |
| `--hyva` | install Hyvä, then `mage-os/module-worker-mode-hyva`. It needs a free key from hyva.io. |
| `--sample-data` | install Magento's sample data |
| `--mageos-version 3.6.0` | the Mage-OS version to create |
| `--set KEY=VALUE` | any `.env` value; repeatable |

The project name becomes part of every container name and hostname (`myshop-app`, `myshop-mariadb`, …).
So it's lowercase letters and digits, with single hyphens between them. No underscores, because they
aren't valid in a hostname.

## An existing store

Put its code in `src/`, or point `--magento-root` at it, then:

- **With an empty database,** setup hands over to the installer, as for a new store.
- **To load a dump,** use `deploy/setup dev --import dump.sql.gz --from-env-php path/to/env.php`. The
  store's own `env.php` provides its crypt key, install date and the other values that must never change.
  Without the crypt key, every encrypted value in the dump would be unreadable.

This stack runs Magento in worker mode only. If the project doesn't have it yet, setup offers to add
it, and lists every change it would make to `composer.json` first.

## Where your Magento code lives

Both of these work. Choose one per shop:

- **One repository per shop:** commit `src/` in this repository, for example from GitHub's "Use this
  template". For a new project, setup writes `src/.gitignore`, which keeps dependencies, generated code,
  runtime state and secrets out of git.
- **A separate Magento repository:** clone it into `src/` and add `/src/` to this repository's
  `.gitignore`.

Either way, the root `.gitignore` already keeps out what setup generates: `.env` (which holds secrets),
the rendered compose files, `.stack/` and the `bin` link.

## Day to day

Run these from the project root:

| Command | |
| --- | --- |
| `bin/start`, `bin/stop`, `bin/status` | start (and apply `.env` changes), stop, and see the state |
| `bin/magento …`, `bin/composer …` | in the app container, as the user PHP runs as |
| `bin/log [service]` | follow a container's log; `bin/log log-tailer` follows every Magento log |
| `bin/deploy` | the post-change sequence: setup:upgrade, di:compile, theme build, static content, cache, restart |
| `bin/xdebug on`, `bin/varnish off`, `bin/watch on` | the dev toggles |

Every command is in [deploy/README.md](deploy/README.md).

**Configuration lives in `.env`.** setup creates it, and every key is documented in
[deploy/.env.example](deploy/.env.example). `env.php` is regenerated from `.env` on every start, so
editing `env.php` doesn't last. The same goes for `bin/magento cache:enable` and
`config:set --lock-env`, and `bin/magento` warns about both. Change `.env`, then run `bin/start`.

## Servers

`deploy/setup server --env staging|production` prepares an Ubuntu or Debian server. It checks for
Docker, the kernel settings, a deploy user and the firewall, and installs only what's missing. Then it
sets up the stack from an existing store: `--image` and `--import` are needed the first time. See
`deploy/setup server --help`. Releases (`bin/release`) and the CI workflow are still being built.

## License

MIT. See [LICENSE](LICENSE).
