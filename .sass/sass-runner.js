#!/usr/bin/env node
/*
 * sass-runner.js — reads .sass/SASS.settings.json and compiles/watches SCSS.
 *
 * Invoked by .sass/sass.sh, which runs it inside the DDEV web container.
 * `sass`, `postcss` and `autoprefixer` are baked into that image by
 * .ddev/web-build/Dockerfile and found via NODE_PATH.
 *
 * Usage:
 *   node sass-runner.js compile   # one-shot
 *   node sass-runner.js watch     # initial compile + watch
 *
 * Settings file shape (.sass/SASS.settings.json):
 *   {
 *     "defaults": {
 *       "style": "expanded",
 *       "sourceMap": true,
 *       "extensionName": ".css",
 *       "autoprefixer": false
 *     },
 *     "compilations": [
 *       { "input": "wp-content/themes/x/scss", "output": "wp-content/themes/x/css" },
 *       { "input": "...", "output": "...", "style": "compressed", "extensionName": ".min.css", "autoprefixer": true }
 *     ]
 *   }
 *
 * Paths are resolved relative to PROJECT_ROOT, which is derived from this
 * file's own location (.sass/..). That makes it correct both inside the web
 * container (/var/www/html) and on the host, without hardcoding either.
 */

const fs = require('fs');
const path = require('path');

let sass, postcss, autoprefixer;
try {
  sass = require('sass');
  postcss = require('postcss');
  autoprefixer = require('autoprefixer');
} catch (e) {
  console.error('[sass-runner] Failed to load sass/postcss/autoprefixer.');
  console.error('             These should be baked into the image. Try rebuild-claude.sh.');
  console.error('             Original error: ' + e.message);
  process.exit(2);
}

// Derived from this file's location rather than hardcoded: under Docker this
// was always /workspace, but DDEV mounts the project at /var/www/html and the
// same script is useful straight from the host.
const PROJECT_ROOT = path.resolve(__dirname, '..');
const SETTINGS_PATH = path.join(PROJECT_ROOT, '.sass', 'SASS.settings.json');
const EXAMPLE_PATH = path.join(PROJECT_ROOT, '.sass', 'SASS.settings.example.json');

const HARD_DEFAULTS = {
  style: 'expanded',
  sourceMap: true,
  extensionName: '.css',
  autoprefixer: false,
};

function loadSettings() {
  if (!fs.existsSync(SETTINGS_PATH)) {
    console.error(`[sass-runner] Settings file not found: ${SETTINGS_PATH}`);
    console.error(`             Copy ${path.relative(PROJECT_ROOT, EXAMPLE_PATH)} to`);
    console.error(`             ${path.relative(PROJECT_ROOT, SETTINGS_PATH)} and edit it.`);
    process.exit(2);
  }
  let raw, parsed;
  try {
    raw = fs.readFileSync(SETTINGS_PATH, 'utf8');
  } catch (e) {
    console.error(`[sass-runner] Could not read ${SETTINGS_PATH}: ${e.message}`);
    process.exit(2);
  }
  try {
    parsed = JSON.parse(raw);
  } catch (e) {
    console.error(`[sass-runner] Invalid JSON in ${SETTINGS_PATH}: ${e.message}`);
    process.exit(2);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    console.error(`[sass-runner] Settings root must be an object with a "compilations" array.`);
    process.exit(2);
  }
  if (!Array.isArray(parsed.compilations) || parsed.compilations.length === 0) {
    console.error(`[sass-runner] "compilations" must be a non-empty array.`);
    process.exit(2);
  }
  return parsed;
}

function mergeOptions(globalDefaults, entry) {
  return Object.assign({}, HARD_DEFAULTS, globalDefaults || {}, entry);
}

function resolvePath(p) {
  if (typeof p !== 'string' || !p.length) {
    throw new Error('input/output paths must be non-empty strings');
  }
  return path.isAbsolute(p) ? p : path.resolve(PROJECT_ROOT, p);
}

function isSassFile(name) {
  return /\.(scss|sass)$/i.test(name);
}

function isPartial(filePath) {
  return path.basename(filePath).startsWith('_');
}

function walkSassFiles(dir) {
  const out = [];
  const stack = [dir];
  while (stack.length) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch (e) {
      continue;
    }
    for (const e of entries) {
      const full = path.join(current, e.name);
      if (e.isDirectory()) stack.push(full);
      else if (e.isFile() && isSassFile(e.name) && !isPartial(e.name)) out.push(full);
    }
  }
  return out;
}

async function compileOne(srcFile, destFile, opts) {
  const result = sass.compile(srcFile, {
    style: opts.style === 'compressed' ? 'compressed' : 'expanded',
    sourceMap: !!opts.sourceMap,
    loadPaths: [path.dirname(srcFile)],
  });

  let css = result.css;
  let mapObj = result.sourceMap; // object | undefined

  if (opts.autoprefixer) {
    const overrideBrowserslist = Array.isArray(opts.autoprefixer) ? opts.autoprefixer : undefined;
    const plugins = [autoprefixer(overrideBrowserslist ? { overrideBrowserslist } : {})];
    const postOpts = { from: srcFile, to: destFile };
    if (opts.sourceMap && mapObj) {
      postOpts.map = { prev: JSON.stringify(mapObj), inline: false, annotation: false };
    } else {
      postOpts.map = false;
    }
    const postResult = await postcss(plugins).process(css, postOpts);
    css = postResult.css;
    mapObj = postResult.map ? JSON.parse(postResult.map.toString()) : undefined;
  }

  fs.mkdirSync(path.dirname(destFile), { recursive: true });

  if (opts.sourceMap && mapObj) {
    const mapFile = destFile + '.map';
    fs.writeFileSync(mapFile, JSON.stringify(mapObj));
    // Strip any trailing sourceMappingURL the upstream emitted, then append our own.
    css = css.replace(/\n?\/\*#\s*sourceMappingURL=.*?\*\/\s*$/m, '');
    css = css.replace(/\s+$/, '') + `\n\n/*# sourceMappingURL=${path.basename(mapFile)} */\n`;
  }

  fs.writeFileSync(destFile, css);
}

function planEntry(entry) {
  const inputAbs = resolvePath(entry.input);
  const outputAbs = resolvePath(entry.output);
  if (!fs.existsSync(inputAbs)) throw new Error(`input not found: ${entry.input}`);
  const stat = fs.statSync(inputAbs);
  const pairs = [];
  if (stat.isFile()) {
    if (isPartial(inputAbs)) throw new Error(`refusing to compile partial directly: ${entry.input}`);
    if (!isSassFile(inputAbs)) throw new Error(`input file is not .scss/.sass: ${entry.input}`);
    pairs.push({ src: inputAbs, dest: outputAbs });
  } else if (stat.isDirectory()) {
    const files = walkSassFiles(inputAbs);
    for (const src of files) {
      const rel = path.relative(inputAbs, src);
      const dest = path.join(outputAbs, rel).replace(/\.(scss|sass)$/i, '');
      pairs.push({ src, dest });
    }
  } else {
    throw new Error(`input is neither file nor directory: ${entry.input}`);
  }
  return { inputAbs, outputAbs, isDir: stat.isDirectory(), pairs };
}

function relForLog(p) {
  return path.relative(PROJECT_ROOT, p) || p;
}

async function compileAll(settings) {
  let failed = 0;
  let succeeded = 0;
  for (let i = 0; i < settings.compilations.length; i++) {
    const entry = settings.compilations[i];
    const opts = mergeOptions(settings.defaults, entry);
    console.log(`\n[${i + 1}/${settings.compilations.length}] ${entry.input}  →  ${entry.output}`);
    let plan;
    try {
      plan = planEntry(entry);
    } catch (e) {
      console.error(`  ✗ ${e.message}`);
      failed++;
      continue;
    }
    for (const { src, dest } of plan.pairs) {
      // For folder-mode, apply extensionName; for file-mode, dest is already a full path.
      const finalDest = plan.isDir ? dest + opts.extensionName : dest;
      try {
        await compileOne(src, finalDest, opts);
        console.log(`  ✓ ${relForLog(src)}  →  ${relForLog(finalDest)}`);
        succeeded++;
      } catch (e) {
        const msg = (e && e.sassMessage) ? e.sassMessage : (e && e.message) ? e.message : String(e);
        const loc = (e && e.span && e.span.url)
          ? ` (${e.span.url.pathname || e.span.url}:${(e.span.start && e.span.start.line + 1) || '?'})`
          : '';
        console.error(`  ✗ ${relForLog(src)}${loc}`);
        console.error(`    ${msg.split('\n').join('\n    ')}`);
        failed++;
      }
    }
  }
  return { failed, succeeded };
}

async function runCompile() {
  const settings = loadSettings();
  console.log(`[sass-runner] compile: ${settings.compilations.length} entr${settings.compilations.length === 1 ? 'y' : 'ies'}`);
  const { failed, succeeded } = await compileAll(settings);
  console.log('');
  if (failed === 0) {
    console.log(`[sass-runner] OK (${succeeded} file${succeeded === 1 ? '' : 's'})`);
    process.exit(0);
  } else {
    console.error(`[sass-runner] ${succeeded} ok, ${failed} failed`);
    process.exit(1);
  }
}

async function runWatch() {
  let settings = loadSettings();
  console.log(`[sass-runner] watch: initial compile (${settings.compilations.length} entr${settings.compilations.length === 1 ? 'y' : 'ies'})`);
  await compileAll(settings);

  const watchDirs = new Set();
  function addWatchersFor(settings) {
    for (const entry of settings.compilations) {
      try {
        const inputAbs = resolvePath(entry.input);
        if (!fs.existsSync(inputAbs)) continue;
        const stat = fs.statSync(inputAbs);
        const dir = stat.isDirectory() ? inputAbs : path.dirname(inputAbs);
        if (watchDirs.has(dir)) continue;
        watchDirs.add(dir);
        fs.watch(dir, { recursive: true }, (eventType, filename) => {
          if (!filename) return;
          if (!isSassFile(filename)) return;
          scheduleRecompile(filename);
        });
        console.log(`[sass-runner] watching: ${relForLog(dir)}`);
      } catch (e) {
        console.error(`[sass-runner] could not watch ${entry.input}: ${e.message}`);
      }
    }
  }

  // Also watch the settings file so edits take effect without a restart.
  let settingsTimer = null;
  fs.watch(SETTINGS_PATH, () => {
    if (settingsTimer) clearTimeout(settingsTimer);
    settingsTimer = setTimeout(() => {
      try {
        const next = loadSettings();
        settings = next;
        console.log(`\n[sass-runner] settings reloaded; recompiling…`);
        compileAll(settings).catch((e) => console.error(e));
        addWatchersFor(settings);
      } catch (e) {
        console.error(`[sass-runner] failed to reload settings: ${e.message}`);
      }
    }, 100);
  });

  let pending = null;
  let lastTrigger = '';
  function scheduleRecompile(trigger) {
    lastTrigger = trigger;
    if (pending) clearTimeout(pending);
    pending = setTimeout(async () => {
      pending = null;
      console.log(`\n[sass-runner] change: ${lastTrigger} → recompiling…`);
      await compileAll(settings);
    }, 150);
  }

  addWatchersFor(settings);
  console.log(`\n[sass-runner] ready. Ctrl+C to stop.`);
}

const mode = process.argv[2];
if (mode === 'compile') {
  runCompile().catch((e) => {
    console.error(`[sass-runner] fatal: ${e.message}`);
    process.exit(2);
  });
} else if (mode === 'watch') {
  runWatch().catch((e) => {
    console.error(`[sass-runner] fatal: ${e.message}`);
    process.exit(2);
  });
} else {
  console.error('Usage: sass-runner.js <compile|watch>');
  process.exit(2);
}
