<?php

/**
 * #.local-generated: Automatically generated WordPress must-use plugin.
 * .local manages this file and overwrites it on every container start.
 *
 * Source:       .local/wp-mu-plugins/00-sandbox-mailpit.php
 * Installed by: .local/wp-entrypoint.sh  ->  wp-content/mu-plugins/local-mu-plugins/
 * Loaded by:    wp-content/mu-plugins/00-local-mu-plugins.php (generated stub)
 *
 * Routes every wp_mail() call through the sandbox Mailpit container instead of
 * PHP's mail(), which the wordpress:php8.2-apache image has no MTA behind — so
 * without this, password resets and notifications vanish silently.
 *
 * Read the captured mail at:
 *   http://localhost:8025      (host browser)
 *   http://mailpit:8025        (from a sibling container, e.g. Claude/Playwright)
 *   http://mailpit:8025/api/v1/messages   (JSON API)
 *
 * @package .local
 */

// Sandbox-only. Every sandbox service sets PANTHEON_ENVIRONMENT=local; a real
// host does not, so a stray copy of this file can never hijack production mail.
// getenv() is used rather than $_ENV because WP-CLI runs with an empty $_ENV
// unless variables_order includes E (see .local/DOC/FIX/WP_CLI_DB_CONNECTION_FIX.md).
if (getenv('PANTHEON_ENVIRONMENT') !== 'local') {
    return;
}

/**
 * A sandbox served from http://localhost makes WordPress derive the From
 * address "wordpress@localhost", which PHPMailer refuses over SMTP because the
 * domain has no dot — every wp_mail() would return false. Rescue only that
 * unusable default; anything a plugin or the site set is left alone. Priority
 * 99 so this runs after other wp_mail_from filters and judges the final value.
 */
add_filter('wp_mail_from', function ($from) {
    return is_email($from) ? $from : 'wordpress@sandbox.local';
}, 99);

/**
 * PHP_INT_MAX priority so the sandbox always wins. A site with an SMTP plugin
 * (WP Mail SMTP, Post SMTP, ...) hooks phpmailer_init at priority 10; because
 * mu-plugins load first, ours would be registered first and the plugin's
 * callback would run after and overwrite these settings — sending real mail out
 * of the sandbox. Running last makes that impossible.
 */
add_action('phpmailer_init', function ($phpmailer) {
    $phpmailer->isSMTP();
    $phpmailer->Host       = 'mailpit';
    $phpmailer->Port       = 1025;
    $phpmailer->SMTPAuth   = false;
    $phpmailer->Username   = '';
    $phpmailer->Password   = '';
    $phpmailer->SMTPSecure = '';
    // Mailpit speaks plain SMTP; without this PHPMailer tries STARTTLS first.
    $phpmailer->SMTPAutoTLS = false;
    // Keep a page load from hanging for a minute if mailpit is powered off.
    $phpmailer->Timeout = 10;
}, PHP_INT_MAX);
