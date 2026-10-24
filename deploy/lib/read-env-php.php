<?php
/**
 * Reads an existing env.php and prints the values the stack keeps in .env, one per line:
 * "KEY<TAB>base64(value)". The base64 keeps any character safe through the shell.
 *
 * deploy/setup uses it twice:
 *  - --from-env-php: to take over an existing store's immutable values (crypt key,
 *    install date, GraphQL salt, cache prefix, admin path, cache state)
 *  - after `bin/magento install`: to capture the values the installer generated
 *
 * It runs inside the app image: php /tmp/read-env-php.php /path/to/env.php
 */
declare(strict_types=1);

$file = $argv[1] ?? '';
if (!is_file($file)) {
    fwrite(STDERR, "read-env-php: no env.php at '$file'\n");
    exit(2);
}
$env = include $file;
if (!is_array($env)) {
    fwrite(STDERR, "read-env-php: $file doesn't return an array\n");
    exit(2);
}

$core = require '/usr/local/lib/stack/core-cache-types.php';
$cacheTypes = is_array($env['cache_types'] ?? null) ? $env['cache_types'] : [];

// Magento separates multiple crypt keys (after a key rotation) with newlines. .env
// holds one line, so they're joined with spaces. Magento and the generator both split
// on any whitespace.
$keys = preg_split('/\s+/', trim((string)($env['crypt']['key'] ?? ''))) ?: [];

$values = [
    'CRYPT_KEY' => implode(' ', array_filter($keys, 'strlen')),
    'INSTALL_DATE' => (string)($env['install']['date'] ?? ''),
    'GRAPHQL_ID_SALT' => (string)($env['cache']['graphql']['id_salt'] ?? ''),
    'CACHE_ID_PREFIX' => (string)($env['cache']['frontend']['default']['id_prefix'] ?? ''),
    'ADMIN_FRONT_NAME' => (string)($env['backend']['frontName'] ?? ''),
    'MAGENTO_CACHE_TYPES_EXTRA' => implode(',', array_values(array_diff(array_keys($cacheTypes), $core))),
    'MAGENTO_CACHE_DISABLED' => implode(',', array_keys(array_filter($cacheTypes, static fn($on): bool => !$on))),
];

foreach ($values as $key => $value) {
    printf("%s\t%s\n", $key, base64_encode($value));
}
