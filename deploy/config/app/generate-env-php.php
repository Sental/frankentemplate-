<?php
/**
 * Writes app/etc/env.php from the container's environment.
 *
 * Why a generator: the stack treats env.php as derived state. Every container start
 * rewrites it from .env, so an environment's configuration is exactly its .env, never
 * whatever a CLI command wrote into env.php months ago. In production that
 * immutability is the point (FINDINGS F-12). It has three consequences:
 *
 *  - var_export() does the quoting, so a secret may contain any character (F-11).
 *  - The file is replaced by an atomic rename, so the app, cron and consumers
 *    containers can start together without one of them reading half a file.
 *  - `bin/magento cache:enable` and `config:set --lock-env` only last until the next
 *    container start. Cache state and locked config belong in .env.
 *
 * Usage:
 *   php generate-env-php.php --write   write /app/app/etc/env.php
 *   php generate-env-php.php --diff    list what --write would change, secrets masked
 *
 * Inputs are environment variables. The compose templates set the service hosts;
 * .env sets the rest. A missing required value is a hard error naming the variable,
 * never a silent default.
 */
declare(strict_types=1);

const ENV_PHP = '/app/app/etc/env.php';

/**
 * Magento core cache types. They're always written, because Magento treats a type
 * missing from env.php as disabled. A module's own types (elasticsuite,
 * compiled_plugins, ...) come from MAGENTO_CACHE_TYPES_EXTRA. deploy/setup reads the
 * same file, so the list exists only once.
 */
define('CORE_CACHE_TYPES', require __DIR__ . '/core-cache-types.php');

/** Keys whose values --diff masks, so diff output is safe to paste. */
const SECRET_KEYS = ['password', 'key', 'http_auth_pwd', 'opensearch_password', 'id_salt'];

/**
 * Reads an optional environment variable. Unset and empty both count as absent,
 * because Compose passes an unset .env value through as an empty string.
 */
function env(string $name, string $default = ''): string
{
    $value = getenv($name);
    return ($value === false || $value === '') ? $default : $value;
}

/** Reads a required environment variable, or stops with a message naming it. */
function required(string $name): string
{
    $value = env($name);
    if ($value === '') {
        throw new RuntimeException("$name is required but empty: set it in .env (see deploy/.env.example)");
    }
    return $value;
}

/** Splits a comma- or whitespace-separated list, dropping empty entries. */
function listOf(string $value): array
{
    return array_values(array_filter(array_map('trim', preg_split('/[\s,]+/', $value) ?: []), 'strlen'));
}

/**
 * Encrypts a value exactly as Magento's Encryptor does, so system config marked
 * `Encrypted` (system/smtp/password) can be held in env.php.
 *
 * Mirrors Magento\Framework\Encryption\Encryptor::encrypt() and
 * Adapter\SodiumChachaIetf::encrypt() in Mage-OS 3.6:
 *  - the crypt key splits on whitespace; the last key is the current one, and its
 *    index is the key version
 *  - a key starting with "base64" is base64-decoded first
 *  - ChaCha20-Poly1305 IETF with a random nonce, which also serves as the
 *    additional data
 *  - result: "<keyVersion>:3:" . base64(nonce . ciphertext)
 */
function encryptForMagento(string $plain, string $cryptKey): string
{
    [$version, $key] = currentKey($cryptKey);
    $nonce = random_bytes(SODIUM_CRYPTO_AEAD_CHACHA20POLY1305_IETF_NPUBBYTES);
    $cipher = sodium_crypto_aead_chacha20poly1305_ietf_encrypt($plain, $nonce, $nonce, $key);
    return $version . ':3:' . base64_encode($nonce . $cipher);
}

/**
 * Decrypts a value encryptForMagento() produced. --diff uses it to compare
 * encrypted values: they differ on every run because of the random nonce.
 */
function decryptForMagento(string $value, string $cryptKey): ?string
{
    $parts = explode(':', $value, 3);
    if (count($parts) !== 3 || $parts[1] !== '3') {
        return null;
    }
    $keys = preg_split('/\s+/', trim($cryptKey)) ?: [];
    $key = decodeKey($keys[(int)$parts[0]] ?? '');
    $raw = base64_decode($parts[2], true);
    if ($raw === false || strlen($raw) <= SODIUM_CRYPTO_AEAD_CHACHA20POLY1305_IETF_NPUBBYTES) {
        return null;
    }
    $nonce = substr($raw, 0, SODIUM_CRYPTO_AEAD_CHACHA20POLY1305_IETF_NPUBBYTES);
    $plain = sodium_crypto_aead_chacha20poly1305_ietf_decrypt(
        substr($raw, SODIUM_CRYPTO_AEAD_CHACHA20POLY1305_IETF_NPUBBYTES),
        $nonce,
        $nonce,
        $key
    );
    return $plain === false ? null : $plain;
}

/** @return array{0: int, 1: string} the current key version and its raw key */
function currentKey(string $cryptKey): array
{
    $keys = preg_split('/\s+/', trim($cryptKey)) ?: [];
    $version = count($keys) - 1;
    $key = decodeKey($keys[$version] ?? '');
    if (strlen($key) !== SODIUM_CRYPTO_AEAD_CHACHA20POLY1305_IETF_KEYBYTES) {
        throw new RuntimeException(
            'CRYPT_KEY must be 32 bytes (or "base64" followed by 32 base64-encoded bytes) to encrypt SMTP_PASSWORD'
        );
    }
    return [$version, $key];
}

function decodeKey(string $key): string
{
    return str_starts_with($key, 'base64') ? (string)base64_decode(substr($key, 6)) : $key;
}

/** Builds the env.php array. Every value comes from the environment. */
function buildConfig(): array
{
    $cryptKey = required('CRYPT_KEY');

    // On a server each colour gets its own cache namespace. While blue and green
    // overlap during a release, the new code must not overwrite cache entries the old
    // code is still reading (GLOBAL_PLUGIN_LIST, compiled config, ...).
    $prefix = env('CACHE_ID_PREFIX');
    if (env('STACK_COLOR') !== '') {
        $prefix .= env('STACK_COLOR') . '_';
    }

    $defaultCache = [
        'id_prefix' => $prefix,
        // A key of the Mage-OS 3.6 adapter map. A class name here silently puts the
        // cache on the filesystem (FINDINGS, reference section).
        'backend' => 'valkey',
        'backend_options' => [
            'server' => required('CACHE_HOST'),
            'port' => env('CACHE_PORT', '6379'),
            'database' => '1',
            'serializer' => 'igbinary',
            'compress_data' => '1',
            'compression_lib' => 'gzip',
            'persistent' => '1',
            'persistent_id' => 'cache_default',
            'timeout' => '2.5',
            'read_timeout' => '2.0',
            'use_lua' => '1',
            'use_lua_on_gc' => '1',
        ],
    ];
    // Preloaded ids are held in each worker's memory for its whole life. Only ids
    // that change at deploy are safe to list (FINDINGS F-07).
    $preload = listOf(env('MAGENTO_PRELOAD_KEYS'));
    if ($preload !== []) {
        $defaultCache['backend_options']['preload_keys'] = array_map(
            static fn(string $id): string => $prefix . $id,
            $preload
        );
    }

    $fpc = env('FPC_BACKEND', 'varnish');
    if (!in_array($fpc, ['varnish', 'builtin'], true)) {
        throw new RuntimeException("FPC_BACKEND must be varnish or builtin, not '$fpc'");
    }
    $frontends = ['default' => $defaultCache];
    if ($fpc === 'builtin') {
        // With Varnish this frontend is never read or written (FINDINGS F-27).
        $frontends['page_cache'] = [
            'id_prefix' => $prefix,
            'backend' => 'valkey',
            'backend_options' => [
                'server' => required('CACHE_HOST'),
                'port' => env('CACHE_PORT', '6379'),
                'database' => '2',
                'serializer' => 'igbinary',
                'compress_data' => '0',
                'persistent' => '1',
                'persistent_id' => 'cache_fpc',
            ],
        ];
    }

    $config = [
        'remote_storage' => ['driver' => 'file'],
        'backend' => ['frontName' => required('ADMIN_FRONT_NAME')],
        'crypt' => ['key' => $cryptKey],
        'db' => [
            'table_prefix' => '',
            'connection' => [
                'default' => [
                    'host' => required('DB_HOST'),
                    'dbname' => required('DB_NAME'),
                    'username' => required('DB_USER'),
                    'password' => required('DB_PASSWORD'),
                    'model' => 'mysql4',
                    'engine' => 'innodb',
                    'initStatements' => 'SET NAMES utf8;',
                    'active' => '1',
                    // 1014 is MYSQL_ATTR_SSL_VERIFY_SERVER_CERT. It's written as the literal
                    // because PHP 8.5 deprecates the PDO::MYSQL_* constants, and they don't
                    // exist at all without pdo_mysql loaded.
                    'driver_options' => [1014 => false],
                ],
            ],
        ],
        'resource' => ['default_setup' => ['connection' => 'default']],
        'x-frame-options' => 'SAMEORIGIN',
        'MAGE_MODE' => env('MAGE_MODE', 'production'),
        'session' => [
            'save' => 'redis',
            'redis' => [
                'host' => required('SESSION_HOST'),
                'port' => env('SESSION_PORT', '6379'),
                'password' => '',
                'timeout' => '2.5',
                'retries' => '0',
                'persistent_identifier' => '',
                'database' => '0',
                'compression_threshold' => '2048',
                'compression_library' => 'gzip',
                'log_level' => '1',
                'max_concurrency' => '6',
                'break_after_frontend' => '5',
                'break_after_adminhtml' => '30',
                'first_lifetime' => '600',
                'bot_first_lifetime' => '60',
                'bot_lifetime' => '7200',
                'disable_locking' => '0',
                'min_lifetime' => '60',
                'max_lifetime' => '2592000',
                'sentinel_master' => '',
                'sentinel_servers' => '',
                'sentinel_connect_retries' => '5',
                'sentinel_verify_master' => '0',
            ],
        ],
        'cache' => [
            'graphql' => ['id_salt' => required('GRAPHQL_ID_SALT')],
            'frontend' => $frontends,
            // Keeps the lock-guarded loader serialising regeneration, so the cache
            // flush after a deploy doesn't stampede.
            'allow_parallel_generation' => false,
        ],
        'config' => ['async' => 0],
        'queue' => [
            'amqp' => [
                'host' => required('AMQP_HOST'),
                'port' => env('AMQP_PORT', '5672'),
                'user' => required('RABBITMQ_USER'),
                'password' => required('RABBITMQ_PASSWORD'),
                'virtualhost' => env('RABBITMQ_VHOST', '/'),
            ],
            'consumers_wait_for_messages' => 1,
            // The consumers service runs them; cron must not start a second copy.
            'consumers_runner' => ['cron_run' => false],
        ],
        'lock' => ['provider' => 'db'],
        'db_logger' => [
            'output' => env('DB_QUERY_LOG', 'disabled'),
            'log_everything' => 1,
            'query_time_threshold' => 0.001,
            'include_stacktrace' => 0,
            'include_index_check' => 0,
        ],
        'directories' => ['document_root_is_pub' => true],
        'system' => ['default' => systemDefaults($cryptKey, $fpc)],
        'cache_types' => cacheTypes(),
        'downloadable_domains' => listOf(env('STORE_DOMAIN') . ' ' . env('STORE_ALIASES')),
        'install' => ['date' => required('INSTALL_DATE')],
    ];

    if ($fpc === 'varnish') {
        $config['http_cache_hosts'] = [['host' => required('VARNISH_HOST'), 'port' => '80']];
    }

    return $config;
}

/** system/default values: locked in env.php, so the admin shows them read-only. */
function systemDefaults(string $cryptKey, string $fpc): array
{
    $searchHost = required('OPENSEARCH_HOST');
    $searchPort = env('OPENSEARCH_PORT', '9200');
    $https = env('OPENSEARCH_HTTPS', '1') === '1';
    $searchUser = required('OPENSEARCH_MAGENTO_USER');
    $searchPassword = required('OPENSEARCH_MAGENTO_PASSWORD');
    $indexPrefix = env('OPENSEARCH_INDEX_PREFIX', 'magento2');

    $system = [
        // ElasticSuite. Harmless when the module isn't installed.
        'smile_elasticsuite_core_base_settings' => [
            'es_client' => [
                'servers' => $searchHost . ':' . $searchPort,
                'enable_https_mode' => $https ? '1' : '0',
                // ElasticSuite has no CA-file option; the entrypoint puts the stack's
                // CA in the system trust store instead.
                'enable_certificate_validation' => $https ? '1' : '0',
                'enable_http_auth' => '1',
                'http_auth_user' => $searchUser,
                'http_auth_pwd' => $searchPassword,
            ],
            'indices_settings' => ['alias' => $indexPrefix],
        ],
        // Core OpenSearch. It takes the scheme from the hostname.
        'catalog' => [
            'search' => [
                'opensearch_server_hostname' => ($https ? 'https://' : 'http://') . $searchHost,
                'opensearch_server_port' => $searchPort,
                'opensearch_index_prefix' => $indexPrefix,
                'opensearch_enable_auth' => '1',
                'opensearch_username' => $searchUser,
                'opensearch_password' => $searchPassword,
            ],
        ],
        'system' => [
            'full_page_cache' => [
                'caching_application' => $fpc === 'varnish' ? '2' : '1',
            ],
        ],
    ];

    if ($fpc === 'varnish') {
        // Used when Magento exports a VCL from the admin. The stack renders its own VCL
        // (deploy/templates/varnish), so these only keep that export honest.
        $system['system']['full_page_cache']['varnish'] = [
            'access_list' => required('VARNISH_BACKEND_HOST'),
            'backend_host' => required('VARNISH_BACKEND_HOST'),
            'backend_port' => '80',
            'grace_period' => '300',
        ];
    }

    $smtpHost = env('SMTP_HOST');
    if ($smtpHost !== '') {
        $auth = env('SMTP_AUTH', 'none');
        $ssl = env('SMTP_SSL', 'none');
        if (!in_array($auth, ['none', 'plain', 'login'], true)) {
            throw new RuntimeException("SMTP_AUTH must be none, plain or login, not '$auth'");
        }
        if (!in_array($ssl, ['none', 'ssl', 'tls'], true)) {
            throw new RuntimeException("SMTP_SSL must be none, ssl or tls, not '$ssl'");
        }
        $smtp = [
            'disable' => '0',
            'transport' => 'smtp',
            'host' => $smtpHost,
            'port' => env('SMTP_PORT', '25'),
            'auth' => $auth,
            'ssl' => $ssl,
            'username' => env('SMTP_USER'),
        ];
        $password = env('SMTP_PASSWORD');
        if ($password !== '') {
            // system/smtp/password is an Encrypted field, so Magento decrypts what it
            // reads. A plaintext value here would decrypt to garbage.
            $smtp['password'] = encryptForMagento($password, $cryptKey);
        }
        $system['system']['smtp'] = $smtp;
    }

    $baseUrl = env('MAGENTO_BASE_URL');
    if ($baseUrl !== '') {
        if (!preg_match('#^https?://[^/]+/$#', $baseUrl)) {
            throw new RuntimeException("MAGENTO_BASE_URL must look like https://host[:port]/ (with the trailing slash), not '$baseUrl'");
        }
        $system['web'] = [
            'unsecure' => ['base_url' => $baseUrl],
            'secure' => ['base_url' => $baseUrl, 'use_in_frontend' => '1', 'use_in_adminhtml' => '1'],
        ];
    }

    return $system;
}

/** Every managed cache type, enabled unless MAGENTO_CACHE_DISABLED lists it. */
function cacheTypes(): array
{
    $types = array_values(array_unique(array_merge(CORE_CACHE_TYPES, listOf(env('MAGENTO_CACHE_TYPES_EXTRA')))));
    $disabled = listOf(env('MAGENTO_CACHE_DISABLED'));
    $unknown = array_diff($disabled, $types);
    if ($unknown !== []) {
        throw new RuntimeException(
            'MAGENTO_CACHE_DISABLED names cache types this stack doesn\'t manage: ' . implode(', ', $unknown)
            . '. Add module types to MAGENTO_CACHE_TYPES_EXTRA.'
        );
    }
    $result = [];
    foreach ($types as $type) {
        $result[$type] = in_array($type, $disabled, true) ? 0 : 1;
    }
    return $result;
}

function render(array $config): string
{
    return "<?php\n"
        . "// GENERATED by stack-entrypoint from the container environment (.env).\n"
        . "// Do not edit: the next container start overwrites it. Change .env instead.\n"
        . 'return ' . var_export($config, true) . ";\n";
}

function writeAtomically(string $path, string $contents): void
{
    $tmp = $path . '.tmp.' . getmypid();
    if (file_put_contents($tmp, $contents, LOCK_EX) === false) {
        throw new RuntimeException("cannot write $tmp");
    }
    chmod($tmp, 0640);
    if (!rename($tmp, $path)) {
        @unlink($tmp);
        throw new RuntimeException("cannot move $tmp into place as $path");
    }
}

/** Flattens a nested array into dotted paths, for --diff. */
function flatten(array $data, string $prefix = ''): array
{
    $flat = [];
    foreach ($data as $key => $value) {
        $path = $prefix === '' ? (string)$key : $prefix . '.' . $key;
        if (is_array($value) && $value !== [] && !array_is_list($value)) {
            $flat += flatten($value, $path);
        } else {
            $flat[$path] = $value;
        }
    }
    return $flat;
}

function isSecret(string $path): bool
{
    $leaf = substr($path, (int)strrpos($path, '.') + 1);
    return in_array($leaf, SECRET_KEYS, true);
}

function show(string $path, mixed $value): string
{
    return isSecret($path) ? '***' : var_export($value, true);
}

/** Prints what --write would change. Exit code 0 = no change, 1 = changes. */
function diff(array $new, string $cryptKey): int
{
    $old = is_file(ENV_PHP) ? (include ENV_PHP) : [];
    $old = is_array($old) ? flatten($old) : [];
    $new = flatten($new);
    $changes = 0;
    foreach ($new + $old as $path => $_) {
        $before = $old[$path] ?? null;
        $after = $new[$path] ?? null;
        if ($path === 'system.default.system.smtp.password' && is_string($before) && is_string($after)) {
            if (decryptForMagento($before, $cryptKey) === decryptForMagento($after, $cryptKey)) {
                continue;
            }
        }
        if ($before === $after) {
            continue;
        }
        $changes++;
        if (!array_key_exists($path, $old)) {
            printf("+ %s = %s\n", $path, show($path, $after));
        } elseif (!array_key_exists($path, $new)) {
            printf("- %s (was %s)\n", $path, show($path, $before));
        } else {
            printf("~ %s: %s -> %s\n", $path, show($path, $before), show($path, $after));
        }
    }
    return $changes === 0 ? 0 : 1;
}

function main(array $argv): int
{
    $mode = $argv[1] ?? '';
    try {
        $config = buildConfig();
        switch ($mode) {
            case '--write':
                writeAtomically(ENV_PHP, render($config));
                fwrite(STDERR, "[generate-env-php] wrote " . ENV_PHP . "\n");
                return 0;
            case '--diff':
                return diff($config, required('CRYPT_KEY'));
            default:
                fwrite(STDERR, "usage: php generate-env-php.php --write|--diff\n");
                return 2;
        }
    } catch (Throwable $e) {
        fwrite(STDERR, '[generate-env-php] ' . $e->getMessage() . "\n");
        return 2;
    }
}

exit(main($argv));
