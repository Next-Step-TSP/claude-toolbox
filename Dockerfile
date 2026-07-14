# claude-toolbox: NSTSP standard Claude Code image, with an M365/Azure
# PowerShell admin toolbox, Tailscale SSH, tmux and an optional ttyd web
# terminal baked in.
#
# Base: Node.js 24 (Active LTS) on Debian 13 "trixie". Node 24 is the runtime
# Claude Code needs; trixie is the current Debian stable and the required
# foundation now that PowerShell dropped Debian 12 support (2026-06-10).
FROM node:24-trixie-slim

# OCI metadata (links the GHCR package back to the repo for provenance).
LABEL org.opencontainers.image.source="https://github.com/Next-Step-TSP/claude-toolbox" \
      org.opencontainers.image.title="claude-toolbox" \
      org.opencontainers.image.description="NSTSP standard Claude Code image: M365/Azure PowerShell toolbox, Tailscale SSH, tmux, optional ttyd web terminal."

# Pinned PowerShell version (latest 7.6 LTS line, .NET 10, as of build authoring).
ARG PWSH_VERSION=7.6.3
# Pinned ttyd release (see the ttyd install layer below for why this is a
# static binary rather than the trixie apt package).
ARG TTYD_VERSION=1.7.7

ENV DEBIAN_FRONTEND=noninteractive \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    NODE_NO_WARNINGS=1 \
    TERM=xterm-256color

# ---------------------------------------------------------------------------
# OS packages: dev/runtime tools + PowerShell deps + Python + gh CLI repo.
#   git, ripgrep, less, procps, openssh-client, curl, wget, ca-certificates  -> dev basics + Claude Code
#   libicu76, libssl3t64, locales                                            -> PowerShell runtime deps (trixie names)
#   tzdata                                                                    -> TZ support (trixie slim ships none)
#   python3, python3-pip, python3-venv, python-is-python3                     -> Python
#   gnupg                                                                     -> apt key handling
# NOTE: PowerShell's runtime deps on Debian 13 are libicu76 + libssl3t64. The
# bookworm names (libicu72 / libssl3) do not exist on trixie — libssl3 was
# renamed by the 64-bit time_t transition.
# ---------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ripgrep less procps openssh-client curl wget ca-certificates gnupg \
        libicu76 libssl3t64 locales tzdata \
        python3 python3-pip python3-venv python-is-python3 \
    # --- GitHub CLI (official apt repo; the repo line is codename-neutral) ---
    && mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# PowerShell 7.6 (pinned), installed from the official linux-x64 tarball.
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" \
        -o /tmp/pwsh.tar.gz \
    && mkdir -p /opt/microsoft/powershell/7 \
    && tar -xzf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7 \
    && chmod +x /opt/microsoft/powershell/7/pwsh \
    && ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh \
    && rm /tmp/pwsh.tar.gz \
    && pwsh --version

# ---------------------------------------------------------------------------
# PowerShell modules: Az, Microsoft.Graph (subset), PnP.PowerShell, EXO.
# Separate layer so it caches independently of the OS layer above.
# ---------------------------------------------------------------------------
COPY install-psmodules.ps1 /tmp/install-psmodules.ps1
RUN pwsh -NoLogo -NonInteractive -File /tmp/install-psmodules.ps1 \
    && rm /tmp/install-psmodules.ps1

# ---------------------------------------------------------------------------
# Tailscale (for phone/remote access via Tailscale SSH) + tmux (detachable
# sessions). tailscaled only runs when the entrypoint is told to (see below),
# so this is dormant for local interactive use. trixie apt channel.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale tmux \
    && rm -rf /var/lib/apt/lists/* \
    # Tailscale SSH logs you in using the target user's login shell; make sure
    # the node user gets bash.
    && usermod -s /bin/bash node

# ---------------------------------------------------------------------------
# ttyd web terminal (optional; entrypoint starts it only when TTYD_ENABLE=1).
# Installed from the pinned upstream static release binary rather than the
# Debian package: the trixie ttyd package inherits util-linux's dropped nested
# login support, and pinning the exact upstream version keeps builds
# reproducible. The static musl binary runs fine on trixie. --writable (-W),
# which the entrypoint uses, requires ttyd >= 1.7.
# ---------------------------------------------------------------------------
RUN curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.x86_64" \
        -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd \
    && ttyd --version

# Entrypoint conditionally brings up Tailscale/ttyd, then runs the command.
# healthcheck.sh backs the HEALTHCHECK below. Both are authored on Windows, so
# strip CRLF and mark executable.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
    && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

# ---------------------------------------------------------------------------
# npm global prefix owned by "node", not root.
#
# This directory lives inside /home/node, which is the claude-home named
# volume — so once it's populated it survives container recreation
# (docker compose run --rm), and both Claude Code's own built-in
# auto-updater AND the entrypoint's update step (below) can actually write
# to it. Installing as root into the default /usr/local prefix (the old
# approach) silently blocked both of those, which is why the version baked
# at build time never moved.
# ---------------------------------------------------------------------------
RUN mkdir -p /home/node/.npm-global \
    && chown -R node:node /home/node/.npm-global
ENV NPM_CONFIG_PREFIX=/home/node/.npm-global \
    PATH=/home/node/.npm-global/bin:$PATH

# Docker's ENV above only applies to processes Docker execs directly
# (entrypoint.sh and its children). Tailscale SSH sets up a fresh login
# session via PAM, which does NOT inherit that — it reads /etc/environment
# instead. Without this, `claude` is "command not found" over SSH even
# though it runs fine via `docker compose run`.
RUN { \
        echo "NPM_CONFIG_PREFIX=/home/node/.npm-global"; \
        echo "PATH=/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
    } >> /etc/environment

# Run as the non-root "node" user shipped by the base image (uid 1000).
# (The remote/Tailscale service overrides this to root, which tailscaled needs.)
USER node

# ---------------------------------------------------------------------------
# Claude Code. No version pin — the entrypoint re-installs @latest on every
# container start (unless UPDATE_CLAUDE_ON_START=0), so the baked-in version
# here is just a fallback for the very first run / fully offline use.
# ---------------------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

WORKDIR /workspace

# Healthcheck: with Tailscale enabled, verify the tailnet backend; otherwise a
# basic liveness check. start-period covers tailscaled join + first update.
HEALTHCHECK --interval=1m --timeout=10s --start-period=45s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default to launching Claude Code. Override with e.g. `bash` or `pwsh`.
CMD ["claude"]
