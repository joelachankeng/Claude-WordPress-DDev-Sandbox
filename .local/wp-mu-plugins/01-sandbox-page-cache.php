<?php

/**
 * #.local-generated: Automatically generated WordPress must-use plugin.
 * .local manages this file and overwrites it on every container start.
 *
 * Source:       .local/wp-mu-plugins/01-sandbox-page-cache.php
 * Installed by: .local/wp-entrypoint.sh  ->  wp-content/mu-plugins/local-mu-plugins/
 * Loaded by:    wp-content/mu-plugins/00-local-mu-plugins.php (generated stub)
 *
 * Drops the Pantheon page-cache TTL to zero in the sandbox.
 *
 * pantheon-mu-plugin sends `cache-control: public, max-age=604800` on HTML — a
 * one-week cache. On Pantheon that is correct: their edge cache honours it and
 * is purged whenever content changes (pantheon-advanced-page-cache and
 * hria-cloudflare-purge-cache handle that). The sandbox has no purge layer, so
 * any page visited without a cache-busting query string is pinned in the
 * browser for a week — you edit a template, reload, and see the old page with
 * no indication why. It survives theme renames and asset moves, producing 404s
 * for files that no longer exist at paths the site stopped using days ago.
 *
 * `public, max-age=0` keeps the response cacheable but immediately stale, so
 * the browser revalidates on every request and always renders current markup.
 *
 * @package .local
 */

// Sandbox-only. Every sandbox service sets PANTHEON_ENVIRONMENT=local; a real
// host does not, so a stray copy of this file can never slow production down.
// getenv() is used rather than $_ENV because WP-CLI runs with an empty $_ENV
// unless variables_order includes E (see .local/DOC/FIX/WP_CLI_DB_CONNECTION_FIX.md).
if (getenv('PANTHEON_ENVIRONMENT') !== 'local') {
    return;
}

/**
 * Zero the cache lifetime.
 *
 * This runs before Pantheon's mu-plugins/loader.php: the generated stub that
 * pulls this file in is named 00-local-mu-plugins.php, and mu-plugins load in
 * filename order, so "00-" beats "loader". The filter is therefore registered
 * before Pantheon_Cache reads it — both when it builds its default options
 * (pantheon-page-cache.php, setup()) and when it assembles the cache-control
 * header on each request (get_cache_control_header_value()).
 *
 * Pantheon clamps a sub-60-second TTL back up to 60 when PANTHEON_ENVIRONMENT
 * is 'live', so even a misplaced copy of this file cannot disable caching on a
 * production site.
 */
add_filter('pantheon_cache_default_max_age', static function () {
    return 0;
});
