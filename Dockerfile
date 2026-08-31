# =====================================================================
# Stage 1: build Helix from source.
# Kept separate so the Rust toolchain (~1.5GB) never reaches the final image.
# bookworm base matches the runtime stage, so glibc versions line up.
# =====================================================================
FROM rust:1-bookworm AS helix-builder

# Extra CA certs for networks that TLS-inspect outbound traffic (corporate
# proxies, Zscaler, Cloudflare Gateway, etc). Drop *.crt files into ./certs;
# the directory is empty by default so this is a no-op otherwise.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates

ARG HELIX_REPO=https://github.com/theproductiveprogrammer/helix.git
# Pin to a branch, tag, or commit. Change this to force a rebuild of the layer.
ARG HELIX_REF=master

RUN git clone --depth 1 --branch "${HELIX_REF}" "${HELIX_REPO}" /src/helix \
    || git clone "${HELIX_REPO}" /src/helix && git -C /src/helix checkout "${HELIX_REF}"

WORKDIR /src/helix

# Builds the hx binary into /opt/helix/bin and compiles the tree-sitter
# grammars into ./runtime/grammars. Needs network access to fetch grammar
# sources from GitHub. Set HELIX_DISABLE_AUTO_GRAMMAR_BUILD=1 to skip them.
RUN cargo install --path helix-term --locked --root /opt/helix

# The runtime dir (queries, themes, tutor, and the grammars just built) has to
# travel with the binary or syntax highlighting silently does nothing.
RUN cp -r /src/helix/runtime /opt/helix/runtime


# =====================================================================
# Stage 2: the actual container.
# =====================================================================
FROM node:22-bookworm

# Extra CA certs for networks that TLS-inspect outbound traffic (see the
# helix-builder stage above for details). Node/npm ship their own CA bundle
# and ignore the OS trust store, so update-ca-certificates alone isn't
# enough here — NODE_EXTRA_CA_CERTS points Node at the same certs too. The
# bundle file always exists (even empty) so this is a no-op when certs/ is.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates \
    && cat /usr/local/share/ca-certificates/*.crt > /usr/local/share/ca-certificates/extra-ca-bundle.pem 2>/dev/null; \
    true
ENV NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/extra-ca-bundle.pem

# --- Match the host UID/GID so files written into /workspace aren't root-owned.
# ONLY NEEDED ON LINUX. Docker Desktop on macOS and Windows maps ownership
# through the file-sharing layer, so leave these at the default there.
# Linux: --build-arg UID=$(id -u) --build-arg GID=$(id -g)
ARG UID=1000
ARG GID=1000

ARG PYTHON_VERSION=3.12

# Override on networks that block the public npm registry (e.g. a corporate
# policy requiring an internal Artifactory/Nexus/JFrog mirror):
# --build-arg NPM_REGISTRY=https://your-mirror/api/npm/npm-virtual/
ARG NPM_REGISTRY=https://registry.npmjs.org
ENV NPM_CONFIG_REGISTRY=${NPM_REGISTRY}

# --- System packages.
# ripgrep is used by Claude Code's search tooling; the lib*-dev set is only
# needed if mise has to compile Python from source rather than fetching a
# precompiled build. Drop them if you want a smaller image and precompiled
# builds work for your platform.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        vim \
        less \
        ripgrep \
        unzip \
        build-essential \
        libbz2-dev \
        libffi-dev \
        liblzma-dev \
        libreadline-dev \
        libsqlite3-dev \
        libssl-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Headless browser for screenshots and page checks.
# The claude-in-chrome extension lives in the host's Chrome and can't be
# reached from inside the container, so we ship Playwright's Chromium plus the
# Playwright MCP server instead. Browsers go under /opt so the node user finds
# them without a per-user cache; --with-deps pulls in the shared libs Chromium
# needs on bookworm. The MCP server is wired up by the launcher via
# --mcp-config /opt/claude-box/mcp.json.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# Understand: the browser build must come from the Playwright version bundled
# inside @playwright/mcp, not whatever `npx playwright` resolves to, or the
# build numbers won't match and launch fails with "Executable doesn't exist".
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm install -g @playwright/mcp \
    && node /usr/local/lib/node_modules/@playwright/mcp/node_modules/playwright/cli.js \
         install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* \
    && chmod -R a+rX /opt/ms-playwright
RUN mkdir -p /opt/claude-box && cat > /opt/claude-box/mcp.json <<'JSON'
{
  "mcpServers": {
    "playwright": {
      "command": "playwright-mcp",
      "args": ["--browser", "chromium", "--headless", "--no-sandbox"]
    }
  }
}
JSON

# --- Helix, from the builder stage.
COPY --from=helix-builder /opt/helix/bin/hx /usr/local/bin/hx
COPY --from=helix-builder /opt/helix/runtime /opt/helix/runtime
ENV HELIX_RUNTIME=/opt/helix/runtime

ENV EDITOR=hx
ENV VISUAL=hx

RUN set -eu; \
    if [ "$UID" != "1000" ] || [ "$GID" != "1000" ]; then \
        # The target GID may already belong to a Debian system group (e.g. 20
        # is dialout, which collides with macOS's staff). In that case just
        # join the existing group rather than renumbering node's own group.
        if ! getent group "$GID" >/dev/null; then \
            groupmod -g "$GID" node; \
        fi; \
        usermod -u "$UID" -g "$GID" node; \
        chown -R "$UID:$GID" /home/node; \
    fi

# Pre-create the config dir so the named volume mounted here inherits
# node:node ownership instead of being created empty and root-owned.
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude

USER node
ENV HOME=/home/node

# --- Claude Code config.
# CLAUDE_CONFIG_DIR moves ~/.claude.json inside the volume, so the OAuth
# account and per-project trust survive container restarts.
ENV CLAUDE_CONFIG_DIR=/home/node/.claude

# --- mise.
# Shims go on PATH ahead of everything so tools resolve in non-login shells
# too (Claude Code's Bash tool doesn't always give you a login shell).
ENV PATH=/home/node/.local/share/mise/shims:/home/node/.local/bin:$PATH

# --- Claude Code, via the native installer (same as it's installed on the
# host) rather than npm. It downloads a self-contained binary straight from
# claude.ai into ~/.local, so it needs no npm registry access at all and
# sidesteps npm mirror/auth/caching issues entirely.
RUN curl -fsSL https://claude.ai/install.sh | bash

# Trust the project config without an interactive prompt, and don't block on
# confirmations for unattended installs.
ENV MISE_TRUSTED_CONFIG_PATHS=/workspace
ENV MISE_YES=1

RUN curl -fsSL https://mise.run | sh

# Interactive shells get full activation (env vars, PATH hooks on cd).
RUN echo 'eval "$(mise activate bash)"' >> /home/node/.bashrc

# Baseline Python + uv, globally available regardless of what a project's
# mise.toml pins. A project mise.toml in /workspace overrides these.
RUN mise use -g "python@${PYTHON_VERSION}" uv@latest \
    && mise reshim \
    && python --version \
    && uv --version

RUN hx --version

WORKDIR /workspace

CMD ["bash"]
