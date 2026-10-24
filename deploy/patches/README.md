# Patches the template ships

`deploy/setup dev` copies these into a new project's `patches/composer/` and registers them under
`extra.patches` in its composer.json (cweagans/composer-patches).

## `opengento_bootstrappool_root_area.diff` (opengento/module-application 0.11.2)

**The bug:** `BootstrapPool::resolveAreaCode()` resolves the area from the first path segment with
`strtok()`. For `/` that returns `false`, not a string. `AreaList::getCodeByFrontName()` compares
strictly, and the admin area's front name is also `false` whenever the request's host isn't the admin
host. That's always true for internal requests, such as the Varnish probe. So `/` resolved to adminhtml,
and the homepage answered 500, which Varnish served as a 503 (2026-07-13).

**The fix:** cast to `(string)`. `/` then resolves to the frontend.

**Why a patch, not a plugin:** `BootstrapPool` is constructed with `new` in `pub/worker.php`, not through
DI, and its methods are private. `mage-os/module-worker-mode` pins `opengento/module-application` to
exactly 0.11.2, so no upstream fix can arrive until both packages move. Remove the patch once an
opengento release carries the cast.
