# Claude WordPress DDEV Sandbox

## _A WordPress development sandbox built on DDEV, with a Playwright browser you can watch and take over from, for Claude Code to work against._

[![Made with DDEV](https://img.shields.io/badge/Made%20with-DDEV-02A8E2?logo=ddev&logoColor=white)](#)
[![WordPress](https://img.shields.io/badge/WordPress-21759B?logo=wordpress&logoColor=white)](#)
[![MariaDB](https://img.shields.io/badge/MariaDB-003545?logo=mariadb&logoColor=white)](#)
[![Playwright](https://img.shields.io/badge/Playwright-2EAD33?logo=playwright&logoColor=white)](#)
[![Claude](https://img.shields.io/badge/Claude-D97757?logo=claude&logoColor=fff)](#)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=fff)](#)

This project turns any WordPress codebase into a DDEV sandbox that Claude Code can
work in: WordPress on nginx with PHP 8.2, MariaDB, WP-CLI, Mailpit, and a real
Chromium that Claude drives with Playwright — and that **you** can connect to over
RDP whenever a human needs to take the wheel.

It is generic enough for any WordPress project but leans towards Pantheon: a
Pantheon `wp-config.php` drops in cleanly, and the database can be pulled straight
from a Pantheon environment with one menu option.

> **Migrating from the Docker Compose version of this sandbox?** See
> [What changed from the Docker version](#what-changed-from-the-docker-version).

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
- [Reaching the site from Windows](#reaching-the-site-from-windows)
- [The browser](#the-browser)
- [Pulling the database from Pantheon](#pulling-the-database-from-pantheon)
- [Image processing (GD / Imagick)](#image-processing-gd--imagick)
- [Logging DB changes](#logging-db-changes)
- [Project-specific instructions](#project-specific-instructions)
- [Sandbox mu-plugins](#sandbox-mu-plugins)
- [Email capture (Mailpit)](#email-capture-mailpit)
- [Page cache (stale pages in the browser)](#page-cache-stale-pages-in-the-browser)
- [Compiling SASS](#compiling-sass)
- [Scripts](#scripts)
- [MCP Servers](#mcp-servers)
- [.env Protection](#env-protection)
- [Multiple Projects](#multiple-projects)
- [What changed from the Docker version](#what-changed-from-the-docker-version)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Disclaimer](#disclaimer)
- [License](#license)

## Problem

**Local WordPress development is fiddly, and it is fiddly once per project.** You
want a real WP install, a real database, WP-CLI, a real browser that can reach the
dashboard, mail you can read instead of mail that vanishes, and the ability to drop
in a production SQL dump. Setting that up by hand is annoying; setting it up five
times for five client sites is worse.

**And an AI agent working in it needs more than a screenshot.** It needs to run
`wp` commands, query the database, edit theme files, and drive a browser through
real flows — while you keep the ability to step in when something needs a human,
like a captcha, a federated login, or a password you would rather not type into a
chat window.

The previous version of this project solved the first problem with a hand-built
Docker Compose stack. DDEV already does that job, better and with less to maintain,
so this version delegates to it and spends its own complexity on the second problem.

## Solution

- **DDEV owns the environment.** WordPress on nginx-fpm with PHP 8.2, MariaDB 11.8,
  WP-CLI, Composer, Node, Mailpit, Xdebug and XHProf all come from DDEV. There is no
  Dockerfile to maintain for any of it.
- **No `name:` in `.ddev/config.yaml`,** so DDEV derives the project name from the
  directory. Copy this scaffolding into another site and it becomes its own project
  at `https://<directory-name>.ddev.site` with no edits — and because DDEV routes
  everything through one shared router, **any number of sandboxes run at once**.
- **The project root is the docroot,** matching Pantheon's layout. Your theme is at
  `wp-content/themes/<yours>/` and WordPress core sits at the top level.
- **A browser you can share with the agent.** Playwright drives a headed Chromium on
  a persistent virtual display; you reach it over RDP. Log in by hand, disconnect,
  and automation continues in the same browser with your session intact. See
  [The browser](#the-browser).
- **HTTPS that is genuinely trusted,** including inside Chromium — which needs more
  than `mkcert -install` alone. See [Requirements](#requirements).
- **Mail is captured, never sent.** DDEV's Mailpit catches ordinary `wp_mail()` with
  no configuration, and a mu-plugin blocks the one case DDEV misses: a site's own
  SMTP plugin relaying real mail with credentials that arrived in a production
  database dump.
- **`site-control.sh` interactive menu** for the jobs you do outside Claude: start
  and stop, generate the DDEV WordPress config, import a SQL file, pull the database
  from Pantheon, search-replace URLs (single site and multisite), refresh the admin
  user, and compile or watch SASS.
- **Pull-only Pantheon integration.** `ddev push pantheon` is disabled on purpose;
  pushing is a manual job done from a trusted checkout.
- **`DB_CHANGES.MD` log.** A required append-only record of every dashboard change so
  the sandbox state stays reproducible — see
  [.local/CLAUDE-LOCAL.md](./.local/CLAUDE-LOCAL.md).
- **`.env` is locked down** with permission deny rules and a PreToolUse hook, and the
  same protection covers `.local/.playwright-secrets` — credentials the browser may
  use but Claude may not read.

## Layout

```
.
├── .claude/
│   ├── hooks/                      # PreToolUse hooks (deny .env / secrets reads)
│   │   ├── deny-env-reads.sh
│   │   ├── deny-env-reads.ps1
│   │   └── _hook_tests.sh          # developer harness for the hook
│   └── settings.json               # Hook wiring + permission deny list
├── .ddev/
│   ├── config.yaml                 # Project config — deliberately has no `name:`
│   ├── providers/pantheon.yaml     # Pull-only; push commands removed
│   ├── web-build/Dockerfile        # Pins the SASS toolchain into the web image
│   └── web-entrypoint.d/
│       └── 10-sandbox-mu-plugins.sh  # Installs the mu-plugins on every start
├── .local/
│   ├── CLAUDE-LOCAL.md             # The sandbox's Claude rules — imported by root CLAUDE.md
│   ├── bootstrap-vm.sh             # ONE-TIME machine setup (display, browser, certs, RDP)
│   ├── display.sh                  # Manage the persistent virtual display
│   ├── playwright-mcp.sh           # MCP server launcher (referenced by .mcp.json)
│   ├── site-control.sh             # The interactive menu
│   ├── search-replace-multisite.sh # Network-aware URL rewrite
│   ├── prune-playwright-mcp.sh     # Screenshot housekeeping
│   ├── check-image-support.php     # Verifies GD + Imagick really process images
│   ├── windows/
│   │   └── Setup-DdevPortProxy.ps1 # Run on Windows: reach the sites + trust the CA
│   ├── wp-mu-plugins/
│   │   ├── 00-sandbox-mail-guard.php   # Stops a site's SMTP plugin sending real mail
│   │   └── 01-sandbox-page-cache.php   # Drops the Pantheon page-cache TTL to 0
│   ├── DOC/
│   │   ├── DB_CHANGES.MD           # Append-only log of dashboard changes
│   │   └── audit-accessibility/    # a11y audit skill
│   ├── .playwright-profile/        # Per-project browser profile (git-ignored)
│   └── .playwright-secrets         # Optional dotenv for the browser (git-ignored, never read by Claude)
├── .sass/
│   ├── sass.sh                     # Host entry point; hands off to the web container
│   ├── sass-runner.js
│   └── SASS.settings.json
├── .mcp.json                       # Project-scoped MCP servers (auto-discovered)
├── CLAUDE.md                       # Yours — a stub importing .local/CLAUDE-LOCAL.md
└── README.md
```

Everything sandbox-related lives in `.local/`, `.ddev/` and `.sass/`. DDEV's nginx
denies dotted paths, so none of them are reachable over HTTP.

## Tech

- [DDEV](https://ddev.com/) — the whole environment: nginx-fpm, PHP 8.2, MariaDB 11.8,
  WP-CLI, Composer, Node 24, Mailpit, Xdebug, XHProf, mkcert-backed HTTPS
- [WordPress](https://wordpress.org/) — your own codebase
- [Playwright](https://playwright.dev/) + [@playwright/mcp](https://www.npmjs.com/package/@playwright/mcp) — browser automation
- [Xvfb](https://www.x.org/) + [openbox](http://openbox.org/) + [x11vnc](https://github.com/LibVNC/x11vnc) + [xrdp](https://www.xrdp.org/) — the persistent display you connect to
- [Claude Code](https://docs.claude.com/en/docs/claude-code/overview)
- [Terminus](https://docs.pantheon.io/terminus) — bundled in DDEV's web container, used for the Pantheon pull

## Requirements

- **A Linux machine or VM** with Docker and [DDEV](https://docs.ddev.com/en/stable/users/install/ddev-installation/)
  installed. This was built on a Debian 13 Hyper-V VM.
- **`bash` and a standard GNU userland.** `sudo` is needed once, for
  `bootstrap-vm.sh`.
- **An RDP client** on whatever machine you sit at, if you want to watch or take over
  the browser. Windows' built-in Remote Desktop Connection is fine.

A note on HTTPS, because it has a trap in it. DDEV serves every project over HTTPS
using a certificate from mkcert's local CA. `mkcert -install` puts that CA in the
system trust store, which is enough for `curl` — but **Chromium does not read the
system store.** It uses its own NSS database at `~/.pki/nssdb`, and if that database
does not exist yet, `mkcert -install` silently skips it. The result is Playwright
failing every navigation with `ERR_CERT_AUTHORITY_INVALID` while `curl` on the same
machine works perfectly. `bootstrap-vm.sh` creates the database and adds the CA, which
is the right fix; launching the browser with `--ignore-certificate-errors` would
"work" by turning off TLS validation everywhere, and is not what this does.

## Installation

Run the one-time machine setup from the project root:

```bash
./.local/bootstrap-vm.sh
```

It installs the virtual display packages and `jq`, trusts the local CA in Chromium,
installs Playwright and Chromium, points xrdp at the persistent display, and starts
it. It asks for `sudo` where it needs it, says what it is about to do, and is safe to
re-run — every step checks before acting.

Run it **once per machine**, not once per project. Everything it sets up is shared by
every sandbox on the box.

Then pick a workflow below.

## Workflow A — Drop scaffolding into an existing WP project

You already have a WordPress codebase (cloned from Pantheon or GitHub) and want to
give Claude a sandboxed local environment.

1. Install the scaffolding. Do not copy by hand — a blind copy overwrites the
   project's own `wp-config.php`, `.gitignore`, `.htaccess` and `README.md`. Use
   the installer, which knows which files belong to whom:

   ```
   ./.local/install-into-project.sh --dry-run /path/to/your-wp-project   # review
   ./.local/install-into-project.sh /path/to/your-wp-project             # do it
   ```

   It sorts every file into three classes:

   | | What | Behaviour |
   | --- | --- | --- |
   | **overwrite** | `.ddev/`, `.local/`, `.claude/`, `.sass/` runner, `.mcp.json`, `CLAUDE.md` | Rewritten on every run — this repo is the source of truth. Anything replaced is first copied to `.local/.install-backups/<timestamp>/`. |
   | **seed** | `.local/DOC/DB_CHANGES.MD`, `.sass/SASS.settings.json` | Created once, then never touched. They accumulate project history. |
   | **never** | `wp-config.php`, `.gitignore`, `.htaccess`, `README.md`, `.git/`, dotenv files, the Playwright secrets file, `.ddev/config.local.yaml`, `.local/.playwright-profile/` | The project owns these. |

   It is re-runnable: that is how a project picks up a later fix to the sandbox.
   Three things it does beyond copying —

   - **Adds the needed rules to the project's `.gitignore`**, under its own
     `# Local Sandbox #` heading (created at the end of the file if absent), in the
     same bare style as the rest of the file — no marker block, no commentary. A
     rule already present anywhere in the file is not repeated, so on a project
     that has hosted the sandbox before the diff is usually two or three lines.
     Note this is purely additive: a rule later dropped from the sandbox is not
     retracted from a project that already took it.
   - **Matches the database engine to production.** It reads `database: version:`
     from `pantheon.upstream.yml` and, if it differs from this repo's pin, writes
     `.ddev/config.local.yaml` — which DDEV merges over `config.yaml` and which
     survives the next re-run.
   - Installs this README as `.local/SANDBOX-README.md`, so the project's own
     `README.md` is left as it is.

   The file list comes from `git ls-files`, not a hardcoded array, so a file added
   to this repo propagates without editing the installer.
2. Run `./.local/site-control.sh`:
   - **Option 1** — Power on. Starts DDEV, creating `.ddev/config.yaml` first if it is
     somehow missing.
   - **Option 3** — Generate the DDEV WordPress config. This writes
     `wp-config-ddev.php` and then makes sure your own `wp-config.php` actually loads
     it. DDEV will not edit a `wp-config.php` it did not create — it only prints a
     suggestion — so this option inserts the include for you, above the
     `wp-settings.php` require, behind a timestamped backup. It also detects and
     repairs the stock Pantheon upstream's placeholder `DB_NAME` fallback, which
     otherwise causes ["Error establishing a database
     connection"](#error-establishing-a-database-connection-on-a-pantheon-project).
     If your `wp-config.php` hardcodes `DB_NAME` / `DB_USER` / `DB_PASSWORD` /
     `DB_HOST` anywhere else, comment those out: whichever is defined first wins.
   - **Option 4** — Import your SQL dump (drop a `.sql` / `.sql.gz` / `.zip` in the
     project root first), or **Option 5** to pull it from Pantheon.
   - **Option 6 / 7** — Search-replace your production URL, if content has it
     hardcoded. Often unnecessary; see
     [Pulling the database from Pantheon](#pulling-the-database-from-pantheon).
   - **Option 8** — Create/refresh the `admin/admin` user.
3. Visit the URL `ddev describe` prints. From the machine running DDEV it just works;
   from a different machine see [Reaching the site from Windows](#reaching-the-site-from-windows).

## Workflow B — Clone this repo, add WP into it

You want a fresh sandbox to drop a WordPress codebase into.

1. Clone this repository and rename the directory to whatever you want the project
   called — the directory name becomes the DDEV project name and the hostname.
2. Copy your WordPress files into the project root, alongside `.local/`, `.ddev/` and
   friends. For a brand-new site, start DDEV and run `ddev wp core download`.
3. Run `./.local/site-control.sh` and follow the same options as Workflow A.

In both workflows the project root is the WordPress docroot.

## site-control.sh

`./.local/site-control.sh` is the interactive control panel for the WordPress side of
the sandbox. It prints a status header and a menu:

```
  1) Power on  (ddev start)
  2) Power off (ddev stop)
  3) Generate the DDEV WordPress config
  4) Import database from a SQL file
  5) Import database from Pantheon
  6) Search-replace database URLs (single site)
  7) Search-replace database URLs (multisite/network)
  8) Create/refresh sandbox admin user
  9) Compile SASS
 10) Watch SASS (Ctrl+C to stop)
  q) Quit
```

- **Power on/off** — `ddev start` / `ddev stop`. Note `stop` is per-project and keeps
  the database; `ddev poweroff` would stop every project on the machine. There is no
  port-conflict check any more because there are no per-project ports to conflict.
- **Generate the DDEV WordPress config** — see Workflow A step 3.
- **Import a SQL dump** — lists every `*.sql` / `*.sql.gz` / `*.gz` / `*.zip` in the
  project root with its size and hands the chosen one to `ddev import-db`, which
  drops the existing tables and understands all those formats natively.
- **Import from Pantheon** — see [Pulling the database from Pantheon](#pulling-the-database-from-pantheon).
- **Search-replace URLs** — detects the current `siteurl` and rewrites both the
  `https://` and `http://` forms of it to this project's DDEV URL, across all tables,
  skipping `guid`. Doing both schemes matters: a production dump is usually `https`
  while older content often holds `http` links, and missing one leaves mixed URLs.
- **Search-replace URLs (multisite)** — delegates to
  `.local/search-replace-multisite.sh`. Use this instead of option 6 for a network.
  It exists because a network needs two things option 6 cannot do: boot WP-CLI against
  the *old* host still present in `wp_blogs` (otherwise the multisite bootstrap fatals
  with "Site not found" and nothing runs at all), and rewrite the protocol-less domain
  columns in `wp_blogs` / `wp_site` / `wp_sitemeta` that a full-URL replace never
  touches.
- **Create/refresh admin user** — `admin` / `admin` / `admin@admin.com` as an
  administrator via WP-CLI, with a direct-SQL fallback (MD5 password; WordPress
  rehashes on next login) for when WP-CLI cannot bootstrap.
- **Compile / watch SASS** — see [Compiling SASS](#compiling-sass).

The sandbox database credentials are DDEV's defaults: `db`/`db`/`db`, plus
`root`/`root`. They are sandbox-only — don't reuse them.

## Reaching the site from Windows

If you sit at a different machine from the one running DDEV — a Windows host with the
sandbox on a Linux VM, say — the sites are not reachable out of the box, and neither
is the HTTPS certificate trusted. Two things fix that, and **you only ever set them
up once, for every project you will ever create**:

```powershell
# In an ADMINISTRATOR PowerShell on Windows, from the project directory:
.local\windows\Setup-DdevPortProxy.ps1 -CaCertPath C:\temp\rootCA.pem
```

The script leans on a useful fact: `*.ddev.site` is a **real public DNS wildcard that
already resolves to `127.0.0.1` everywhere**, including on Windows. So Windows is
already sending `anything.ddev.site` to its own loopback — there is just nothing
listening there. The script adds two `netsh portproxy` rules relaying loopback `80`
and `443` to the VM:

```
browser -> myproject.ddev.site -> 127.0.0.1:443 -> VM:443 -> traefik -> the right project
```

Because the relay is plain TCP, the `Host` header and TLS SNI reach the VM untouched,
so DDEV's router picks the right project. A new project needs **no configuration at
all** — `ddev start` and it is reachable.

This is worth contrasting with the obvious approach: the Windows `hosts` file has no
wildcard support, so going that route really would mean one line per project, added
as administrator each time. Two rules beat N lines.

It also imports the VM's mkcert root CA into the Windows Trusted Root store. Without
that, every `https://*.ddev.site` page shows a certificate error Chromium will not let
you click through. Get the certificate off the VM with:

```bash
cat "$(mkcert -CAROOT)/rootCA.pem"
```

and paste it into a file on Windows, or copy it across over the RDP clipboard.

Two caveats:

- **You also need `router_bind_all_interfaces`** so DDEV's router listens beyond
  loopback on the VM: `ddev config global --router-bind-all-interfaces`. Be aware this
  exposes Mailpit's ports to the network too, which DDEV's own docs flag; on a
  host-only VM network that is narrow, but worth a firewall rule if yours is broader.
- **Re-run the script if the VM's IP changes.** Hyper-V's Default Switch hands out
  DHCP addresses that can change when Windows reboots. The script resolves the VM by
  name (`<hostname>.mshome.net`, which Hyper-V registers) rather than hardcoding an
  address, so re-running is all it takes. Give the VM a static address if you would
  rather not think about it.

## The browser

Two browsers are in play, and they are good at different things.

### Playwright (the default)

Wired up through `.mcp.json` → `.local/playwright-mcp.sh`. It runs **on the machine
hosting DDEV**, which is what makes it work: it can reach `https://*.ddev.site`, and
it trusts the local CA. It also gives you isolated browser contexts — genuine
incognito, with separate cookie jars — plus request interception, uploads and
downloads.

It runs **headed** on a shared virtual display, so you can watch it and take over.

### Taking over the browser

1. Connect with an RDP client and choose the **"Sandbox Browser"** session.

   *How* you connect depends on how xrdp is configured, and the Debian default on a
   Hyper-V guest is not what you would guess. Check it:

   ```bash
   grep -m1 '^port=' /etc/xrdp/xrdp.ini
   ```

   - `port=vsock://-1:3389` — Hyper-V **Enhanced Session Mode**. Connect through
     **Hyper-V Manager → Connect** (vmconnect), *not* to an IP address. Nothing
     listens on TCP 3389, and `ss -ltn` shows nothing for xrdp — which makes it very
     easy to conclude xrdp is broken when it is fine. Use `ss --vsock -l` to see the
     real listener. `bootstrap-vm.sh` detects this and prints the right advice.
   - `port=3389` — an ordinary TCP listener. Connect to
     `<vm-ip>:3389` or `<hostname>.mshome.net:3389`.

2. You are looking at the virtual desktop the browser lives on. Log in, solve the
   captcha, type the password.
3. Disconnect. **The browser stays running** and automation continues with your
   session intact — it is the same browser, not a copy.

That last point is why the display is persistent rather than owned by your RDP
session: an RDP-session-owned browser dies when you disconnect, and its `DISPLAY`
number changes on every connect.

```bash
.local/display.sh status   # what is running, and which windows are open
.local/display.sh up       # start it (safe to re-run)
.local/display.sh down     # stop it — closes EVERY project's browser
```

The display is **shared** by every sandbox on the machine. That is deliberate: a
display is a screen, not a browser slot, so each project's browser is just another
window on one desktop and one RDP session shows you all of them. What is
**per-project** is the browser *profile* (`.local/.playwright-profile/`), because that
is what actually collides — Chromium refuses to open a second instance against the
same profile directory.

If the display cannot start, the MCP server falls back to headless rather than
failing. Force headless with `SANDBOX_PLAYWRIGHT_HEADLESS=1`.

### Credentials you don't want in the chat

Create `.local/.playwright-secrets` as a dotenv file and the MCP server is started
with `--secrets` pointing at it, so the **browser** can use those values while Claude
cannot read the file. The `.env` deny rules and the PreToolUse hook both cover it, and
it is git-ignored.

### Claude Code's own browser

If your Claude Code client has a built-in browser, it is useful for showing you
something — but know its limits before relying on it. When the client runs on a
different machine from DDEV, it **cannot reach that machine's `localhost`** and will
only see the site once the port proxy above is in place. And all of its tabs typically
**share one cookie jar**, so you cannot be logged in as admin in one tab and anonymous
in another. Use Playwright contexts for that.

## Pulling the database from Pantheon

Menu **option 5** imports the database straight from a Pantheon environment. It asks
which environment to use (`live`, `test`, `dev`, or a multidev branch), remembers the
site name in `.ddev/config.local.yaml` (which DDEV git-ignores), and never touches
files — code and uploads come from git.

The backup rule is: **reuse Pantheon's newest database backup if it is less than 24
hours old, and only create a new one when it is not.** DDEV's own provider has no mode
for this — it either grabs the newest existing backup regardless of age
(`DDEV_USE_PANTHEON_BACKUP=true`) or streams a fresh `mysqldump` off the live database,
which is slow — so the freshness check is implemented in `site-control.sh`.

Setup is a one-time global step:

```bash
ddev config global --web-environment-add="TERMINUS_MACHINE_TOKEN=<token>"
ddev restart
```

Generate the token at the Pantheon dashboard under Account → Machine Tokens. Terminus
itself is already in DDEV's web container.

**After importing, search-replace is usually unnecessary.** `wp-config-ddev.php`
defines `WP_HOME` and `WP_SITEURL` from DDEV, and those **override whatever URL is in
the database**, so the site is browsable immediately. You need option 6 only for URLs
hardcoded in post content, and option 7 for a multisite network, where `wp_blogs` and
`wp_site` store bare domains that no constant can override. Option 5 offers both when
it finishes.

`ddev push pantheon` is **disabled** in `.ddev/providers/pantheon.yaml` — it dropped
and recreated the remote database, which is not something that should be one typo
away in a sandbox. The `#ddev-generated` marker is removed from that file so DDEV
cannot restore it. Push by hand from a trusted checkout.

## Image processing (GD / Imagick)

WordPress needs one of two PHP extensions to resize anything — Imagick (preferred) or
GD (fallback). DDEV's web container has both, with Imagick carrying a full delegate
set, so `wp media regenerate`, `wp media import`, thumbnail generation and plugin
resizing all work with no setup. Verify it:

```bash
ddev exec php .local/check-image-support.php
```

It round-trips a real image through each backend (create → encode → decode → resize)
rather than just checking `extension_loaded()`, and exits non-zero on failure.

## Logging DB changes

Every change made through the WordPress dashboard — posts, pages, settings, plugins,
themes, menus, widgets, users — must be appended to `.local/DOC/DB_CHANGES.MD`, oldest
first, never rewritten or reordered. It is the running history that makes the sandbox
state reproducible. The rule Claude follows is in
[.local/CLAUDE-LOCAL.md](./.local/CLAUDE-LOCAL.md).

## Project-specific instructions

`CLAUDE.md` in the project root is **yours**. It ships as a stub that imports the
sandbox's own rules:

```markdown
# CLAUDE.md

<!-- THIS IS REQUIRED FOR THE SANDBOX TO WORK PROPERLY --->
## Claude DDEV Sandbox Instructions
@.local/CLAUDE-LOCAL.md
<!-- DO NOT REMOVE ABOVE!!! --->
```

Add your site's conventions below that import — coding standards, which plugins are
off-limits, deployment quirks. Because the sandbox's rules live in
`.local/CLAUDE-LOCAL.md`, updating `.local/` keeps them current without touching what
you wrote.

## Sandbox mu-plugins

The sandbox's must-use plugins live in `.local/wp-mu-plugins/`. On every web container
start, `.ddev/web-entrypoint.d/10-sandbox-mu-plugins.sh` installs them here:

```
wp-content/mu-plugins/
├── 00-local-mu-plugins.php     # generated stub — loads the folder below
└── local-mu-plugins/           # generated copies of .local/wp-mu-plugins/*.php
```

**Always edit `.local/wp-mu-plugins/`, never `wp-content/mu-plugins/`.** Both
generated paths are overwritten on every start and are git-ignored; the installer also
deletes copies whose source is gone, and cleans up copies from the old layout.

Three things to know before changing this:

- **The stub is what makes the subfolder work.** `wp_get_mu_plugins()`
  (`wp-includes/load.php`) `readdir()`s `wp-content/mu-plugins` and takes only the
  `*.php` directly inside it — WordPress never recurses. Delete the stub and
  everything in `local-mu-plugins/` silently stops loading. The subfolder exists to
  keep sandbox files clearly apart from the project's own, since Pantheon's
  `loader.php` and `pantheon-mu-plugin/` live in the same directory.
- **The `00-` prefix is load-bearing.** mu-plugins load in filename order, and
  `01-sandbox-page-cache.php` must register its filter before Pantheon's `loader.php`
  constructs `Pantheon_Cache`.
- **DDEV *sources* the scripts in `.ddev/web-entrypoint.d/`,** it does not execute
  them. So an `exit` at top level terminates the entrypoint and the container never
  boots — which is exactly what happened the first time this was written — and `set -e`
  leaks into the rest of the entrypoint. That is why the installer's body runs inside a
  subshell. Keep it that way.

Sandbox-only code gates on `getenv('IS_DDEV_PROJECT') === 'true'`, which is set in
every DDEV web container and nowhere else, so a stray copy on a production host does
nothing.

## Email capture (Mailpit)

DDEV ships Mailpit inside the web container and points PHP's `sendmail_path` at it:

```
sendmail_path = /usr/local/bin/mailpit sendmail -t --smtp-addr 127.0.0.1:1025
```

So every `mail()` — and therefore every ordinary `wp_mail()` — is captured with no
configuration at all. Password resets and registration notices are safe to trigger and
readable afterwards. Open the UI with `ddev mailpit`, or at
`https://<project>.ddev.site:8026`. The JSON API is often easier:

```bash
ddev exec 'curl -s http://127.0.0.1:8025/api/v1/messages'
ddev exec 'curl -s http://127.0.0.1:8025/api/v1/message/<ID>'
ddev exec 'curl -s -X DELETE http://127.0.0.1:8025/api/v1/messages'
```

**The one case DDEV does not cover** is a site whose own SMTP plugin — WP Mail SMTP,
Post SMTP, Easy WP SMTP — hooks `phpmailer_init` and points PHPMailer at a real relay,
typically using credentials that arrived with an imported production database. That
bypasses `sendmail` entirely, and the sandbox would cheerfully email live customers.
`.local/wp-mu-plugins/00-sandbox-mail-guard.php` prevents it by forcing every message
back to Mailpit at `PHP_INT_MAX` priority. The priority is the whole point: mu-plugins
load before regular plugins, so a hook registered at the normal priority would run
*first* and be overwritten by the plugin's. Running last makes that impossible.

## Page cache (stale pages in the browser)

If a page still shows old markup after you edited a template, suspect the cache before
you suspect your change. On projects carrying Pantheon's mu-plugin, HTML goes out as
`cache-control: public, max-age=604800` — a week — and the sandbox has no purge layer
to invalidate it.

`.local/wp-mu-plugins/01-sandbox-page-cache.php` filters
`pantheon_cache_default_max_age` to `0` so new requests revalidate every time. It only
affects requests made *after* it took effect, so a URL cached earlier under the
week-long header stays stuck until it expires. Reload that URL with cache bypass
rather than concluding the fix did not work:

```js
fetch(location.href, {cache: 'reload'})
```

## Compiling SASS

```bash
bash .sass/sass.sh compile     # once
bash .sass/sass.sh watch       # watch for changes
```

Run it from the host; it hands off to the web container, where the toolchain lives.
Run it from inside the container (`ddev ssh`) and it executes the runner directly.
Entries come from `.sass/SASS.settings.json` — copy
`.sass/SASS.settings.example.json` to start.

`sass`, `postcss` and `autoprefixer` are pinned in `.ddev/web-build/Dockerfile` and
installed into `/usr/local/lib/sandbox-sass`, with `NODE_PATH` pointing at it. That
fixed path is deliberate rather than a plain `npm install -g`: DDEV manages Node with
`n`, so the global module root is version-dependent and gets replaced whenever
`nodejs_version` changes in `.ddev/config.yaml` — which would silently strip the
toolchain. After editing that Dockerfile, run `ddev restart` to rebuild.

## Scripts

All in `.local/`, all run from the host.

- **`bootstrap-vm.sh`** — One-time, per-machine setup: virtual display packages and
  `jq`, the mkcert CA in Chromium's NSS store, Playwright and Chromium, xrdp pointed at
  the persistent display. Idempotent; asks for `sudo` where needed.
- **`site-control.sh`** — The interactive menu; see [above](#site-controlsh).
- **`display.sh`** — `up` / `ensure` / `down` / `status` for the virtual display.
  Override `SANDBOX_DISPLAY_NUM`, `SANDBOX_VNC_PORT` or `SANDBOX_SCREEN_GEOMETRY` if you
  ever want a project on its own screen.
- **`playwright-mcp.sh`** — Launches the MCP server with the per-project profile, the
  screenshot output directory, and the headed-or-headless decision. Referenced by
  `.mcp.json`; you do not normally run it yourself.
- **`search-replace-multisite.sh`** — Network-aware URL rewrite. Takes `[OLD] [NEW]`,
  `--dry-run` and `-y`.
- **`prune-playwright-mcp.sh`** — Deletes screenshots older than 7 days, then caps the
  directory at 100 files. Run automatically when the MCP server starts.
- **`check-image-support.php`** — `ddev exec php .local/check-image-support.php`.
- **`windows/Setup-DdevPortProxy.ps1`** — Run on Windows, elevated. See
  [Reaching the site from Windows](#reaching-the-site-from-windows).

## MCP Servers

`.mcp.json` in the project root is the discovery point — Claude Code picks it up
automatically. The old sandbox passed `.local/.mcp.json` with `--mcp-config` from a
start script; there are no start scripts any more, because Claude runs natively rather
than in a container, so a project-root `.mcp.json` is the right home.

It points at `.local/playwright-mcp.sh` rather than `@playwright/mcp` directly, which
is what adds the headed display, the per-project profile and the headless fallback.

One implementation note if you edit that script: **MCP speaks JSON-RPC over stdout**,
so anything printed there corrupts the stream and the server looks like it is hanging.
Every diagnostic in it goes to stderr, deliberately.

Screenshots default to `.playwright-mcp/` via `--output-dir`, and that directory is
pruned on each start.

## .env Protection

`.env` and `.local/.playwright-secrets` both get layered protection:

- **`.local/CLAUDE-LOCAL.md`** — a hard rule telling Claude never to read or transmit
  either file (or any backup like `.env.bak`, `.env.local`), loaded via the `@` import
  in `CLAUDE.md`.
- **`.claude/settings.json`** — a `permissions.deny` list blocking the Read tool
  against `.env` / `**/.env.*` / the secrets file, plus a long set of
  `Bash(<tool> *.env*)` and `Bash(<tool> *playwright-secrets*)` patterns for `cat`,
  `grep`, `sed`, `cp`, `mv`, `tar`, `zip` and friends. This layer is enforced by Claude
  Code itself.
- **`.claude/hooks/deny-env-reads.sh`** (and `.ps1`) — PreToolUse hooks that inspect
  every Bash command's full text and deny anything referencing `.env`, `.env.<ext>`
  other than `.env.example`, or the secrets file. Hook failures fail open, so a broken
  hook cannot lock you out.
- **`_hook_tests.sh`** — a developer harness running the hook against expected-block
  and expected-allow inputs.

**The hook layer needs `jq`.** `settings.json` only runs the hook when `jq` is present,
so without it that layer is silently inert and only the deny list is active.
`bootstrap-vm.sh` installs `jq` for this reason.

`.env.example` is always allowed — it contains variable names but no secrets. Note that
the deny patterns are broad enough to also block `cat .env.example`; read it with an
editor or a differently-named copy if you need to.

## Multiple Projects

Copy this whole folder into as many WordPress projects as you like. Because
`.ddev/config.yaml` has no `name:`, each copy names itself from its directory and gets:

- its own containers and its own database,
- its own hostname at `https://<directory-name>.ddev.site`,
- its own browser profile at `.local/.playwright-profile/`,
- its own Pantheon site setting in `.ddev/config.local.yaml`.

**They can all run at the same time.** DDEV routes every project through one shared
router keyed on hostname, so there are no per-project host ports to collide — a real
change from the old setup, where `8080` and `8025` were fixed and only one sandbox could
run at once.

What *is* shared, on purpose: the virtual display, xrdp, Chromium, and the trusted CA.
Each project's browser is a separate window on the one virtual desktop.

`ddev list` shows every project; `ddev poweroff` stops all of them.

## What changed from the Docker version

If you know the Compose-based sandbox, here is the short version.

**Deleted, because DDEV already does it:** `Dockerfile`, `Dockerfile.wp-cli`,
`docker-compose.yml`, `wp-entrypoint.sh`, `php-memory.ini`, `compose.sh`. DDEV provides
WordPress, MariaDB, WP-CLI, GD, Imagick with full delegates, Mailpit, and host-user file
ownership. `Dockerfile.wp-cli` existed only to repair `wordpress:cli`'s delegate-less
Imagick; that bug does not exist in DDEV's container.

**Deleted, because Claude no longer runs in a container:** `start-claude-normal.sh`,
`start-claude-dangerously.sh`, `rebuild-claude.sh`, `restore-sessions.sh`, the session
backup/restore dance, the OAuth token in `.env`, and the "Update Claude CLI" menu
option. Claude runs natively on the VM.

**Deleted, because the underlying problem is gone:**

- `DOC/FIX/PLAYWRIGHT_BLANK_PAGE_FIX.md` — blank pages and hanging screenshots came
  from headed Chrome painting to an *occludable* X window on the Windows desktop; when
  Windows stopped driving paints, Chrome produced zero frames. An Xvfb framebuffer is
  always mapped, so it cannot recur. VcXsrv and the `DISPLAY=host.docker.internal:0.0`
  wiring are gone with it.
- `DOC/FIX/WP_CLI_DB_CONNECTION_FIX.md` — the `php -d variables_order=EGPCS` workaround
  is unnecessary: DDEV's PHP already ships `variables_order=EGPCS`, so `$_ENV` is
  populated. Just run `ddev wp`.

**Changed:**

- `http://wordpress/` → `https://<project>.ddev.site`. The container hostname existed
  because Playwright ran in a sibling container on a Compose network.
- `PANTHEON_ENVIRONMENT=local` → `IS_DDEV_PROJECT=true` as the sandbox-only gate.
- `wp-config.local.php` → DDEV's own `wp-config-ddev.php`, with `site-control.sh`
  option 3 wiring your `wp-config.php` to it.
- Apache → nginx. This matches Pantheon, which also runs nginx. **Consequence: the
  repository's `.htaccess` is inert**, exactly as it is on Pantheon. Custom rewrite or
  header rules go in `.ddev/nginx_full/`.
- The mailpit mu-plugin shrank to a mail *guard* (see
  [Email capture](#email-capture-mailpit)).
- Masking `.local` and `.sass` out of the docroot with anonymous volumes is no longer
  needed — DDEV's nginx denies dotted paths already.

**New:** the Pantheon database pull, `ddev snapshot` for database snapshots, `ddev
xdebug on` for step debugging, `ddev xhgui` for profiling, `ddev share` for a temporary
public URL, and the take-over-the-browser workflow.

## Troubleshooting

### "Error establishing a database connection" on a Pantheon project

The usual cause is not DDEV. It is the dead-code fallback at the end of the
stock Pantheon `wp-config.php`:

```php
} else {
    define('DB_NAME',          'database_name');
    ...
```

On Pantheon that branch never runs, because `PANTHEON_ENVIRONMENT` is always
set. Under DDEV nothing sets it and `wp-config-local.php` does not exist, so the
branch *does* run — and it runs above the `wp-config-ddev.php` include, because
that include has to sit after `ABSPATH` is defined (`wp-config-ddev.php`
dereferences `ABSPATH` to compute `WP_SITEURL`; put it any higher and you get an
instant fatal). Since DDEV guards every constant with `defined() || define()`,
the placeholders win. Confirm it with:

```
ddev exec php -r 'require "wp-config.php";' 2>/dev/null; ddev wp config get DB_NAME
```

`database_name` means you have hit this. **`.local/site-control.sh` option 3
detects and fixes it** — it retargets that one `else` to skip under DDEV, which
leaves Pantheon and plain local checkouts behaving exactly as before.

### RDP logins disconnect immediately

You connect, it authenticates, and the session closes at once — repeatedly. Almost
always this means a **previous RDP session was orphaned** and is still holding the
display.

It happens when `xrdp` is restarted while a session is live. The session's `Xorg`,
`xfce4-session` and `xrdp-chansrv` lose their parent `xrdp-sesman`, reparent to
`init` (PPID 1) and keep running. A stale `xfce4-session` then refuses to let the
same user start a second one, so every new login dies instantly. `~/.xsession-errors`
shows the giveaway — a session starting over and over:

```
Xsession: X session started for <user> at ...
/usr/bin/x-session-manager: X server already running on display :11.0
```

Find the orphans — the tell is `PPID 1` on an `Xorg` started with `xrdp/xorg.conf`:

```bash
ps -eo pid,ppid,user,cmd | grep -E "[X]org.*xrdp|[x]fce4-session|[x]rdp-chansrv"
```

Kill them (they are yours, so no `sudo` needed), then clear any stale lock left
behind, then reconnect:

```bash
kill <xfce4-session-pid> <xrdp-chansrv-pid> <Xorg-pid>
rm -f /tmp/.X<N>-lock /tmp/.X11-unix/X<N>      # only for the dead display
```

Be careful to leave `:99` alone — that is the sandbox's own display, and `:0` belongs
to the local console session.

`bootstrap-vm.sh` will no longer restart `xrdp` when it detects a live session, for
exactly this reason; it tells you to do it from SSH or after disconnecting instead.

**A red herring while diagnosing this:** `ss -ltn | grep 3389` showing nothing does
*not* mean xrdp is down. On a Hyper-V guest the Debian default is
`port=vsock://-1:3389`, a VSOCK that `ss -ltn` cannot display. Check with
`ss --vsock -l`, which should show `v_str LISTEN *:3389`.

### The desktop's window manager changed after running bootstrap

Installing `openbox` can silently replace the system window manager. Debian's
alternatives system picks the highest-priority candidate while the link is in `auto`
mode, and **openbox registers at priority 90 against xfwm4's 60** — so a machine
running XFCE quietly switches to openbox for every desktop session.

`bootstrap-vm.sh` now records the window manager before installing and puts it back
afterwards. To check and fix it by hand:

```bash
update-alternatives --query x-window-manager | grep -E "^(Value|Best|Status)"
sudo update-alternatives --set x-window-manager /usr/bin/xfwm4
```

`--set` also switches the link to manual mode, so a later openbox upgrade cannot
reclaim it. This does not affect the sandbox: `display.sh` runs openbox by name on
the `:99` display and never consults the alternative.

### The RDP session shows a blank screen

Expected, if no browser is open. The `:99` display is a bare window manager with
nothing on it between automation runs, so it renders as one flat colour — and an
untouched openbox root is pure **black**, which is indistinguishable from a dead
connection.

`display.sh` now paints the root window dark blue (set `SANDBOX_ROOT_COLOR` to
change it) precisely so "connected, nothing open" does not look like "broken".
Check what is actually there:

```bash
.local/display.sh status     # says "windows: none open" when it is simply empty
ss -tnp | grep 5900          # an ESTABLISHED line means your RDP client IS attached
```

If both look healthy the session is fine — open a browser and it will appear.

### The browser will not start: "Chromium distribution 'chrome' is not found"

`@playwright/mcp` defaults to the **chrome channel**, meaning a system-wide Google
Chrome at `/opt/google/chrome/chrome`, and its `--browser` flag accepts only
`chrome`, `firefox`, `webkit` and `msedge` — there is no value that selects the
Chromium `playwright install chromium` downloads. `playwright-mcp.sh` therefore
resolves Playwright's own bundled Chromium and passes it with `--executable-path`,
rather than requiring a root install of Chrome. It resolves the path through
Playwright's API because it contains a build number that changes on upgrade.

If you hit this error, the MCP server is running an older copy of that script —
restart your Claude session so it re-launches.

### The headed browser's window manager keeps dying

If `display.sh status` shows openbox stopped and its log ends with:

```
ICE default IO error handler doing an exit(), pid = ..., errno = 11
```

then openbox joined somebody else's desktop session and died with it. That happens
when it inherits `SESSION_MANAGER` from the shell that started it — typically because
`display.sh up` was run from inside an RDP session. It is launched with
`--sm-disable` and a cleared `SESSION_MANAGER` to prevent this; if you edit that
launch line, keep both.

## Development

Want to contribute? Great! Fork it, edit the scripts in `.local/` or the config in
`.ddev/`, and send a PR — or just send me a message.

## Disclaimer

**Read this section if you are coming from the Docker version — the security model has
changed.**

The old sandbox ran Claude with `--dangerously-skip-permissions` *inside a container*,
and the pitch was that malicious code could only reach the container and the project
folder mounted into it. **That is no longer how this works.** Claude now runs natively
on the machine hosting DDEV, with that user's full access: every repository in your home
directory, your SSH keys, your shell history, `~/.ddev/global_config.yaml` and any API
tokens in it.

So the boundary has moved outward, and it is now **the machine itself**. That is a
perfectly good boundary — if that machine is a VM you are willing to lose. It is a bad
one if it is your daily driver.

**Run this on a dedicated VM or a disposable machine.** Not on the laptop holding your
personal files.

What still holds:

- **The VM boundary is real.** On a Hyper-V or similar VM, a compromise is confined to
  that VM and does not reach the host's files.
- **The environment is disposable.** `ddev delete` and a fresh clone rebuild everything.

What you are accepting:

- **Supply-chain risk is real.** Packages from npm, PyPI and Packagist do get
  compromised through account takeovers, typosquatting and malicious updates. An npm
  `postinstall` script runs arbitrary code the moment a package is installed — before
  the project is ever run. WordPress plugins and themes from arbitrary sources are no
  safer.
- **The whole VM is in the blast radius**, not just one project folder. Anything on it
  can be read, changed, encrypted or exfiltrated.
- **Outbound internet is open.** Nothing here firewalls it, and Claude, WP-CLI,
  WordPress, Composer and Playwright all need it.
- **Secrets on the VM are reachable.** The `.env` and `.playwright-secrets` protections
  stop *Claude* from reading those files; they do not stop any other process the VM ends
  up running. A Pantheon machine token in `~/.ddev/global_config.yaml` is plaintext and
  is injected into every project's web container.
- **`ddev share` exposes the site publicly** while it runs. Be deliberate about it.

The accurate mental model: anything that goes wrong is confined to this VM and the
credentials reachable from it, and kept away from the host. That is a large and
worthwhile reduction in risk — and it is a smaller reduction than the container version
claimed. Use it at your own risk.

## License

MIT

**Free Software, Hell Yeah!**
