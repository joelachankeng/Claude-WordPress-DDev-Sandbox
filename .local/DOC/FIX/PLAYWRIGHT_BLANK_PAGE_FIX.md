# Playwright MCP — Blank Page / Hanging Screenshots Fix

A runbook for when the Playwright MCP browser shows a **blank/white page** and
**screenshots hang or time out**, even though the page's HTML/CSS is clearly
present in the DOM and the same URL renders fine in a normal browser.

---

## Symptoms

- A dashboard page (e.g. `wp-admin/admin.php?page=wpforo-overview`, or even the
  plain Dashboard) renders as a **wide white/blank page** in Playwright.
- Inspecting the DOM shows the **content is actually there** — real elements,
  styles, text, correct colors, no overlay covering them.
- `browser_take_screenshot` **times out** with:
  ```
  waiting for fonts to load...
  fonts loaded
  (then hangs / 5000ms timeout exceeded)
  ```
- Element screenshots hang at `waiting for element to be stable`.
- The same page in a **normal browser on the host looks fine**.
- **Restarting the browser fixes it temporarily**, but it **breaks again after
  navigating** to another page (or even after a few seconds, no navigation
  needed).

---

## Root cause

The Playwright MCP server launches Chrome **headed** (the `@playwright/mcp`
default — "headed by default"), and in this WSL2/container setup Chrome renders
to an **X server on the Windows host**:

```
DISPLAY=host.docker.internal:0.0      # no local Xvfb, no local X sockets
```

In **headed** mode, Chrome's frame production (the compositor's BeginFrame /
vsync loop) is tied to that external window's state. When the window is
idle / unfocused / occluded / minimized on the Windows desktop, the X server
stops driving paints, so:

- Chrome produces **zero rendering frames** → the surface is never painted →
  **blank white page**.
- `page.screenshot()` waits for a fresh composited frame that never arrives →
  **hang**.
- A **restart** maps a fresh window that gets an initial paint (works for a few
  seconds), then it settles back into the no-frames state → **breaks again on
  next navigation**.
- A normal host browser is a real, visible, foregrounded window that is
  continuously painted → **looks fine**.

### How it was diagnosed (key signal)

The decisive probe — run via `browser_evaluate`:

```js
async () => {
  let n = 0, stop = false;
  const tick = () => { n++; if (!stop) requestAnimationFrame(tick); };
  requestAnimationFrame(tick);
  await new Promise(r => setTimeout(r, 500));
  stop = true;
  return { rafCountIn500ms: n, hasFocus: document.hasFocus(),
           visibility: document.visibilityState };
}
```

- **Broken state:** `rafCountIn500ms: 0` while `visibility: "visible"` →
  `requestAnimationFrame` is NOT firing = no frames being produced = blank +
  screenshot hang. Plain JS and `setTimeout` still run (that's why the DOM looks
  complete when inspected).
- **Healthy state:** `rafCountIn500ms: ~28–31` (≈60fps).

Things that were **ruled out** (not the cause): the wpForo page itself, its
CSS/JS, the stuck loading spinner (`.wpf-admin-loading-ico`), the
`$(...).pointer is not a function` console error, the `CDPScreenshotNewSurface`
feature, the 64 MB `/dev/shm`, navigation count, memory/OOM, and duplicate
browser instances. Fresh **headless** browsers never reproduced it; the
long-lived **headed-on-remote-X** browser did.

---

## The fix

Switch Chrome to a **free-running frame source** that no longer waits on the
remote X server's vsync, by adding launch flags via the MCP server's config.
This keeps the browser **headed** (you still get a visible window) but keeps it
painting when idle/occluded.

### Files

**1. `/workspace/.playwright-mcp-config.json`** (the flags)

```json
{
  "browser": {
    "launchOptions": {
      "args": [
        "--disable-gpu-vsync",
        "--disable-frame-rate-limit",
        "--disable-features=CalculateNativeWinOcclusion"
      ]
    }
  }
}
```

**2. `/workspace/.local/.mcp.json`** — point the MCP server at that config.

> ⚠️ This is the file that Claude Code **actually** loads (it is started with
> `claude … --mcp-config /workspace/.local/.mcp.json`). Editing other
> `.mcp.json` files (e.g. the plugin marketplace one) has **no effect**. Confirm
> the real one via the process tree:
> `tr '\0' ' ' < /proc/1/cmdline` → look for `--mcp-config <path>`.

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": [
        "-y",
        "@playwright/mcp@0.0.75",
        "--no-sandbox",
        "--output-dir",
        "/workspace/.playwright-mcp/",
        "--config",
        "/workspace/.playwright-mcp-config.json"
      ]
    }
  }
}
```

**3. Restart the MCP server** (restart Claude Code / reconnect the `playwright`
server) so the new launch args take effect.

---

## ⚠️ Stale profile lock on restart

After a restart, the **first** navigation often fails with:

```
Error: Browser is already in use for
/home/node/.cache/ms-playwright/mcp-chrome-c52ddf6,
use --isolated to run multiple instances of the same browser
```

This happens because the previous browser didn't exit cleanly and left
`Singleton*` lock files behind. Clear them:

```bash
P=/home/node/.cache/ms-playwright/mcp-chrome-c52ddf6
# kill any chrome still bound to that profile
for pid in $(pgrep -x chrome); do
  tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | grep -q -- "mcp-chrome-c52ddf6" \
    && kill -9 "$pid" 2>/dev/null
done
rm -f "$P"/SingletonLock "$P"/SingletonCookie "$P"/SingletonSocket
```

Then navigate again — it will launch a fresh browser.

> If this becomes a recurring annoyance, add `--isolated` to the server args to
> skip the persistent profile entirely (trade-off: login sessions are not saved
> between restarts).

---

## How to verify the fix is live

1. **Flags on the running Chrome:**
   ```bash
   for pid in $(pgrep -x chrome); do
     cl=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
     echo "$cl" | grep -q -- "mcp-chrome-c52ddf6" && ! echo "$cl" | grep -q -- "--type=" \
       && echo "$cl" | tr ' ' '\n' | grep -E "gpu-vsync|frame-rate-limit|CalculateNativeWinOcclusion"
   done
   ```
   Should print the three flags.

2. **Frames are flowing:** run the `requestAnimationFrame` probe above →
   `rafCountIn500ms` should be ~28–31 (not 0).

3. **Screenshot works** on the previously-blank page, instantly, showing real
   content. Confirm it still works **after navigating** to another page (that
   was the original recurring symptom).

---

## If it STILL goes blank after all this

The flags can't cover a window that is fully unmapped/minimized on the Windows
side. Guaranteed fallbacks:

- **Headless** — add `"headless": true` under `launchOptions` in
  `/workspace/.playwright-mcp-config.json`. Most reliable; no visible window.
- **Local Xvfb** — run a virtual X server inside the container and point
  `DISPLAY` at it instead of `host.docker.internal:0.0`. Keeps a "window" that
  is always considered visible.

---

## One-line mental model

> Headed Chrome rendering to a remote/occluded X window stops producing frames →
> blank page + hanging screenshots. Decouple frames from display vsync
> (`--disable-gpu-vsync --disable-frame-rate-limit`) via the config that
> `/workspace/.local/.mcp.json` actually loads, then restart. Verify with the
> `requestAnimationFrame` probe (0 = broken, ~30 = healthy).
