# Appended to DDEV's own web-container Dockerfile (no FROM line needed).
#
# Bakes the SASS toolchain into the web image so .sass/sass-runner.js can run
# there. These were baked into the old Claude image the same way, at the same
# pinned versions; bump them here and run `ddev restart` to rebuild.
#
# Why a fixed prefix instead of `npm install -g`:
# DDEV manages Node with `n`, so the global module root is version-dependent
# (/usr/local/n/lib/node_modules right now) and is replaced whenever
# nodejs_version changes in .ddev/config.yaml — which would silently strip the
# toolchain. Installing into a path we choose keeps it stable across Node
# upgrades, and .sass/sass.sh points NODE_PATH at exactly this directory.

ARG SANDBOX_SASS_VERSION=1.83.0
ARG SANDBOX_POSTCSS_VERSION=8.4.49
ARG SANDBOX_AUTOPREFIXER_VERSION=10.4.20

ENV SANDBOX_SASS_PREFIX=/usr/local/lib/sandbox-sass
ENV NODE_PATH=/usr/local/lib/sandbox-sass/node_modules

RUN mkdir -p "${SANDBOX_SASS_PREFIX}" \
 && npm install --prefix "${SANDBOX_SASS_PREFIX}" --no-save --no-audit --no-fund \
      sass@${SANDBOX_SASS_VERSION} \
      postcss@${SANDBOX_POSTCSS_VERSION} \
      autoprefixer@${SANDBOX_AUTOPREFIXER_VERSION} \
 && chmod -R a+rX "${SANDBOX_SASS_PREFIX}" \
 && node -e "require('sass');require('postcss');require('autoprefixer');console.log('sandbox sass toolchain OK')"
