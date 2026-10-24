# Hooks: project-specific steps

The template is generic. Anything only one project needs goes in a hook, never in the
Dockerfile or `bin/release`. A hook is a bash script with a fixed name in this
directory. If the file exists it runs; if it doesn't, nothing happens.

| File | When it runs | Where | Working directory | Inputs |
| --- | --- | --- | --- | --- |
| `pre-composer.sh` | Image build, before `composer install` | The `build` stage | `/build` (the Magento root being built) | `HOOK_ENV` |
| `post-composer.sh` | Image build, after `composer install` | The `build` stage | `/build` | `HOOK_ENV` |
| `post-release.sh` | After `bin/release` has switched colours (`bin/release` is still being built) | The server host | The project root | `STACK_ROOT`, `SCHEMA_UPGRADED` (`1` or `0`) |

## Inputs

`HOOK_ENV` is one build argument holding space-separated `KEY=VALUE` pairs. The build
runs each build hook as `env $HOOK_ENV bash <hook>`, so every pair is an environment
variable inside it. For example, `HOOK_ENV="MODULE_REF=abc1234 BUILD_ID=42"` gives
the hook `$MODULE_REF` and `$BUILD_ID`. CI passes it as a build argument; locally,
`bin/build` reads `HOOK_ENV` from `.env`. Values may not contain spaces.

`post-release.sh` runs on the host, and can use the stack's own wrappers
(`"$STACK_ROOT/bin/magento" …`).

## Rules

- **Fail loudly.** Start with `set -euo pipefail`. A hook that fails stops the build or
  the release, and that's what should happen. Never `|| true` a step that matters.
- **Idempotent.** A build hook runs on every uncached build, and a release hook on every
  release.
- **No secrets in `HOOK_ENV`.** Build arguments are visible in the image history. Pass
  credentials as BuildKit secrets, the way `composer_auth` is passed.

## Writing one

A hook is an ordinary bash script, saved here under the name from the table. The usual
reason for a build hook is a package that composer.json installs from a path repository.
A `COPY` of composer.json and composer.lock alone can't provide its files, so
`pre-composer.sh` has to put them in place first.

```bash
#!/usr/bin/env bash
# deploy/hooks/pre-composer.sh
set -euo pipefail
: "${MODULE_REF:?HOOK_ENV must set MODULE_REF}"   # fail loudly if the build didn't pass it

# Runs in /build, the Magento root being built, before composer install.
# ... put packages/my-module in place at $MODULE_REF ...
```

A release hook gets the stack's root, and whether the release changed the schema:

```bash
#!/usr/bin/env bash
# deploy/hooks/post-release.sh
set -euo pipefail
if [ "$SCHEMA_UPGRADED" = "1" ]; then
    "$STACK_ROOT/bin/magento" indexer:reindex
fi
```
