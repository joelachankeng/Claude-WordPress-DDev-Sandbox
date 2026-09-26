<?php

/**
 * #.local-generated: Automatically generated WordPress must-use plugin.
 * .local manages this file and overwrites it on every container start.
 *
 * Source:       .local/wp-mu-plugins/01-sandbox-page-cache.php
 * Installed by: .ddev/web-entrypoint.d/10-sandbox-mu-plugins.sh
 *                 -> wp-content/mu-plugins/local-mu-plugins/
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

// Sandbox-only. IS_DDEV_PROJECT is set in every DDEV web container and nowhere
// else, so a stray copy of this file can never slow production down.
if (getenv('IS_DDEV_PROJECT') !== 'true') {
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
 * production site. The IS_DDEV_PROJECT gate above means it never gets there.
 */
add_filter('pantheon_cache_default_max_age', static function () {
    return 0;
});
