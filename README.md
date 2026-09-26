# Claude WordPress Docker Sandbox

## _A WordPress + MariaDB development sandbox that runs Claude Code in dangerous mode alongside the site, with Playwright browser automation against the live container._

[![Made with Docker](https://img.shields.io/badge/Made%20with-Docker-2496ED?logo=docker&logoColor=white)](#)
[![WordPress](https://img.shields.io/badge/WordPress-21759B?logo=wordpress&logoColor=white)](#)
[![MariaDB](https://img.shields.io/badge/MariaDB-003545?logo=mariadb&logoColor=white)](#)
[![WSL2](https://img.shields.io/badge/Platform-WSL2-0078D6?logo=windows&logoColor=white)](#)
[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](#)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=fff)](#)

This project spins up a self-contained WordPress development environment — WordPress (PHP 8.2 + Apache), MariaDB, wp-cli, and Claude Code — as a single Docker Compose stack on WSL2. Claude runs in the same compose network as the WP and DB containers, so it can hit the live site over `http://wordpress/` with Playwright, run `wp` commands, query the database, and edit your theme/plugin code — all without touching your real machine.

It is generic enough for any WordPress project but follows the Pantheon `wp-config.local.php` + `PANTHEON_ENVIRONMENT` convention, so a site cloned from Pantheon (or any host that uses the same pattern) drops in cleanly.

## Table of Contents

- [Problem](#problem)
- [Solution](#solution)
- [Layout](#layout)
- [Tech](#tech)
- [Requirements](#requirements)
- [Installation](#installation)
- [Workflow A — Drop scaffolding into an existing WP project](#workflow-a--drop-scaffolding-into-an-existing-wp-project)
- [Workflow B — Clone this repo, add WP into it](#workflow-b--clone-this-repo-add-wp-into-it)
- [site-control.sh](#site-controlsh)
- [Image processing (GD / Imagick)](#image-processing-gd--imagick)
- [Logging DB changes](#logging-db-changes)
- [Playwright and the `http://wordpress/` hostname](#playwright-and-the-httpwordpress-hostname)
- [Project-specific instructions](#project-specific-instructions)
- [Sandbox mu-plugins](#sandbox-mu-plugins)
- [Email capture (Mailpit)](#email-capture-mailpit)
- [Page cache (stale pages in the browser)](#page-cache-stale-pages-in-the-browser)
- [Login Token](#login-token)
- [VcXsrv Setup](#vcxsrv-setup)
- [Scripts](#scripts)
- [MCP Servers](#mcp-servers)
- [.env Protection](#env-protection)
- [Sessions](#sessions)
- [Multiple Projects](#multiple-projects)
- [Development](#development)
- [Disclaimer](#disclaimer)
- [License](#license)

## Problem

Two problems, one solution.

**1. Claude Code with `--dangerously-skip-permissions` is risky on your real machine.** That flag lets Claude edit files and run commands without stopping to ask. Great for letting it work uninterrupted — bad if it (or any package it pulls in) does something you didn't want. Supply-chain attacks on npm, PyPI, and Composer are real and frequent. The moment Claude installs or runs that code, it is running on your machine too [(see disclaimer)](#disclaimer).

**2. Local WordPress development is fiddly.** You want a real WP install, a real database, wp-cli, a real browser that can hit the dashboard, and ideally the ability to swap in a SQL dump from production. Setting that up by hand — and re-setting it up per project — is annoying.

This project solves both at once. Claude gets hands-off autonomy without the keys to your actual machine, and you get a clean WordPress + MariaDB + wp-cli sandbox to point it at.

## Solution

- **One compose stack with four services on a shared network:** `claude` (Node 22 + Claude Code + wp-cli + Playwright), `wordpress` (php8.2-apache on port 8080), `db` (MariaDB 11), and `mailpit` (mail catcher on port 8025). A fifth `wp-cli` service runs one-off wp commands.
- **Project root is the WordPress install.** The repo root is bind-mounted to `/var/www/html` (Apache's docroot) and `/workspace` (Claude's working dir). Editing files in your editor, on the host, or via Claude all hits the same files.
- **Claude reaches the site by hostname.** From inside the `claude` container, `http://wordpress/` resolves over the compose network to the WP container. Use that with Playwright — not `localhost:8080`.
- **wp-cli baked into the Claude image.** Claude can run `wp post list`, `wp search-replace`, `wp option get`, etc. directly, against the live DB.
- **GD and Imagick everywhere PHP runs.** Both WordPress image editors work in all three PHP environments — the Claude image installs `php-gd` + `php-imagick` for its own php-cli, and the `wp-cli` image is patched to restore the ImageMagick coders upstream leaves out — so `wp media regenerate`, `wp media import`, and plugin thumbnailing work from any of them. `.local/check-image-support.php` verifies it. See [Image processing](#image-processing-gd--imagick).
- **`site-control.sh` interactive menu** for the stuff you do outside Claude: start/stop services, generate a `wp-config.local.php`, import a SQL dump (`.sql` / `.sql.gz` / `.zip`), search-replace URLs, and create an `admin/admin` user.
- **Pantheon-friendly `wp-config.local.php` pattern.** A generated `wp-config.local.php` is gated by `PANTHEON_ENVIRONMENT=local`, which the compose file sets for the WP and wp-cli services. Your committed `wp-config.php` stays untouched on prod.
- **Mail is captured, never sent.** Every `wp_mail()` is routed over SMTP to the `mailpit` container by an auto-installed mu-plugin, so password resets and notifications are readable at [http://localhost:8025](http://localhost:8025) instead of vanishing into a PHP `mail()` with no MTA behind it — and nothing reaches a real inbox.
- **Dynamic `WP_HOME` / `WP_SITEURL`.** Derived from the request `Host` header so the site responds correctly at both `http://localhost:8080` (host browser) and `http://wordpress/` (sibling containers like Playwright) without 301-redirecting.
- **`DB_CHANGES.MD` log.** A required append-only record of every dashboard change (posts, pages, settings, plugins, themes, menus, widgets, users) so the sandbox state stays reproducible — see [.local/CLAUDE-LOCAL.md](./.local/CLAUDE-LOCAL.md) for the rule.
- **All the original sandbox protections still apply.** Claude runs with `--dangerously-skip-permissions` inside the container, Playwright MCP forwards the headed browser to your Windows desktop via VcXsrv, your OAuth login is persisted, sessions back up across rebuilds, and `.env` is locked down with hooks + deny rules.

## Layout

```
.
├── .claude/
│   ├── hooks/                      # PreToolUse hooks (deny .env reads)
│   ├── settings.json               # Hook wiring + permission deny list
│   └── settings.local.json         # Local allow list + MCP toggles
├── .local/
│   ├── CLAUDE-LOCAL.md             # The sandbox's Claude rules — imported by root CLAUDE.md
│   ├── Dockerfile                  # Claude container image (Node 22 + wp-cli + Playwright + GD/Imagick)
│   ├── Dockerfile.wp-cli           # wordpress:cli + the ImageMagick coders it ships without
│   ├── docker-compose.yml          # claude + wordpress + db + mailpit (+ wp-cli) services
│   ├── wp-mu-plugins/              # installed to wp-content/mu-plugins/local-mu-plugins/ on start
│   │   ├── 00-sandbox-mailpit.php  # routes wp_mail() to the mailpit catcher
│   │   └── 01-sandbox-page-cache.php # drops the Pantheon page-cache TTL to 0
│   ├── compose.sh                  # docker-compose wrapper that pins COMPOSE_PROJECT_NAME
│   ├── .mcp.json                   # Playwright MCP config
│   ├── start-claude-dangerously.sh
│   ├── start-claude-normal.sh
│   ├── rebuild-claude.sh
│   ├── restore-sessions.sh
│   ├── prune-playwright-mcp.sh
│   ├── site-control.sh             # Interactive menu: power, wp-config, import, search-replace, admin, sass, CLI update
│   ├── check-image-support.php     # Verifies GD + Imagick actually process images in a container
│   ├── wp-config-local.php         # Template used by site-control.sh option 3
│   ├── wp-config.local.php         # Generated copy (also serves as a working default)
│   ├── .claude-sessions/           # Session backups (created on demand)
│   └── .playwright-mcp/            # Screenshot output (auto-pruned)
├── wp-config.local.php             # Generated into project root by site-control.sh
├── .env                            # Your OAuth token — never read by Claude
├── .env.example
├── CLAUDE.md                       # Yours — a stub importing the file above, plus your site's own rules
├── DB_CHANGES.MD                   # Append-only log of dashboard changes
└── README.md
```

Everything sandbox-related lives in `.local/`. The project root is what gets bind-mounted into the containers — as `/workspace` (Claude) and `/var/www/html` (WordPress).

## Tech

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (with WSL2 integration enabled)
- [WordPress](https://hub.docker.com/_/wordpress) — `wordpress:php8.2-apache` (web) and `wordpress:cli` (one-off wp-cli)
- [MariaDB 11](https://hub.docker.com/_/mariadb)
- [Mailpit](https://mailpit.axllent.org/) — `axllent/mailpit`, SMTP sink + web UI for reading captured mail
- [Node.js 22 (bookworm-slim)](https://hub.docker.com/_/node) — Claude container base
- [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
- [WP-CLI](https://wp-cli.org/) — phar baked into the Claude image, plus the dedicated `wp-cli` compose service
- [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp) — pinned to `0.0.75` in both the image and `.mcp.json`
- [VcXsrv](https://sourceforge.net/projects/vcxsrv/) — X server for the headed browser window

## Requirements

- Windows 11 (or Windows 10) with WSL2 installed and a Linux distro available.
- Docker Desktop with **WSL integration enabled** for your distro (Settings → Resources → WSL integration).
- VcXsrv installed on the Windows side (see [VcXsrv Setup](#vcxsrv-setup)). Optional if you do not need the Playwright browser window.
- `bash`, `docker`, and standard GNU userland inside WSL.

## Installation

From a WSL shell, in the project root:

```bash
# Build the Claude image (or skip — the start scripts auto-build if missing)
( cd .local && docker compose build claude )
```

Then set up your OAuth login token (see [Login Token](#login-token)) and pick a workflow below.

## Workflow A — Drop scaffolding into an existing WP project

You already have a WordPress codebase (e.g. cloned from Pantheon or GitHub) and want to give Claude a sandboxed local environment.

1. Copy these into the root of your WP project:
   - `.local/` (whole directory)
   - `.claude/` (whole directory)
   - `CLAUDE.md` — **first time only.** After setup this file is yours to write in; re-copying it on a later update would wipe what you added. The sandbox's own rules ride along inside `.local/`, so updating `.local/` keeps them current on its own. See [Project-specific instructions](#project-specific-instructions).
   - `DB_CHANGES.MD`
   - `.env.example` → rename to `.env` and fill in your OAuth token
   - `.gitignore` entries from this repo's `.gitignore` (merge into yours)
2. Make sure your existing `wp-config.php` knows about the local override. Add this near the top, **before** `wp-settings.php` is included:
   ```php
   if (isset($_ENV['PANTHEON_ENVIRONMENT']) && $_ENV['PANTHEON_ENVIRONMENT'] === 'local') {
     require_once(dirname(__FILE__) . '/wp-config.local.php');
     return;
   }
   ```
3. Run `./.local/site-control.sh`:
   - **Option 1** — Power on (starts db + wordpress).
   - **Option 3** — Generate `wp-config.local.php` in the project root (sandbox DB creds, dynamic `WP_HOME`).
   - **Option 4** — Import your SQL dump (drop a `.sql` / `.sql.gz` / `.zip` in the project root first).
   - **Option 5** — Search-replace your prod URL to `http://localhost:8080`.
   - **Option 6** — Create/refresh an `admin/admin` user.
4. Visit [http://localhost:8080](http://localhost:8080). Log in as `admin/admin`.
5. Launch Claude with `./.local/start-claude-dangerously.sh`.

## Workflow B — Clone this repo, add WP into it

You want a fresh sandbox to drop a WordPress codebase into.

1. `git clone https://github.com/joelachankeng/Claude-WordPress-Docker-Sandbox.git my-wp-sandbox && cd my-wp-sandbox`
2. Copy your WordPress files into the project root (they sit alongside `.local/`, `.claude/`, etc.). For a brand-new site, the `wordpress:php8.2-apache` image will auto-populate WP core on first boot if the docroot is empty — so an empty project root works too.
3. `cp .env.example .env` and fill in your OAuth token.
4. Run `./.local/site-control.sh` and follow the same options as Workflow A starting at step 3.
5. Visit [http://localhost:8080](http://localhost:8080).
6. Launch Claude with `./.local/start-claude-dangerously.sh`.

In both workflows the project root is the WordPress docroot — your theme lives at `wp-content/themes/<yours>/`, your plugins at `wp-content/plugins/`, etc.

## site-control.sh

`./.local/site-control.sh` is the interactive control panel for the WP side of the sandbox. Run it from a WSL shell — it prints a status header and a menu:

```
  1) Power on  (start db + wordpress)
  2) Power off (stop all services)
  3) Generate wp-config.local.php
  4) Import database from SQL file
  5) Search-replace database URLs (single site)
  6) Search-replace database URLs (multisite/network)
  7) Create/refresh sandbox admin user
  8) Compile SASS
  9) Watch SASS (Ctrl+C to stop)
 10) Update Claude CLI (rebuild image with the latest release)
  q) Quit
```

- **Power on/off** — `docker compose up -d db wordpress` / `docker compose down` against the pinned project name.
- **Generate `wp-config.local.php`** — renders `.local/wp-config-local.php` (a template) into the project root with sandbox DB creds (`db/db/db@db`) and a `WP_HOME` that auto-derives from `$_SERVER['HTTP_HOST']`. Includes a `#.local-generated` marker so future runs warn before overwriting a hand-edited copy.
- **Import a SQL dump** — lists every `*.sql` / `*.sql.gz` / `*.gz` / `*.zip` in the project root, drops + recreates the `db` database, and pipes the dump into MariaDB. Useful for pulling a prod export down.
- **Search-replace URLs** — runs `wp search-replace` across all tables (skipping `guid`) via the `wp-cli` compose service. Auto-detects the current `siteurl`, defaults the new value to `http://localhost:8080`. Retries on db connection failure so you can fix `wp-config.php` and continue.
- **Search-replace URLs (multisite)** — delegates to `.local/search-replace-multisite.sh`, which boots wp-cli against the old host still in the DB and also rewrites the protocol-less domain columns in `wp_blogs` / `wp_site` / `wp_sitemeta`. Use this instead of option 5 for a network install.
- **Create/refresh admin user** — creates `admin/admin/admin@admin.com` as an administrator via wp-cli, with a direct-SQL fallback (MD5 password; WP rehashes on next login) if wp-cli can't connect.
- **Compile / watch SASS** — runs `.sass/sass.sh` inside the sandbox (the image bakes in Dart Sass, PostCSS, and Autoprefixer). Requires the stack to be powered on.
- **Update Claude CLI** — reads the version currently baked into `claude-dangerous:<project>`, asks the npm registry for the latest `@anthropic-ai/claude-code`, and rebuilds the image pinned to it. The Dockerfile installs the CLI in its own final layer with a `CLAUDE_CODE_VERSION` build arg, so only that layer is invalidated — the apt and Chrome layers stay cached and the rebuild takes seconds. A Claude session that is already running keeps the old version until it exits; restart with `start-claude-dangerously.sh` to pick up the new one.

The DB defaults wired into both compose and this script are `db_name=db`, `db_user=db`, `db_password=db`, `db_root_password=root`. They're sandbox-only — don't reuse them.

## Image processing (GD / Imagick)

WordPress needs one of two PHP extensions to resize anything — Imagick (preferred) or GD (fallback). Both are available in the containers you actually work in:

| Container / image | GD | Imagick |
| --- | --- | --- |
| `wordpress` (`wordpress:php8.2-apache`) | ✅ | ✅ |
| `claude` (built from `.local/Dockerfile`) | ✅ `php-gd` | ✅ `php-imagick` |
| `wp-cli` (built from `.local/Dockerfile.wp-cli`) | ✅ | ✅ |

So `wp media regenerate`, `wp media import`, thumbnail generation, and plugins that resize images all work — from the site itself, from `wp` inside the Claude container, and from the one-off `wp-cli` service.

To verify, run the checker in whichever container you care about:

```bash
# Claude container
php .local/check-image-support.php

# wordpress container (it masks /var/www/html/.local, so copy the file in)
WP=$(./.local/compose.sh ps -q wordpress)
docker cp .local/check-image-support.php "$WP:/tmp/" && docker exec "$WP" php /tmp/check-image-support.php
```

It doesn't just check `extension_loaded()` — a loaded extension with no JPEG delegate still can't resize a media library. Each backend is made to round-trip a real image (create → encode → decode → resize), the reported delegates are checked, and it finishes by asking which editor WordPress itself would choose. Exit code is non-zero if anything fails.

**Why `wp-cli` is built rather than pulled.** The upstream `wordpress:cli` image installs `imagemagick-libs` but not `imagemagick`, the package that carries the coder modules. Imagick loads and reports a version, but `Imagick::queryFormats()` returns an empty array — it can't read or write a single format. WordPress notices and silently falls back to GD, so nothing visibly breaks, which is what makes it easy to miss. `.local/Dockerfile.wp-cli` is a three-line layer on top of the upstream image that installs the missing package, restoring the full ~200-format delegate set. Compose builds it automatically the first time the service runs.

## Logging DB changes

The sandbox rules require every change made through the WordPress dashboard (posts, pages, settings, plugins, themes, menus, widgets, users) to be appended to `DB_CHANGES.MD` in chronological order. Entries follow the format already in the file:

```
## YYYY-MM-DD HH:MM — Short summary
- **Area:** Posts | Pages | Settings | Plugins | Themes | Menus | Widgets | Users
- **Change:** what was added/edited/deleted
- **Details:** object IDs, titles, slugs, option names
```

This is how the sandbox state stays reproducible after a `rebuild-claude.sh` or a fresh import — you can read the log to see what was done.

## Playwright and the `http://wordpress/` hostname

Inside the Claude container, **always navigate to `http://wordpress/`** — not `http://localhost:8080/`. From within a sibling container, `localhost` refers to that container itself, not the host. The `wordpress` hostname resolves over the compose network straight to the WP container.

`wp-config.local.php` is wired so the site responds correctly at both URLs without 301-redirecting, by deriving `WP_HOME` from the request `Host` header at runtime. This is why both `http://localhost:8080` (your host browser) and `http://wordpress/` (Playwright inside the Claude container) work without conflict.

The rule is in `.local/CLAUDE-LOCAL.md` so Claude follows it without being reminded.

## Project-specific instructions

This scaffolding is cloned across many sites, and updating it means re-copying `.local/` wholesale. If the sandbox's own rules lived in `CLAUDE.md`, every site that added notes to that file would lose them on the next update.

So the sandbox's rules do not live there. They live in `.local/CLAUDE-LOCAL.md`, and `CLAUDE.md` is reduced to a stub that imports them:

```markdown
# CLAUDE.md

<!-- THIS IS REQUIRED FOR THE SANDBOX TO WORK PROPERLY --->
## Claude Docker Sandbox Instructions
@.local/CLAUDE-LOCAL.md
<!-- DO NOT REMOVE ABOVE!!! --->
```

`@path` is Claude Code's import syntax: the referenced file is inlined where the line appears, so Claude loads the sandbox rules exactly as if they were pasted into `CLAUDE.md`.

| File | Belongs to | On update |
|---|---|---|
| `.local/CLAUDE-LOCAL.md` | the scaffolding | **replaced** along with the rest of `.local/` |
| `CLAUDE.md` | your site | **untouched** — write whatever you like below the stub |

- **`CLAUDE.md` is yours now.** Add your site's conventions, gotchas, and theme layout straight into it, underneath the import. Nothing in the update path rewrites it.
- **Keep the stub.** Delete the `@.local/CLAUDE-LOCAL.md` line and Claude loses every sandbox rule at once — the `.env` prohibition, the `http://wordpress/` hostname, the `DB_CHANGES.MD` requirement.
- **Your rules are read after the sandbox's,** since the import sits above them.
- **Imports nest** up to five levels, so you can `@`-import per-area notes (a theme conventions file, say) once `CLAUDE.md` gets long.

Run `/memory` inside Claude Code to see exactly which files were loaded, imports included.

## Sandbox mu-plugins

Two behaviours the sandbox needs are supplied as must-use plugins: the Mailpit router and the page-cache override. Both live in `.local/wp-mu-plugins/`, and `.local/wp-entrypoint.sh` installs them on every container start.

They are installed into their own subdirectory so the sandbox's files never mingle with the project's — on a Pantheon site, `wp-content/mu-plugins/` already contains `loader.php` and `pantheon-mu-plugin/`:

```
wp-content/mu-plugins/
├── 00-local-mu-plugins.php     # generated stub — loads the folder below
├── local-mu-plugins/           # generated; edit the sources in .local/wp-mu-plugins/
│   ├── 00-sandbox-mailpit.php
│   └── 01-sandbox-page-cache.php
├── loader.php                  # your project's
└── pantheon-mu-plugin/         # your project's
```

- **The stub is required, not decorative.** WordPress does not recurse into mu-plugin subdirectories — `wp_get_mu_plugins()` (`wp-includes/load.php`) `readdir()`s `wp-content/mu-plugins` and takes only the `*.php` sitting directly in it. Without `00-local-mu-plugins.php` the subfolder is inert. Its `00-` prefix also puts it ahead of Pantheon's `loader.php`, which the page-cache filter depends on.
- **Real files, not bind mounts.** The `wp-cli` and `claude` containers share the docroot but not the entrypoint, so copying the files in is what makes all three containers behave alike.
- **Generated, so git-ignored.** Both the stub and `local-mu-plugins/` are rewritten on every start — edit the sources in `.local/wp-mu-plugins/`, never the installed copies.
- **Self-cleaning.** Copies whose source has been renamed or deleted are removed, as are top-level leftovers from the pre-subdirectory layout. Deletion only ever touches files carrying the `#.local-generated` marker, so a project file that happens to match the naming pattern is left alone.

## Email capture (Mailpit)

The `wordpress:php8.2-apache` image has no MTA behind PHP's `mail()`, so out of the box every password reset, new-user notice, and contact-form submission is silently dropped. The `mailpit` service fixes that: it is an SMTP sink with a web UI, so mail is captured and readable, and nothing can reach a real inbox from the sandbox.

- **Read your mail** at [http://localhost:8025](http://localhost:8025) from the host browser, or `http://mailpit:8025` from inside a sibling container (Claude, Playwright) — same hostname rule as `http://wordpress/`.
- **JSON API** for scripted checks — handy for Claude, which can pull a reset link straight out of a message body:
  ```bash
  curl -s http://mailpit:8025/api/v1/messages         # list, newest first
  curl -s http://mailpit:8025/api/v1/message/<ID>     # one message (.Text / .HTML)
  curl -s -X DELETE http://mailpit:8025/api/v1/messages   # empty the mailbox
  ```
- **How the routing works.** `00-sandbox-mailpit.php` hooks `phpmailer_init` and points PHPMailer at `mailpit:1025` over plain SMTP. It is installed as a real file rather than a bind mount so the `wp-cli` and `claude` containers — which share the docroot but not the entrypoint — route mail the same way. See [Sandbox mu-plugins](#sandbox-mu-plugins) for how it gets there.
- **It cannot leak into production.** The mu-plugin returns immediately unless `PANTHEON_ENVIRONMENT=local`, which only the sandbox services set.
- **It also fixes the `wordpress@localhost` From address.** WordPress derives that from a `localhost` site URL, and PHPMailer rejects it over SMTP (no dot in the domain), which would make every `wp_mail()` return `false`. The mu-plugin substitutes `wordpress@sandbox.local` when — and only when — the derived address is invalid.
- **Storage is in-memory,** capped at 500 messages. Stopping the container discards the mailbox.

If port 8025 is unavailable on your machine (see the note in [Multiple Projects](#multiple-projects)), override it:

```bash
MAILPIT_PORT=8225 ./.local/compose.sh up -d db mailpit wordpress
```

## Page cache (stale pages in the browser)

This one only bites on projects that vendor Pantheon's mu-plugin into `wp-content/mu-plugins/` — a plain WordPress install never sends the header, so if your site is not a Pantheon site, `01-sandbox-page-cache.php` registers a filter nothing ever calls and you can ignore this section.

`pantheon-mu-plugin` sends `cache-control: public, max-age=604800` on HTML. On Pantheon that is correct: their edge cache honours it and is purged whenever content changes. The sandbox has no purge layer, so the header lands in **your browser's** cache and stays there for a week. You edit a template, reload, and get the old page with nothing to indicate why. It outlives theme renames and asset moves, so it also serves 404s for files at paths the site abandoned days ago.

`.local/wp-mu-plugins/01-sandbox-page-cache.php` filters `pantheon_cache_default_max_age` to `0`. Load order is load-bearing: the generated stub that pulls it in is named `00-local-mu-plugins.php`, so it runs before Pantheon's `loader.php` constructs `Pantheon_Cache`. See [Sandbox mu-plugins](#sandbox-mu-plugins).

- **`max-age=0` rather than `no-store`.** The response stays cacheable but is immediately stale, so the browser revalidates instead of refusing to store anything — you keep conditional-request efficiency and never see frozen markup.
- **It cannot slow production down.** Two independent barriers: the file returns early unless `PANTHEON_ENVIRONMENT=local`, which only the sandbox services set; and Pantheon itself clamps any sub-60-second TTL back up to 60 when that variable is `live`.
- **Pages you already visited stay stuck.** They were cached under the old week-long header, and a response already in the cache is not revisited until it expires. One hard refresh (<kbd>Ctrl/Cmd</kbd>+<kbd>Shift</kbd>+<kbd>R</kbd>) per affected URL clears it; after that they behave normally.

## Login Token

Every time the container starts, Claude asks you to log in. To stop that for good, set up a long-lived login token once. (Its proper name is an OAuth token — "long-lived" just means it does not expire when the session ends.)

There is a trap in the middle of this, so follow the steps in order:

1. Run the token setup command from the project root:

   ```bash
   ( cd .local && docker compose run --rm claude claude setup-token )
   ```

2. The terminal prints a URL. Open it in a browser — click it, or copy and paste it.

3. Log in and approve. The browser then shows you a code. **This code is _not_ your long-lived token** — it is a short-lived browser code for the next step.

4. Go back to the terminal, paste in that browser code, and press Enter.

5. Claude exchanges the code and prints your real long-lived token. **It starts with `sk-ant-oat01-`.** If what you have does not start with `sk-ant-`, it is almost certainly the browser code from step 3 — not the token. Run the command again and watch for the `sk-ant-oat01-` line at the very end.

6. Copy `.env.example` to `.env`.

7. Open `.env` and set `CLAUDE_CODE_OAUTH_TOKEN` to the `sk-ant-oat01-` token from step 5.

8. Run `./.local/start-claude-dangerously.sh` (or `start-claude-normal.sh`) to launch Claude in the container. Claude should not prompt you to log in.

9. If Claude still asks you to log in after step 8, the container is probably holding stale credentials from an earlier attempt — an old `.claude` folder and session files cached inside its volume. Run `./.local/rebuild-claude.sh` to wipe the volume and rebuild clean, then repeat step 8.

## VcXsrv Setup

VcXsrv is the X server that lets the container draw the Playwright browser window on your Windows desktop. Without it, Claude still runs and Playwright still works headlessly against `http://wordpress/` — you just will not see the browser.

Install it on the Windows side with [winget](https://learn.microsoft.com/windows/package-manager/winget/) (run from PowerShell or Command Prompt, not WSL):

```
winget install --id marha.VcXsrv -e --accept-package-agreements --accept-source-agreements
```

Then configure it:

- Launch **XLaunch** from the Start menu.
- **Display settings:** choose _Multiple windows_, leave the display number at `0`, click Next.
- **Client startup:** choose _Start no client_, click Next.
- **Extra settings:** check _Disable access control_ — this is required, or the container cannot connect. Click Next.
- Click _Save configuration_ to keep an `.xlaunch` file you can double-click next time, then Finish.
- When Windows Firewall asks, allow VcXsrv on Private networks.

The container reaches VcXsrv via `DISPLAY=host.docker.internal:0.0`, wired up through `--add-host=host.docker.internal:host-gateway` in the start scripts. VcXsrv must be running before you start Claude.

## Scripts

All scripts live in `.local/` and are run from a WSL shell. They derive the Compose project name from the parent directory, so each cloned copy gets its own isolated containers, volumes, and network.

- **`start-claude-dangerously.sh`** — Launches Claude with `--dangerously-skip-permissions`, joins the project's compose network (so `db` and `wordpress` are reachable by hostname), auto-builds the image if missing, and prunes the Playwright screenshot dir first.
- **`start-claude-normal.sh`** — Same as above but in normal mode, where Claude asks for approval before edits or shell commands.
- **`rebuild-claude.sh`** — Deletes this project's `claude` container, the `claude-config` + `claude-cache` volumes, and the `claude-dangerous:latest` image, then rebuilds from scratch with `--no-cache`. Asks for confirmation, offers to back up your sessions to `.local/.claude-sessions/`, and pauses for you to verify that backup (opens the folder in Explorer) before anything is deleted. Auto-starts Docker Desktop from WSL if it is not running. Use it for a clean slate when something breaks. **Does not** touch the `wp-db` volume — your DB survives.
- **`restore-sessions.sh`** — Copies sessions saved in `.local/.claude-sessions/` back into the container volume and puts a resume prompt on your Windows clipboard via `clip.exe`. See [Sessions](#sessions).
- **`prune-playwright-mcp.sh`** — Housekeeping for `.local/.playwright-mcp/`: deletes screenshots older than 7 days, then caps the total at 100 files. The start scripts run this automatically; you can run it manually too.
- **`compose.sh`** — Thin `docker compose` wrapper that exports the same per-project `COMPOSE_PROJECT_NAME` the start scripts use, so any compose op (`up`, `down`, `logs`, `ps`, `exec`) hits the same containers and network. Example: `./.local/compose.sh logs -f wordpress`.
- **`site-control.sh`** — Interactive WP control panel; see [site-control.sh](#site-controlsh).

To start Claude without a script, from the project root: `( cd .local && docker compose run --rm claude )` for dangerous mode (the compose `command:` includes the flag), or `( cd .local && docker compose run --rm claude claude )` for normal mode. Note that doing it this way will _not_ load `.mcp.json` — the start scripts pass it explicitly with `--mcp-config`.

## MCP Servers

Playwright MCP is configured in `.local/.mcp.json` and passed to Claude via `--mcp-config /workspace/.local/.mcp.json` by the start scripts. The pinned version (`0.0.75`) is mirrored in `.local/Dockerfile` so the image bakes in matching browser binaries and `npx -y` does not need to fetch them at runtime.

Screenshots default to `/workspace/.local/.playwright-mcp/` (the `--output-dir` flag in `.mcp.json`). `.local/CLAUDE-LOCAL.md` instructs Claude to set `filename` to that same path when calling `browser_take_screenshot`, so screenshots never land in the workspace root. The directory is auto-pruned on each start.

## .env Protection

Because `.env` holds your long-lived Anthropic token, it gets layered protection:

- **`.local/CLAUDE-LOCAL.md`** — a hard rule telling Claude to never read or transmit `.env` (or any backup like `.env.bak`, `.env.local`, `.env.testbackup`), loaded via the `@` import in `CLAUDE.md`.
- **`.claude/settings.json`** — a `permissions.deny` list that blocks the Read tool against `.env` / `**/.env.*`, plus a long set of `Bash(<tool> *.env*)` patterns for `cat`, `grep`, `sed`, `cp`, `mv`, `tar`, `zip`, etc.
- **`.claude/hooks/deny-env-reads.sh`** and **`deny-env-reads.ps1`** — PreToolUse hooks (one for each interpreter; the missing one no-ops) that inspect every Bash command's full text and deny anything referencing `.env` or `.env.<ext>` other than `.env.example`. Hook failures fail open so a broken hook can't lock you out.
- **`_hook_tests.sh`** in the same folder is a small developer harness that runs the bash hook against a handful of expected-block / expected-allow inputs.

`.env.example` is always allowed — it contains variable names but no secrets.

## Sessions

Your conversations are stored inside the container's `<project>_claude-config` volume, so they survive a normal restart. But `rebuild-claude.sh` deletes that volume — which would wipe your history. This feature keeps it safe across a rebuild.

- **Back up** — `rebuild-claude.sh` offers to copy your sessions out of the container into `.local/.claude-sessions/` before deleting anything, opens the folder in Explorer, and waits for you to confirm the backup looks right.
- **Restore** — `restore-sessions.sh` copies `.local/.claude-sessions/` back into the container's volume.
- **Resume** — Claude's built-in `--resume` may not list a restored session. So `restore-sessions.sh` also copies a ready-made prompt to your Windows clipboard via `clip.exe`: start Claude, paste it in, and Claude reads the old transcript and continues from where you left off.

`.local/.claude-sessions/` is git-ignored — transcripts contain your conversation content.

## Multiple Projects

The start, rebuild, restore, and `compose.sh` scripts compute a per-project `COMPOSE_PROJECT_NAME` from the parent directory name (`<dirname>-claude`). That means you can clone or copy this whole folder into any number of WordPress projects and each one gets:

- its own `claude`, `wordpress`, and `db` containers,
- its own `claude-config`, `claude-cache`, and `wp-db` volumes (so each project has an independent DB),
- its own compose network (`http://wordpress/` from inside that project's Claude container only ever hits that project's WP container),
- its own session backup at `.local/.claude-sessions/`.

The Docker image (`claude-dangerous:latest`) is shared across all of them — only volumes and containers are per-project. Note that the published ports are _not_ per-project: `8080` (WordPress) and `8025` (Mailpit) are fixed, so two sandboxes can't run those services at the same time. Mailpit's host port can be moved with `MAILPIT_PORT=<port>`; WordPress's needs an edit to `docker-compose.yml`.

**If a port refuses to bind on Windows** with `An attempt was made to access a socket in a way forbidden by its access permissions`, Hyper-V has reserved that range for dynamic use — it commonly swallows 8080 and 8025. Check with `netsh interface ipv4 show excludedportrange protocol=tcp` in an elevated prompt, then either release the ranges (`net stop winnat` && `net start winnat`) or reserve the port for yourself so Hyper-V stops taking it:

```
netsh int ipv4 add excludedportrange protocol=tcp startport=8080 numberofports=1 store=persistent
```

## Development

Want to contribute? Great!

Fork it, edit the `Dockerfile`, compose file, or scripts in `.local/`, and send a PR — or just send me a message.

## Disclaimer

This is a personal project. It reduces risk — it does not eliminate it. Use it with a clear understanding of what the container does and does not protect.

**Supply-chain risk is real.** Packages from registries like npm, PyPI, and Composer/Packagist do get compromised, through maintainer account takeovers, typosquatting, and malicious updates. An npm `postinstall` script runs arbitrary code the moment a package is installed — before the project is ever run. WordPress plugins and themes pulled from arbitrary sources are no safer. The Problem section is not an exaggeration.

**A container reduces the blast radius — it does not "prevent" everything.** Phrases in this README like "walled off" and "an exploit cannot reach my system" describe the goal, not an absolute guarantee.

What the container protects:

- Malicious code cannot see or touch the rest of your machine — other folders, other projects, your Windows user profile, SSH keys, saved browser passwords. It only sees the container.
- On Windows, Docker Desktop runs the container inside a WSL2 virtual machine, so there is a VM boundary as well, not just a container boundary.
- The container is disposable. `rebuild-claude.sh` destroys and recreates it.

What the container does not protect:

- **The mounted project folder is fully exposed.** The project directory is bind-mounted into the container with read and write access. Malicious code can read, change, encrypt, or steal anything in the project you mount — including your WordPress files, themes, plugins, and any uploaded media in `wp-content/uploads/`. The container protects everything except the folder you point it at.
- **The sandbox database is reachable from the Claude container.** `db` is on the compose network with default sandbox credentials. Anything running in the `claude` container can read or wipe the WP database. Don't put real production data in it without thinking about that.
- **Outbound internet is open.** Malicious code can send data to a remote server. The container does not firewall outbound traffic, and Claude, wp-cli, WordPress, and Playwright all need internet to function.
- **Your Anthropic token is reachable.** `CLAUDE_CODE_OAUTH_TOKEN` lives in the container environment, and `.env` sits in the mounted project folder. The `.env` protections above stop _Claude_ from reading it, but any other process the container ends up running can still see it. To eliminate that, remove the token from `.env` and log in interactively instead.
- **Container escape is possible.** It is rare, but a container is not as strong a security boundary as a full virtual machine.

The accurate mental model: anything that goes wrong is confined to the container, the project folder mounted into it, and the sandbox database — and kept away from the rest of your system. That is a large and worthwhile reduction in risk — but the project folder, the sandbox DB, and the injected token are inside the blast zone, and nothing here is a guarantee. Use it at your own risk.

## License

MIT

**Free Software, Hell Yeah!**
