<?php

/**
 * #.local-generated: Automatically generated WordPress must-use plugin.
 * .local manages this file and overwrites it on every container start.
 *
 * Source:       .local/wp-mu-plugins/00-sandbox-mail-guard.php
 * Installed by: .ddev/web-entrypoint.d/10-sandbox-mu-plugins.sh
 *                 -> wp-content/mu-plugins/local-mu-plugins/
 * Loaded by:    wp-content/mu-plugins/00-local-mu-plugins.php (generated stub)
 *
 * Stops a site's own SMTP plugin from sending real mail out of the sandbox.
 *
 * DDEV already captures ordinary mail with no help from us: the web container
 * ships Mailpit and sets
 *
 *     sendmail_path = /usr/local/bin/mailpit sendmail -t --smtp-addr 127.0.0.1:1025
 *
 * so any plain mail() — and therefore any ordinary wp_mail() — lands in Mailpit.
 * That is why this file is much smaller than the 00-sandbox-mailpit.php it
 * replaces: the SMTP wiring and the "wordpress@localhost has no dot" From-address
 * rescue are both unnecessary now (DDEV serves the site at <project>.ddev.site,
 * which has a dot).
 *
 * What DDEV does NOT protect against is a plugin that bypasses mail() entirely.
 * WP Mail SMTP, Post SMTP, Easy WP SMTP and friends hook phpmailer_init and
 * point PHPMailer at a real relay with real credentials — usually credentials
 * that came along with an imported production database. Nothing in sendmail_path
 * can intercept that, and the sandbox would cheerfully email live customers.
 *
 * Read the captured mail at:
 *   ddev mailpit                                  (opens the UI)
 *   https://<project>.ddev.site:8026              (host browser)
 *   http://127.0.0.1:8025/api/v1/messages         (JSON API, from the web container)
 *
 * @package .local
 */

// Sandbox-only. IS_DDEV_PROJECT is set in every DDEV web container and nowhere
// else, so a stray copy of this file can never hijack production mail. getenv()
// rather than $_ENV out of habit and for CLI safety, though DDEV ships PHP with
// variables_order=EGPCS so both work here.
if (getenv('IS_DDEV_PROJECT') !== 'true') {
    return;
}

/**
 * Force every message back onto the sandbox's own Mailpit, whatever the site
 * thinks it is configured to do.
 *
 * PHP_INT_MAX priority is the whole point. An SMTP plugin registers its
 * phpmailer_init callback at the default priority 10, but mu-plugins load before
 * regular plugins — so ours would be registered *first* and the plugin's
 * callback would run *after* it and overwrite everything, sending real mail.
 * Running last instead makes that impossible.
 */
add_action('phpmailer_init', static function ($phpmailer) {
    // Mailpit's SMTP listener inside the DDEV web container.
    $phpmailer->isSMTP();
    $phpmailer->Host = '127.0.0.1';
    $phpmailer->Port = 1025;

    // Undo anything a plugin configured. Mailpit accepts unauthenticated plain
    // SMTP, and leaving stale credentials or TLS settings in place would make
    // the handoff fail rather than be captured.
    $phpmailer->SMTPAuth   = false;
    $phpmailer->Username   = '';
    $phpmailer->Password   = '';
    $phpmailer->SMTPSecure = '';
    // Without this PHPMailer attempts STARTTLS first; Mailpit speaks plain SMTP.
    $phpmailer->SMTPAutoTLS = false;
    // Keep a page load from hanging for a minute if Mailpit is somehow down.
    $phpmailer->Timeout = 10;
}, PHP_INT_MAX);
