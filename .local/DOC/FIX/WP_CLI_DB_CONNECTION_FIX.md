# WP-CLI — "Error establishing a database connection" Fix

A runbook for when running `wp <command>` directly inside the **claude**
container fails with **`Error establishing a database connection`** (usually
alongside a burst of `Undefined array key "REQUEST_URI" / "HTTP_HOST"`
warnings), even though the WordPress site itself loads fine in the browser and
the `db` service is healthy.

---

## Symptoms

- Running any `wp ...` command from the claude container's shell prints:
  ```
  PHP Warning:  Undefined array key "REQUEST_URI" in ... eval()'d code
  PHP Warning:  Undefined array key "HTTP_HOST" in ... eval()'d code
  Error: Error establishing a database connection.
  ```
- The site works in the browser at `http://wordpress/`, so the database is
  clearly up and reachable.
- `getent hosts db` resolves, and a manual PHP `mysqli_connect("db","db","db","db")`
  **succeeds** — so the credentials and network are fine.
- The documented one-off runner
  `docker compose -f .local/docker-compose.yml run --rm wp-cli wp ...`
  is **not usable from inside the claude container** because `docker` is not
  installed there (`docker: command not found`).

---

## Root cause

Two things combine:

1. **`wp-config.php` gates the sandbox config on `$_ENV`, not `getenv()`.**
   The top of `wp-config.php` decides whether to load the local sandbox
   credentials (`wp-config.local.php`, which sets `DB_HOST=db`, `DB_USER=db`,
   `DB_PASSWORD=db`) like this:

   ```php
   if (isset($_ENV['PANTHEON_ENVIRONMENT']) && $_ENV['PANTHEON_ENVIRONMENT'] === 'local') {
       require_once(dirname(__FILE__) . '/wp-config.local.php');
       return;
   }
   ```

   It reads the **`$_ENV` superglobal**, not `getenv()`.

2. **PHP CLI doesn't populate `$_ENV` by default.** In this image the CLI
   `variables_order` is `GPCS` — note there is **no `E`**. So even though the
   container sets `PANTHEON_ENVIRONMENT=local` (visible via `getenv()`), it is
   **absent from `$_ENV`**:

   ```
   getenv:        local
   $_ENV:         (not in $_ENV)
   variables_order: GPCS
   ```

   Because the `$_ENV` check is false, `wp-config.php` skips
   `wp-config.local.php` and falls through to the placeholder defaults
   (`DB_PASSWORD = 'database_password'`, `DB_HOST = 'database_host'`, …) →
   the DB connection fails.

The `Undefined array key "REQUEST_URI"/"HTTP_HOST"` warnings are a related
side effect: `wp-config.local.php` reads `$_SERVER['HTTP_HOST']` etc., which
don't exist in a CLI (non-HTTP) context.

---

## Solution

Run WP-CLI with `variables_order` set to include `E`, so PHP populates `$_ENV`
and `wp-config.php` loads the sandbox credentials. Invoke the `wp` phar through
PHP with the `-d` override:

```bash
php -d variables_order=EGPCS /usr/local/bin/wp <command>
```

Example — list active plugins:

```bash
php -d variables_order=EGPCS /usr/local/bin/wp plugin list --status=active
```

The `Undefined array key` / `HTTP_HOST` CLI warnings are harmless noise; filter
them out for readable output if desired:

```bash
php -d variables_order=EGPCS /usr/local/bin/wp plugin list --status=active 2>&1 \
  | grep -viE 'Undefined array key|REQUEST_URI|HTTP_HOST|eval'
```

---

## Quick reference

- **Symptom:** `wp` → `Error establishing a database connection` + `REQUEST_URI`/`HTTP_HOST` warnings.
- **Cause:** `wp-config.php` checks `$_ENV['PANTHEON_ENVIRONMENT']`, but CLI `variables_order=GPCS` leaves `$_ENV` empty, so sandbox creds in `wp-config.local.php` never load.
- **Fix:** `php -d variables_order=EGPCS /usr/local/bin/wp <command>`
- **Do NOT** rely on `docker compose ... run wp-cli` from inside the claude container — `docker` isn't installed there.
