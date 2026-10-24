<?php
/**
 * Magento core cache types (Mage-OS 3.6), declared in the cache.xml files of
 * mage-os/framework and the core modules.
 *
 * Two readers share this list:
 *  - generate-env-php.php writes every core type into env.php's cache_types. Magento
 *    treats a type missing from env.php as disabled.
 *  - deploy/lib/read-env-php.php works out a project's own module types (env.php's
 *    cache_types minus these) for MAGENTO_CACHE_TYPES_EXTRA.
 *
 * Baked into the image at /usr/local/lib/stack/core-cache-types.php.
 */
return [
    'block_html', 'collections', 'compiled_config', 'config', 'config_integration',
    'config_integration_api', 'config_webservice', 'customer_notification', 'db_ddl',
    'eav', 'full_page', 'graphql_query_resolver_result', 'layout', 'reflection', 'translate',
];
