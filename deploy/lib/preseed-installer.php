<?php
/**
 * Writes the Mage-OS installer's resume file, so `bin/magento install` starts with the
 * stack's services and credentials already answered.
 *
 * The format is the one InstallationContext::fromArray() reads
 * (setup/src/MageOS/Installer/Model/Writer/ConfigFileManager.php): {"config": {...}}.
 * The installer leaves passwords out when it saves this file itself. It still reads
 * them when they're present, so including them here means no stage asks for one.
 * Each stage then shows its saved values and asks one "use saved?" question.
 *
 * Without a password, a resumed RabbitMQ config would silently fall back to
 * "guest" (RabbitMQConfiguration::fromArray()). Writing the real one avoids that.
 *
 * The file holds passwords, so it's created 0600. The installer deletes it after a
 * successful install, and deploy/setup deletes it after the handoff whatever happened.
 *
 * Every value comes from an environment variable passed in by deploy/setup.
 */
declare(strict_types=1);

$env = static function (string $key, string $default = ''): string {
    $value = getenv($key);
    return ($value === false || $value === '') ? $default : $value;
};
$flag = static fn(string $key): bool => $env($key) === '1';

$hyva = $flag('PRESEED_HYVA');

$config = [
    'environment' => ['type' => 'development', 'mageMode' => 'developer'],
    'database' => [
        'host' => $env('PRESEED_DB_HOST'),
        'name' => $env('PRESEED_DB_NAME'),
        'user' => $env('PRESEED_DB_USER'),
        'password' => $env('PRESEED_DB_PASSWORD'),
        'prefix' => '',
    ],
    'admin' => [
        'firstName' => 'Admin',
        'lastName' => 'User',
        'email' => $env('PRESEED_ADMIN_EMAIL'),
        'username' => $env('PRESEED_ADMIN_USER', 'admin'),
        'password' => $env('PRESEED_ADMIN_PASSWORD'),
    ],
    'store' => [
        'baseUrl' => $env('PRESEED_BASE_URL'),
        'language' => $env('PRESEED_LOCALE', 'en_US'),
        'currency' => $env('PRESEED_CURRENCY', 'USD'),
        'timezone' => $env('PRESEED_TIMEZONE', 'UTC'),
        'useRewrites' => true,
    ],
    'backend' => ['frontname' => $env('PRESEED_ADMIN_FRONT_NAME', 'admin')],
    'search' => [
        'engine' => 'opensearch',
        // Core OpenSearch takes the scheme from the hostname. The entrypoint has put the
        // stack's CA in the trust store, so setup:install's connection check can verify it.
        'host' => 'https://' . $env('PRESEED_OPENSEARCH_HOST'),
        'port' => 9200,
        'prefix' => $env('PRESEED_OPENSEARCH_PREFIX', 'magento2'),
        'enableAuth' => true,
        'username' => $env('PRESEED_OPENSEARCH_USER'),
        'password' => $env('PRESEED_OPENSEARCH_PASSWORD'),
    ],
    // Off on purpose. The installer can describe only one Redis host, and the stack
    // has two Valkey instances. env.php is regenerated from .env on the next start,
    // and that configures both.
    'redis' => [
        'session' => false,
        'cache' => false,
        'fpc' => false,
        'host' => $env('PRESEED_CACHE_HOST'),
        'port' => 6379,
        'sessionDb' => 0,
        'cacheDb' => 1,
        'fpcDb' => 2,
    ],
    'rabbitmq' => [
        'enabled' => true,
        'host' => $env('PRESEED_AMQP_HOST'),
        'port' => 5672,
        'user' => $env('PRESEED_AMQP_USER'),
        'password' => $env('PRESEED_AMQP_PASSWORD'),
        'virtualHost' => $env('PRESEED_AMQP_VHOST', '/'),
    ],
    'logging' => ['debugMode' => false, 'logLevel' => 'error'],
    'sampleData' => ['install' => $flag('PRESEED_SAMPLE_DATA')],
    // Hyvä is installed by the installer's own theme stage, before setup:install, with
    // the free access key from the hyva.io dashboard. Without --hyva the store uses Luma.
    'theme' => [
        'install' => $hyva,
        'theme' => $hyva ? 'hyva' : 'luma',
        'hyva_project_key' => $env('PRESEED_HYVA_PROJECT_KEY'),
        'hyva_api_token' => $env('PRESEED_HYVA_API_TOKEN'),
    ],
];

$file = '/app/var/.mageos-install-config.json';
if (!is_dir(dirname($file)) && !mkdir(dirname($file), 0775, true)) {
    fwrite(STDERR, "preseed-installer: cannot create " . dirname($file) . "\n");
    exit(2);
}
$json = json_encode(
    [
        '_metadata' => [
            'created_at' => date('Y-m-d H:i:s'),
            'version' => '1.0.0',
            'note' => 'Pre-seeded by deploy/setup. Holds passwords until the install finishes; deleted afterwards.',
        ],
        'config' => $config,
    ],
    JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR
);
$old = umask(0077);
$written = file_put_contents($file, $json);
umask($old);
if ($written === false) {
    fwrite(STDERR, "preseed-installer: cannot write $file\n");
    exit(2);
}
chmod($file, 0600);
fwrite(STDERR, "preseed-installer: wrote $file\n");
