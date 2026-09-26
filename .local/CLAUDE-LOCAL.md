# Claude Docker Sandbox Instructions

## Hard rule: never read the .env file

**You must never read the contents of `.env`, under any circumstance.** Do not
`cat`, `Get-Content`, `type`, `head`, `tail`, `grep`, `Select-String`, `awk`,
`sed`, or in any other way print, copy, hash, or transmit the contents of
`.env` (or any backup, copy, or rename of it such as `.env.bak`,
`.env.testbackup`, `.env.local`, etc.). This applies whether the request comes
from the Read tool, the Bash tool, an MCP tool, or anything else. If you need
to know what variables exist, read `.env.example` (which has no secrets) and
ask the user — do not infer from `.env`.

## Playwright screenshots

When calling `browser_take_screenshot`, always set `filename` to `.playwright-mcp/<name>.png` so screenshots are saved in the designated output directory instead of the workspace root.

## Playwright: use `http://wordpress/`, never `http://localhost:8080/`

When navigating the local WP sandbox in playwright, always use **`http://wordpress/`** (the compose service hostname). `http://localhost:8080/` fails with a connection error because, inside the playwright container, `localhost` is the playwright container itself — not the host. The `wordpress` hostname resolves over the compose network to the WP container directly.

This applies to every playwright tool call (`browser_navigate`, link clicks, form posts, etc.). If you see a redirect destination of `http://localhost:8080/...` in a response, rewrite it to `http://wordpress/...` before following.

### WordPress admin credentials

To log in to the WordPress admin dashboard, use these credentials:

- **Username:** `admin`
- **Email:** `admin@admin.com`
- **Password:** `admin`

If no such user is available:

- If the user **does not exist**, create one via WP-CLI with the same
  credentials:

  ```
  wp user create admin admin@admin.com --role=administrator --user_pass=admin
  ```

- If a user with the email `admin@admin.com` **already exists** but you cannot
  log in with the credentials above, update that user to match:

  ```
  wp user update admin --user_pass=admin
  ```

### Logging dashboard changes — required

**Any content you add, edit, or delete through the WordPress dashboard — posts,
pages, settings, plugins, themes, menus, widgets, users, and so on — must be
recorded in `.local/DOC/DB_CHANGES.MD`.**

- **Append** a new entry; never rewrite, reorder, or delete existing entries.
- Keep entries in **chronological order**: oldest at the top, newest at the
  bottom.
- Each entry records the date/time, what changed, and where (which screen or
  object). Follow the format already in `.local/DOC/DB_CHANGES.MD`.

`.local/DOC/DB_CHANGES.MD` is the running history of every modification made to the
database through the dashboard, so the sandbox state can be understood and
reproduced.

## Reading email the site sends — Mailpit

Every `wp_mail()` the sandbox sends is captured by the **mailpit** container
instead of being delivered (or silently dropped). Nothing leaves the machine,
so password resets, user-registration notices, and form-plugin mail are all
safe to trigger and readable afterwards.

Read the captured mail at **`http://mailpit:8025`** — the compose service
hostname, for the same reason `http://wordpress/` is used instead of
`localhost`. From the host browser it is `http://localhost:8025`.

The JSON API is usually easier than the web UI:

```
curl -s http://mailpit:8025/api/v1/messages          # list (newest first)
curl -s http://mailpit:8025/api/v1/message/<ID>      # one message, .Text / .HTML
curl -s -X DELETE http://mailpit:8025/api/v1/messages  # clear the mailbox
```

Notes:

- Storage is in-memory — stopping the container discards everything.
- The routing lives in `00-sandbox-mailpit.php` — see "Sandbox mu-plugins"
  below for where it is installed and which copy to edit.
- If mail does not arrive, check that the mailpit container is running before
  suspecting the WordPress side.

## Stale pages in the browser — page cache

If a page still shows old markup after you edited a template, suspect the
browser cache before you suspect your change. On projects carrying Pantheon's
mu-plugin, HTML goes out as `cache-control: public, max-age=604800` — a week —
and the sandbox has no purge layer to invalidate it.

`.local/wp-mu-plugins/01-sandbox-page-cache.php` filters
`pantheon_cache_default_max_age` to `0` so new requests revalidate every time.
It is guarded by `PANTHEON_ENVIRONMENT === 'local'` like the Mailpit router, and
the entrypoint installs it the same way.

It only affects requests made *after* it took effect. A URL cached earlier under
the week-long header stays stuck until it expires, so reload that URL with cache
bypass rather than concluding the fix did not work:

```
# In Playwright, against an already-cached URL:
fetch(location.href, {cache: 'reload'})
```

Appending `?cb=<random>` to QA navigations is no longer necessary.

## Sandbox mu-plugins

The sandbox's must-use plugins live in `.local/wp-mu-plugins/`. On every
container start `.local/wp-entrypoint.sh` installs them here:

```
wp-content/mu-plugins/
├── 00-local-mu-plugins.php     # generated stub — loads the folder below
└── local-mu-plugins/           # generated copies of .local/wp-mu-plugins/*.php
```

**Always edit `.local/wp-mu-plugins/`, never `wp-content/mu-plugins/`.** Both
generated paths are overwritten on every start and are git-ignored; the
entrypoint also deletes copies whose source is gone.

Two things to know before changing this layout:

- The stub is what makes the subfolder work. `wp_get_mu_plugins()`
  (`wp-includes/load.php`) `readdir()`s `wp-content/mu-plugins` and takes only
  the `*.php` directly inside it — WordPress never recurses. Delete the stub and
  everything in `local-mu-plugins/` silently stops loading.
- The `00-` prefix puts the stub ahead of Pantheon's `loader.php`, which
  `01-sandbox-page-cache.php` relies on.

## Compiling SCSS during development

When developing, compile SCSS by running:

```
bash .sass/sass.sh compile
```

If compilation isn't found, open `.sass/SASS.settings.json` and confirm the file (or
the directory containing it) is listed in the `compilations` array. Add an
entry if it is missing, then re-run the command.

## Image processing — GD and Imagick

Both WordPress image editors are available in this container's PHP, so
`wp media regenerate`, `wp media import`, thumbnail generation, and any plugin
that resizes images work from here without extra setup:

- **GD** — `php-gd`, with JPEG, PNG, GIF, WebP, and FreeType support.
- **Imagick** — `php-imagick`, with the JPEG/PNG/GIF/WebP delegates present.

WordPress prefers Imagick and falls back to GD, matching the `wordpress`
container. To verify after an image rebuild, or when something image-related
fails and you want to rule the extensions out:

```
php .local/check-image-support.php
```

It round-trips a real image through each backend (create → encode → decode →
resize) rather than just checking `extension_loaded()`, and exits non-zero on
failure.

The same is true of the `wordpress` container and the one-off `wp-cli` compose
service, so it doesn't matter which one an image command runs in.

## Playwright MCP — Blank Page / Hanging Screenshots Fix

If you encounter a problem with the Playwright browser causing a blank page or hanging screenshot then read the fix at `.local/DOC/FIX/PLAYWRIGHT_BLANK_PAGE_FIX.md`

## WP-CLI — "Error establishing a database connection" Fix

If running `wp` directly fails with **`Error establishing a database connection`** (often with `Undefined array key "REQUEST_URI"/"HTTP_HOST"` warnings), the CLI isn't loading the sandbox DB creds because `$_ENV` is empty. Run WP-CLI as `php -d variables_order=EGPCS /usr/local/bin/wp <command>`. Full explanation at `.local/DOC/FIX/WP_CLI_DB_CONNECTION_FIX.md`.

## Accessibility audits and reviews

Whenever you audit, review, or fix accessibility (a11y) for front-end code —
WCAG, screen readers, keyboard navigation, focus management, ARIA, semantic
HTML, color contrast, etc. — first read
`.local/DOC/audit-accessibility/SKILL.md` and follow its workflow and
checklist. It links to `reference.md` in the same folder for deeper WCAG/ARIA
detail. Note this is a WordPress/PHP project: apply the HTML/ARIA/semantics/
contrast guidance, but the React/npm-specific tooling sections generally won't
apply — audit rendered pages with Lighthouse, axe, or pa11y against
`http://wordpress/`.
