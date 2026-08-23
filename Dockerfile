# =====================================================================
# Stage 1: build Helix from source.
# Kept separate so the Rust toolchain (~1.5GB) never reaches the final image.
# bookworm base matches the runtime stage, so glibc versions line up.
# =====================================================================
FROM rust:1-bookworm AS helix-builder

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

# --- Match the host UID/GID so files written into /workspace aren't root-owned.
# ONLY NEEDED ON LINUX. Docker Desktop on macOS and Windows maps ownership
# through the file-sharing layer, so leave these at the default there.
# Linux: --build-arg UID=$(id -u) --build-arg GID=$(id -g)
ARG UID=1000
ARG GID=1000

ARG PYTHON_VERSION=3.12

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

RUN npm install -g @anthropic-ai/claude-code

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
