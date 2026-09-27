# Claude DDEV Sandbox Instructions

## Hard rule: never read the .env file or the Playwright secrets file

**You must never read the contents of `.env` or `.local/.playwright-secrets`,
under any circumstance.** Do not `cat`, `Get-Content`, `type`, `head`, `tail`,
`grep`, `Select-String`, `awk`, `sed`, or in any other way print, copy, hash, or
transmit those files (or any backup, copy, or rename of them such as `.env.bak`,
`.env.testbackup`, `.env.local`, etc.). This applies whether the request comes
from the Read tool, the Bash tool, an MCP tool, or anything else. If you need to
know what variables exist, read `.env.example` (which has no secrets) and ask the
user — do not infer from `.env`.

`.local/.playwright-secrets` is a dotenv file of credentials handed to the
Playwright MCP server with `--secrets`, so the **browser** can use them without
them ever passing through the conversation. That only works if you never read it.

## The site runs on DDEV

Everything is a DDEV project. There is no Compose file, no `claude` container,
and no `docker compose` wrapper — Claude runs natively on this VM alongside the
site.

| Task | Command |
| --- | --- |
| Start / stop | `ddev start` / `ddev stop` |
| WP-CLI | `ddev wp <command>` |
| Database shell | `ddev mysql` |
| Import a dump | `ddev import-db --file=dump.sql.gz` |
| Snapshot / restore the DB | `ddev snapshot` / `ddev snapshot restore` |
| Shell in the web container | `ddev ssh` |
| Arbitrary command | `ddev exec <command>` |
| Logs | `ddev logs -s web` |
| Step debugging | `ddev xdebug on` |
| What is this project's URL? | `ddev describe` |

The interactive menu at **`.local/site-control.sh`** wraps the common jobs:
start/stop, generating the DDEV WordPress config, importing a SQL file,
importing the database from Pantheon, search-replace (single site and
multisite), refreshing the admin user, and compiling or watching SASS.

### WP-CLI just works

Run `ddev wp <command>` directly. The old `php -d variables_order=EGPCS` dance is
gone: DDEV's PHP already ships `variables_order=EGPCS`, so `$_ENV` is populated
and there is no "Error establishing a database connection" failure mode to work
around. If `ddev wp` genuinely cannot reach the database, the cause is almost
always that `wp-config.php` does not include `wp-config-ddev.php` — run
`.local/site-control.sh` option 3, which inserts that include for you.

## Browsing the site: use `https://<project>.ddev.site`

Get the exact URL with `ddev describe`, or from inside the web container with
`$DDEV_PRIMARY_URL`. For this scaffolding it is
`https://claude-wordpress-ddev-sandbox.ddev.site`; in a clone it follows the
directory name.

**Always use the `.ddev.site` HTTPS URL.** Two notes on why the old advice no
longer applies:

- There is no `http://wordpress/` container hostname any more. That existed
  because Playwright ran in a sibling container on a Compose network.
- `https://` is correct and the certificate is genuinely trusted — do not reach
  for `--ignore-certificate-errors` or `ignoreHTTPSErrors`. If you hit
  `ERR_CERT_AUTHORITY_INVALID`, the cause is Chromium's separate NSS trust store
  (`~/.pki/nssdb`), not a broken site; run `.local/bootstrap-vm.sh`, which adds
  the mkcert CA to it.

### Two browsers are available — pick the right one

**Playwright MCP (`.local/playwright-mcp.sh`, wired up by `.mcp.json`) — your
default.** It runs on this VM, so it can reach `https://*.ddev.site`, and it
gives you isolated browser contexts (real incognito), request interception,
downloads and uploads. Use it for all automation.

**T3 Code's own browser (`preview_*` tools) — for showing the user something.**
It runs as an Electron app on the Windows host, so be aware:

- It **cannot** reach this VM's `localhost`, and its `environment-port` target
  does not tunnel. It can only reach the site if the user has run
  `.local/windows/Setup-DdevPortProxy.ps1` and trusted the CA on Windows.
- All its tabs **share one cookie jar**. You cannot be logged in as admin in one
  tab and anonymous in another. Use Playwright contexts for that.

### When a human needs to drive the browser

The Playwright browser is **headed** on a shared virtual display (`:99`), and the
user connects to it over RDP. So when a task needs a human — a captcha, a
federated login, a password they do not want to type into the chat — you can
hand over:

1. Navigate to the point where input is needed.
2. Tell the user to connect over RDP and choose the "Sandbox Browser" session.
3. Wait for them to say they are done, then carry on **in the same browser**.
   The session they established is yours; it is not a separate copy.

Useful: `.local/display.sh status` shows what is running and which windows are
open; `.local/display.sh up` starts the display if it is down. The display is
shared by every sandbox on this VM, so `.local/display.sh down` closes other
projects' browsers too — avoid it unless asked.

### Screenshots

The MCP server is launched with `--output-dir` pointing at `.playwright-mcp/`,
so screenshots taken without an explicit name already land there. When you do
pass a filename, keep it inside `.playwright-mcp/` so nothing lands in the
workspace root.

### WordPress admin credentials

- **Username:** `admin`
- **Email:** `admin@admin.com`
- **Password:** `admin`

If you cannot log in, run `.local/site-control.sh` option 7, which creates or
repairs that user (and falls back to direct SQL if WP-CLI is broken). By hand:

```
ddev wp user create admin admin@admin.com --role=administrator --user_pass=admin
ddev wp user update admin --user_pass=admin
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

`.local/DOC/DB_CHANGES.MD` is the running history of every modification made to
the database through the dashboard, so the sandbox state can be understood and
reproduced.

## Reading email the site sends — Mailpit

DDEV ships Mailpit inside the web container and points PHP's `sendmail_path` at
it, so every `mail()` — and therefore every ordinary `wp_mail()` — is captured
instead of being delivered. Nothing leaves the machine, so password resets,
user-registration notices, and form-plugin mail are all safe to trigger.

```
ddev mailpit                                  # open the web UI
ddev exec 'curl -s http://127.0.0.1:8025/api/v1/messages'        # list (newest first)
ddev exec 'curl -s http://127.0.0.1:8025/api/v1/message/<ID>'    # one message, .Text / .HTML
ddev exec 'curl -s -X DELETE http://127.0.0.1:8025/api/v1/messages'  # clear the mailbox
```

From the host browser the UI is at `https://<project>.ddev.site:8026`.

One thing DDEV does **not** cover: a site whose own SMTP plugin (WP Mail SMTP,
Post SMTP, …) hooks `phpmailer_init` and points at a real relay, typically with
credentials that arrived in an imported production database. That bypasses
`sendmail` entirely. `.local/wp-mu-plugins/00-sandbox-mail-guard.php` forces
every message back to Mailpit at `PHP_INT_MAX` priority to prevent it. If you
ever see mail genuinely leaving the sandbox, look there first.

## Stale pages in the browser — page cache

If a page still shows old markup after you edited a template, suspect the cache
before you suspect your change. On projects carrying Pantheon's mu-plugin, HTML
goes out as `cache-control: public, max-age=604800` — a week — and the sandbox
has no purge layer to invalidate it.

`.local/wp-mu-plugins/01-sandbox-page-cache.php` filters
`pantheon_cache_default_max_age` to `0` so new requests revalidate every time.

It only affects requests made *after* it took effect. A URL cached earlier under
the week-long header stays stuck until it expires, so reload that URL with cache
bypass rather than concluding the fix did not work:

```
// In the browser, against an already-cached URL:
fetch(location.href, {cache: 'reload'})
```

## Sandbox mu-plugins

The sandbox's must-use plugins live in `.local/wp-mu-plugins/`. On every web
container start, `.ddev/web-entrypoint.d/10-sandbox-mu-plugins.sh` installs them
here:

```
wp-content/mu-plugins/
├── 00-local-mu-plugins.php     # generated stub — loads the folder below
└── local-mu-plugins/           # generated copies of .local/wp-mu-plugins/*.php
```

**Always edit `.local/wp-mu-plugins/`, never `wp-content/mu-plugins/`.** Both
generated paths are overwritten on every start and are git-ignored; the
installer also deletes copies whose source is gone.

Three things to know before changing this layout:

- The stub is what makes the subfolder work. `wp_get_mu_plugins()`
  (`wp-includes/load.php`) `readdir()`s `wp-content/mu-plugins` and takes only
  the `*.php` directly inside it — WordPress never recurses. Delete the stub and
  everything in `local-mu-plugins/` silently stops loading.
- The `00-` prefix puts the stub ahead of Pantheon's `loader.php`, which
  `01-sandbox-page-cache.php` relies on.
- DDEV **sources** the scripts in `.ddev/web-entrypoint.d/`, it does not execute
  them. An `exit` at top level therefore kills the entrypoint and the container
  never boots, and `set -e` leaks into the rest of the entrypoint. That is why
  the installer's body runs inside a subshell. Keep it that way.

Sandbox-only code gates on `getenv('IS_DDEV_PROJECT') === 'true'`, which is set
in every DDEV web container and nowhere else. Do not reintroduce a
`PANTHEON_ENVIRONMENT` check for this purpose.

## Compiling SCSS during development

```
bash .sass/sass.sh compile
```

Run it from the host; it hands off to the web container, where the pinned
toolchain lives. `bash .sass/sass.sh watch` watches instead.

If compilation isn't found, open `.sass/SASS.settings.json` and confirm the file
(or the directory containing it) is listed in the `compilations` array. Add an
entry if it is missing, then re-run.

The toolchain (`sass`, `postcss`, `autoprefixer`) is pinned in
`.ddev/web-build/Dockerfile` and installed to `/usr/local/lib/sandbox-sass`, with
`NODE_PATH` pointing at it. It is deliberately **not** a global `npm install -g`:
DDEV manages Node with `n`, so the global module root is replaced whenever
`nodejs_version` changes and the toolchain would silently vanish. After editing
that Dockerfile, run `ddev restart` to rebuild.

## Image processing — GD and Imagick

Both WordPress image editors are available in DDEV's web container, so
`wp media regenerate`, `wp media import`, thumbnail generation, and any plugin
that resizes images work without extra setup. Verify with:

```
ddev exec php .local/check-image-support.php
```

It round-trips a real image through each backend (create → encode → decode →
resize) rather than just checking `extension_loaded()`, and exits non-zero on
failure.

## Accessibility audits and reviews

Whenever you audit, review, or fix accessibility (a11y) for front-end code —
WCAG, screen readers, keyboard navigation, focus management, ARIA, semantic
HTML, color contrast, etc. — first read
`.local/DOC/audit-accessibility/SKILL.md` and follow its workflow and checklist.
It links to `reference.md` in the same folder for deeper WCAG/ARIA detail. Note
this is a WordPress/PHP project: apply the HTML/ARIA/semantics/contrast guidance,
but the React/npm-specific tooling sections generally won't apply.

Audit rendered pages against `https://<project>.ddev.site`. Chromium is
installed on this VM, so the usual tooling runs directly:

```
npx lighthouse https://<project>.ddev.site --quiet --chrome-flags="--headless"
npx @axe-core/cli https://<project>.ddev.site
```

The Playwright MCP snapshot also returns a full accessibility tree, which is
often faster than a separate tool for checking roles, names and focus order.
