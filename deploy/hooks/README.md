# Hooks: project-specific steps

The template is generic. Anything only one project needs goes in a hook, never in the
Dockerfile or `bin/release`. A hook is a bash script with a fixed name in this
directory. If the file exists it runs; if it doesn't, nothing happens.

| File | When it runs | Where | Working directory | Inputs |
| --- | --- | --- | --- | --- |
| `pre-composer.sh` | Image build, before `composer install` | The `build` stage | `/build` (the Magento root being built) | `HOOK_ENV` |
| `post-composer.sh` | Image build, after `composer install` | The `build` stage | `/build` | `HOOK_ENV` |
| `post-release.sh` | After `bin/release` has switched colours (Phase 4) | The server host | The project root | `STACK_ROOT`, `SCHEMA_UPGRADED` (`1` or `0`) |

## Inputs

`HOOK_ENV` is one build argument holding space-separated `KEY=VALUE` pairs. The build
runs each build hook as `env $HOOK_ENV bash <hook>`, so every pair is an environment
variable inside it. For example, CI passes the storefront gitlink's commit as
`HOOK_ENV="CS_REF=<sha>"`. Locally, `bin/build` reads `HOOK_ENV` from `.env`. Values
may not contain spaces.

`post-release.sh` runs on the host, and can use the stack's own wrappers
(`"$STACK_ROOT/bin/magento" …`).

## Rules

- **Fail loudly.** Start with `set -euo pipefail`. A hook that fails stops the build or
  the release, and that's what should happen. Never `|| true` a step that matters.
- **Idempotent.** A build hook runs on every uncached build, and a release hook on every
  release.
- **No secrets in `HOOK_ENV`.** Build arguments are visible in the image history. Pass
  credentials as BuildKit secrets, the way `composer_auth` is passed.

## Examples

`examples/` holds completely.frankenphp's hooks. They're the first real user of this
contract, and nothing runs from that directory. A project that needs one copies it here
under the name in the table:

- `pre-composer.completely.sh` clones the commerce-data-export fork into
  `packages/commerce-data-export`, and fetches the storefront gitlink's commit (`CS_REF`)
  into its path repository. Both are path repositories that a `COPY` of composer.json and
  composer.lock alone can't install from.
- `post-release.completely.sh` queues variant-slug regeneration, and starts a background
  reindex when the release changed the schema.
