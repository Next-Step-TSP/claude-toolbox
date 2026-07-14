# Custom image to run Claude Code in a Linux container, with an M365/Azure
# PowerShell admin toolbox baked in.
# Base: Node.js LTS (Claude Code is a Node CLI and needs Node 18+).
FROM node:22-bookworm-slim

# Pinned PowerShell version (latest stable 7.6 line as of build authoring).
ARG PWSH_VERSION=7.6.3

ENV DEBIAN_FRONTEND=noninteractive \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    NODE_NO_WARNINGS=1 \
    TERM=xterm-256color

# ---------------------------------------------------------------------------
# OS packages: dev/runtime tools + PowerShell deps + Python + gh CLI repo.
#   git, ripgrep, less, procps, openssh-client, curl, ca-certificates  -> dev basics + Claude Code
#   libicu72, libssl3, locales                                          -> PowerShell runtime deps
#   python3, python3-pip, python3-venv, python-is-python3               -> Python
#   gnupg                                                               -> apt key handling
# ---------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ripgrep less procps openssh-client curl wget ca-certificates gnupg \
        libicu72 libssl3 locales \
        python3 python3-pip python3-venv python-is-python3 \
    # --- GitHub CLI (official apt repo) ---
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
# so this is dormant for local interactive use.
# ---------------------------------------------------------------------------
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale tmux \
    && rm -rf /var/lib/apt/lists/* \
    # Tailscale SSH logs you in using the target user's login shell; make sure
    # the node user gets bash.
    && usermod -s /bin/bash node

# Entrypoint conditionally brings up Tailscale, then runs the command.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

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
# container start, so the baked-in version here is just a fallback for the
# very first run / fully offline use.
# ---------------------------------------------------------------------------
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default to launching Claude Code. Override with e.g. `bash` or `pwsh`.
CMD ["claude"]
