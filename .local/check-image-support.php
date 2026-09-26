<?php
/**
 * Sandbox image-support check — verifies PHP can actually process images.
 *
 * Run it in whichever container you care about:
 *
 *   php .local/check-image-support.php                                    # claude container
 *   ./.local/compose.sh exec wordpress php /var/www/html/.local/check-image-support.php
 *
 * Note the wordpress container masks /var/www/html/.local, so from the host use:
 *   docker cp .local/check-image-support.php <wp-container>:/tmp/ && ... php /tmp/...
 *
 * It does not just check extension_loaded() — a loaded extension with no JPEG
 * or PNG delegate still can't resize a media library, so each backend is made
 * to round-trip a real image.
 */

$failures = [];
$line = str_repeat('-', 58);

function ok(string $msg): void   { echo "  [ OK ] $msg\n"; }
function bad(string $msg): void  { global $failures; $failures[] = $msg; echo "  [FAIL] $msg\n"; }
function info(string $msg): void { echo "  .     $msg\n"; }

echo "PHP " . PHP_VERSION . " (" . PHP_SAPI . ")\n";
echo "$line\n";

/* ------------------------------------------------------------------ GD -- */
echo "GD\n";
if (!extension_loaded('gd')) {
    bad('gd extension not loaded');
} else {
    $gd = gd_info();
    info('version: ' . ($gd['GD Version'] ?? '?'));

    foreach (['JPEG Support', 'PNG Support', 'GIF Read Support', 'WebP Support', 'FreeType Support'] as $cap) {
        empty($gd[$cap]) ? bad("gd: $cap missing") : ok("gd: $cap");
    }

    // Round-trip: draw -> encode JPEG -> decode -> resize.
    $im = imagecreatetruecolor(120, 90);
    if (!$im) {
        bad('gd: imagecreatetruecolor() failed');
    } else {
        imagefilledrectangle($im, 0, 0, 119, 89, imagecolorallocate($im, 200, 30, 60));

        ob_start();
        $encoded = imagejpeg($im, null, 90);
        $jpeg = ob_get_clean();
        imagedestroy($im);

        if (!$encoded || strlen($jpeg) < 100) {
            bad('gd: JPEG encode produced no output');
        } else {
            $back = imagecreatefromstring($jpeg);
            if (!$back) {
                bad('gd: could not decode the JPEG it just wrote');
            } else {
                $small = imagescale($back, 40);
                if (!$small || imagesx($small) !== 40) {
                    bad('gd: imagescale() failed');
                } else {
                    ok('gd: round-trip create -> JPEG (' . strlen($jpeg) . ' bytes) -> decode -> resize to 40px');
                    imagedestroy($small);
                }
                imagedestroy($back);
            }
        }
    }
}

/* ------------------------------------------------------------- Imagick -- */
echo "\nImagick\n";
if (!extension_loaded('imagick')) {
    bad('imagick extension not loaded');
} else {
    info('extension: ' . phpversion('imagick'));
    $v = Imagick::getVersion();
    info('imagemagick: ' . ($v['versionString'] ?? '?'));

    $formats = array_map('strtoupper', Imagick::queryFormats());
    foreach (['JPEG', 'PNG', 'GIF', 'WEBP'] as $fmt) {
        in_array($fmt, $formats, true) ? ok("imagick: $fmt delegate") : bad("imagick: $fmt delegate missing");
    }

    // Round-trip: synthesize -> write PNG -> read back -> thumbnail.
    try {
        $img = new Imagick();
        $img->newImage(120, 90, new ImagickPixel('rgb(30,120,200)'));
        $img->setImageFormat('png');
        $png = $img->getImageBlob();
        $img->clear();

        if (strlen($png) < 100) {
            bad('imagick: PNG encode produced no output');
        } else {
            $back = new Imagick();
            $back->readImageBlob($png);
            $back->thumbnailImage(40, 0);
            if ($back->getImageWidth() !== 40) {
                bad('imagick: thumbnailImage() did not resize');
            } else {
                ok('imagick: round-trip create -> PNG (' . strlen($png) . ' bytes) -> read -> thumbnail to 40px');
            }
            $back->clear();
        }
    } catch (Throwable $e) {
        bad('imagick: ' . $e->getMessage());
    }
}

/* ------------------------------------------------- WordPress, if present -- */
// Which editor WordPress itself would pick — the answer that actually decides
// whether the media library works. Deliberately NOT via wp-load.php: that needs
// a reachable database and dies with an HTML error page when there isn't one,
// which has nothing to do with image support. Loading the four editor files
// directly gives the same answer in any container, DB or no DB.
echo "\nWordPress image editor\n";

// Normally run from .local/, but also copied to /tmp to reach the wordpress
// container (which masks /var/www/html/.local) — so don't assume the docroot
// is the parent directory.
$abspath = null;
foreach ([dirname(__DIR__), '/var/www/html', '/workspace', getcwd()] as $dir) {
    if ($dir && is_readable("$dir/wp-includes/class-wp-image-editor.php")) {
        $abspath = rtrim($dir, '/') . '/';
        break;
    }
}

if ($abspath === null) {
    info('no WordPress core found from here — skipped');
} else {
    info("docroot: " . rtrim($abspath, '/'));
    // Both are normally set by wp-load.php / wp-settings.php, which we're
    // deliberately bypassing; core files require() against them.
    if (!defined('ABSPATH')) {
        define('ABSPATH', $abspath);
    }
    if (!defined('WPINC')) {
        define('WPINC', 'wp-includes');
    }

    // Order matters. The editors call wp_get_default_extension_for_mime_type()
    // (functions.php), which filters through the hook layer — so plugin.php and
    // functions.php have to be in place before the editors load.
    //
    // Each entry names what it provides, and is skipped if that already exists:
    // plugin.php pulls in class-wp-hook.php with a bare `require`, so loading
    // that file ourselves afterwards would redeclare WP_Hook and fatal.
    $includes = [
        ['wp-includes/class-wp-error.php',              'class',    'WP_Error'],
        ['wp-includes/plugin.php',                      'function', 'apply_filters'],
        ['wp-includes/class-wp-hook.php',               'class',    'WP_Hook'],
        ['wp-includes/functions.php',                   'function', 'wp_get_default_extension_for_mime_type'],
        ['wp-includes/class-wp-image-editor.php',       'class',    'WP_Image_Editor'],
        ['wp-includes/class-wp-image-editor-gd.php',    'class',    'WP_Image_Editor_GD'],
        ['wp-includes/class-wp-image-editor-imagick.php', 'class',  'WP_Image_Editor_Imagick'],
    ];
    foreach ($includes as [$rel, $kind, $name]) {
        $already = $kind === 'class' ? class_exists($name, false) : function_exists($name);
        if (!$already && is_readable($abspath . $rel)) {
            require_once $abspath . $rel;
        }
    }

    if (!class_exists('WP_Image_Editor_GD') || !class_exists('WP_Image_Editor_Imagick')) {
        info('editor classes could not be loaded — skipped');
    } else {
        // Same order and the same two gates core applies in
        // _wp_image_editor_choose(): the class must test() clean and claim the
        // mime type. Core prefers Imagick, falling back to GD.
        $chosen = null;
        foreach (['WP_Image_Editor_Imagick', 'WP_Image_Editor_GD'] as $class) {
            try {
                $usable = $class::test([]) && $class::supports_mime_type('image/jpeg');
            } catch (Throwable $e) {
                // Only part of core is loaded here, so a missing dependency is a
                // limitation of this probe, not evidence the editor is broken.
                info("$class: could not probe ({$e->getMessage()})");
                continue;
            }
            $usable ? ok("$class is usable for image/jpeg") : info("$class is NOT usable for image/jpeg");
            if ($usable && $chosen === null) {
                $chosen = $class;
            }
        }

        if ($chosen === null) {
            bad('WordPress would find no usable image editor for image/jpeg');
        } else {
            ok("WordPress would pick $chosen");
        }
    }
}

echo "$line\n";
if ($failures) {
    echo count($failures) . " check(s) FAILED:\n";
    foreach ($failures as $f) {
        echo "  - $f\n";
    }
    exit(1);
}
echo "All image-support checks passed.\n";
exit(0);
