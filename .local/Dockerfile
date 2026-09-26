FROM node:22-bookworm-slim

ARG TZ=Etc/UTC
ENV TZ=$TZ

# @playwright/mcp version — keep in sync with .mcp.json
ARG PLAYWRIGHT_MCP_VERSION=0.0.75

# Pinned SASS toolchain (Dart Sass + PostCSS + Autoprefixer).
# Bump these when you want a newer toolchain; rebuild with rebuild-claude.sh.
ARG SASS_VERSION=1.83.0
ARG POSTCSS_VERSION=8.4.49
ARG AUTOPREFIXER_VERSION=10.4.20

# php-gd / php-imagick: WordPress' two image editors. The wordpress image ships
# both; this container runs its own php-cli (for the WP-CLI phar above), so
# without them `wp media regenerate`, `wp media import`, and anything else that
# resizes an image fails for want of an editor. Verify with
# `php .local/check-image-support.php`.
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl ca-certificates sudo less procps jq ripgrep nano vim \
    openssh-client gnupg dnsutils iputils-ping \
    x11-apps \
    php-cli php-mysql php-mbstring php-curl php-zip php-xml \
    php-gd php-imagick \
    mariadb-client \
 && rm -rf /var/lib/apt/lists/* \
 && curl -sL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp

ENV NPM_CONFIG_PREFIX=/home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:$PATH
ENV NODE_PATH=/home/node/.npm-global/lib/node_modules
ENV PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright

USER node
WORKDIR /workspace

RUN mkdir -p /home/node/.npm-global /home/node/.cache/ms-playwright /home/node/.claude \
 && npm install -g \
      @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} \
      sass@${SASS_VERSION} \
      postcss@${POSTCSS_VERSION} \
      autoprefixer@${AUTOPREFIXER_VERSION}

USER root
RUN npx -y playwright install --with-deps chrome \
 && chown -R node:node /home/node/.cache/ms-playwright

# @anthropic-ai/claude-code, deliberately last and on its own line.
# "latest" so a fresh build always gets the current release; site-control.sh's
# "Update Claude CLI" option re-builds with this pinned to a resolved version
# number, which invalidates the cache from here down only — everything
# expensive (apt, Chrome) is already behind us. The ARG is declared here, not
# at the top of the file, for the same reason: the classic builder invalidates
# every layer after an ARG whose value changed.
USER node
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

RUN printf '%s' '{"hasCompletedOnboarding":true}' > /home/node/.claude.json \
 && printf '%s' '{"skipDangerousModePermissionPrompt":true,"enableAllProjectMcpServers":true}' > /home/node/.claude/settings.json
CMD ["bash"]
