#!/usr/bin/env bash
# Container entrypoint.
#
# If Tailscale is enabled (TS_AUTHKEY set, or TS_ENABLE=1 with persisted state),
# bring up tailscaled with Tailscale SSH so the box is reachable on your tailnet.
# Otherwise this is a no-op and we just run the given command — so local
# interactive use (docker compose run --rm claude) is unaffected.
#
# Every feature added beyond the original local/remote flow is env-gated and
# defaults to the previous behaviour, so existing compose setups keep working
# unchanged.
set -euo pipefail

# PATH as baked into /etc/environment (Dockerfile). Reused whenever we launch a
# process as the node user from a root entrypoint (runuser does not source a
# login shell), so `claude`, `ttyd`, `tmux` etc. resolve.
NODE_PATH_ENV="/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------------------------------------------------------------------------
# PUID/PGID/TZ/UMASK (Unraid-style). Only meaningful when we start as root
# (the remote/Unraid service); the node user is remapped so bind-mounted files
# land with the host's ownership. Defaults (unset) keep the base image's
# uid/gid 1000. Applied before anything creates files under /home/node.
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    cur_uid="$(id -u node)"
    cur_gid="$(id -g node)"
    if [ -n "${PGID:-}" ] && [ "${PGID}" != "${cur_gid}" ]; then
        groupmod -o -g "${PGID}" node
    fi
    if [ -n "${PUID:-}" ] && [ "${PUID}" != "${cur_uid}" ]; then
        usermod -o -u "${PUID}" node
    fi
    # Re-own key dirs only when the top-level owner actually drifted — /home/node
    # can be large (persisted volume), so avoid a blind recursive chown on every
    # start. usermod -u does not re-own existing files, hence this step.
    want_uid="$(id -u node)"
    want_gid="$(id -g node)"
    for d in /home/node /var/lib/tailscale; do
        [ -d "${d}" ] || continue
        owner="$(stat -c '%u' "${d}" 2>/dev/null || echo '')"
        if [ "${owner}" != "${want_uid}" ]; then
            chown -R "${want_uid}:${want_gid}" "${d}" 2>/dev/null || true
        fi
    done
    # Timezone: needs /etc write access, so root-only. tzdata is in the image.
    if [ -n "${TZ:-}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
        ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
    fi
fi

# UMASK applies to whatever user we are (root or node).
if [ -n "${UMASK:-}" ]; then
    umask "${UMASK}" 2>/dev/null || echo "entrypoint: invalid UMASK='${UMASK}' — ignoring." >&2
fi

# ---------------------------------------------------------------------------
# run_as_node: run a command as the node user. When the entrypoint is root
# (remote/Unraid), drop to node via runuser with a login-like environment
# (HOME + PATH). When already node (local), run directly.
# ---------------------------------------------------------------------------
run_as_node() {
    if [ "$(id -u)" -eq 0 ]; then
        runuser -u node -- env HOME=/home/node PATH="${NODE_PATH_ENV}" "$@"
    else
        env HOME=/home/node PATH="${NODE_PATH_ENV}" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Belt-and-suspenders for SSH logins: the /etc/environment fix (Dockerfile)
# only takes effect on a rebuilt image, but ~/.bashrc and ~/.profile live in
# /home/node — the persisted claude-home volume — so an *existing* volume
# from before this fix wouldn't have them. Add idempotently on every start.
# ---------------------------------------------------------------------------
for rcfile in /home/node/.bashrc /home/node/.profile; do
    if ! grep -q NPM_CONFIG_PREFIX "$rcfile" 2>/dev/null; then
        {
            echo ''
            echo '# Added for Claude Code (npm global installs as non-root "node" user).'
            echo 'export NPM_CONFIG_PREFIX=/home/node/.npm-global'
            echo 'export PATH=/home/node/.npm-global/bin:$PATH'
        } >> "$rcfile"
    fi
done

# ---------------------------------------------------------------------------
# Multi-account Claude Code profiles.
#
# Each name in CLAUDE_PROFILES (space-separated) gets an isolated config dir
# ~/.claude-<name> and a shell function claude-<name> that launches Claude Code
# against it — separate login / settings / history per account, so two accounts
# can run side-by-side. This block is regenerated in ~/.bashrc on every start,
# so the setup survives even a wipe of the claude-home volume (the per-profile
# logins themselves live in the volume and would need a fresh /login after a
# reset — but the commands are always here).
# ---------------------------------------------------------------------------
CLAUDE_PROFILES="${CLAUDE_PROFILES:-nstsp extra}"
BASHRC=/home/node/.bashrc
PROF_START="# >>> claude multi-account profiles >>>"
PROF_END="# <<< claude multi-account profiles <<<"
[ -f "$BASHRC" ] && sed -i "/$PROF_START/,/$PROF_END/d" "$BASHRC"
{
    echo "$PROF_START"
    for p in $CLAUDE_PROFILES; do
        echo "claude-$p() { mkdir -p \"\$HOME/.claude-$p\"; CLAUDE_CONFIG_DIR=\"\$HOME/.claude-$p\" claude \"\$@\"; }"
    done
    echo "$PROF_END"
} >> "$BASHRC"
for p in $CLAUDE_PROFILES; do
    mkdir -p "/home/node/.claude-$p" 2>/dev/null || true
done
# Fix ownership in case we created these as root (remote service runs as root).
chown node:node "$BASHRC" /home/node/.claude-* 2>/dev/null || true

# ---------------------------------------------------------------------------
# Keep Claude Code current. The npm global prefix is owned by "node" (see
# Dockerfile), so this works whether we're running as node (local service) or
# root (remote service). Failures (e.g. offline) are non-fatal — fall back to
# whatever is already installed. Gated by UPDATE_CLAUDE_ON_START (default 1).
# ---------------------------------------------------------------------------
UPDATE_CLAUDE_ON_START="${UPDATE_CLAUDE_ON_START:-1}"

update_claude_code() {
    if [ "${UPDATE_CLAUDE_ON_START}" != "1" ]; then
        echo "entrypoint: UPDATE_CLAUDE_ON_START=${UPDATE_CLAUDE_ON_START} — skipping Claude Code self-update."
        return 0
    fi
    # The remote service runs as root, but SSH logins land as "node" and the
    # npm prefix is node-owned. A root-run install leaves root-owned files that
    # (a) block node's built-in auto-updater and (b) leave behind a root-owned
    # ".claude-code-<hash>" temp dir when an install is interrupted, which then
    # jams every subsequent update with ENOTEMPTY on the atomic rename.
    # Clear any such stale temp dirs before installing, and restore node
    # ownership after, so both update paths keep working across reboots.
    local anthropic_dir=/home/node/.npm-global/lib/node_modules/@anthropic-ai
    rm -rf "$anthropic_dir"/.claude-code-* 2>/dev/null || true
    if npm install -g @anthropic-ai/claude-code@latest --silent >/tmp/claude-update.log 2>&1; then
        [ "$(id -u)" -eq 0 ] && chown -R node:node "$anthropic_dir" 2>/dev/null || true
        echo "entrypoint: Claude Code is up to date ($(claude --version 2>/dev/null || echo 'version unknown'))."
    else
        echo "entrypoint: Claude Code update check failed (offline?) — continuing with existing install. See /tmp/claude-update.log" >&2
    fi
}

# ---------------------------------------------------------------------------
# Plugin bootstrap (idempotent, non-fatal, quick).
#
# For each Claude Code profile (the default config dir plus every CLAUDE_PROFILES
# entry), add the marketplaces in CLAUDE_MARKETPLACES (space-separated GitHub
# slugs / URLs) and install the plugins in CLAUDE_PLUGINS (space-separated,
# e.g. "core-toolkit@nstsp"). Private marketplaces are cloned at RUNTIME with
# the deployment's own git credentials — nothing private is baked into the
# image — so we skip silently when no credentials are configured or we're
# offline. Uses the non-interactive `claude plugin` CLI (verified surface:
# `claude plugin marketplace add <source> [--scope user]` and
# `claude plugin install <plugin>@<marketplace> [--scope user]`).
# ---------------------------------------------------------------------------
have_git_creds() {
    run_as_node gh auth status >/dev/null 2>&1 && return 0
    [ -n "$(run_as_node git config --get credential.helper 2>/dev/null)" ] && return 0
    return 1
}

bootstrap_plugins() {
    [ -n "${CLAUDE_MARKETPLACES:-}" ] || [ -n "${CLAUDE_PLUGINS:-}" ] || return 0
    if ! have_git_creds; then
        echo "entrypoint: plugin bootstrap skipped — no gh/git credentials (run 'gh auth login' inside the container, then restart)." >&2
        return 0
    fi

    local profiles cfg mp pl
    profiles="default ${CLAUDE_PROFILES}"
    for p in $profiles; do
        if [ "$p" = "default" ]; then
            cfg="/home/node/.claude"
        else
            cfg="/home/node/.claude-$p"
        fi
        mkdir -p "$cfg" 2>/dev/null || true
        [ "$(id -u)" -eq 0 ] && chown node:node "$cfg" 2>/dev/null || true

        for mp in ${CLAUDE_MARKETPLACES:-}; do
            # Idempotent: only add when the marketplace slug/name isn't listed yet.
            if run_as_node env CLAUDE_CONFIG_DIR="$cfg" claude plugin marketplace list 2>/dev/null \
                    | grep -qiF "$mp"; then
                continue
            fi
            if run_as_node env CLAUDE_CONFIG_DIR="$cfg" claude plugin marketplace add "$mp" --scope user >/dev/null 2>&1; then
                echo "entrypoint: [$p] added marketplace $mp"
            else
                echo "entrypoint: [$p] could not add marketplace $mp (private/offline?) — skipping." >&2
            fi
        done

        for pl in ${CLAUDE_PLUGINS:-}; do
            # Idempotent: skip when the plugin (name before any @marketplace) is installed.
            if run_as_node env CLAUDE_CONFIG_DIR="$cfg" claude plugin list 2>/dev/null \
                    | grep -qiF "${pl%@*}"; then
                continue
            fi
            if run_as_node env CLAUDE_CONFIG_DIR="$cfg" claude plugin install "$pl" --scope user >/dev/null 2>&1; then
                echo "entrypoint: [$p] installed plugin $pl"
            else
                echo "entrypoint: [$p] could not install plugin $pl — skipping." >&2
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# ttyd web terminal (TTYD_ENABLE=1, TTYD_PORT default 7681). Serves an
# attach-or-create tmux session as the node user. ttyd has NO built-in auth
# and --writable makes it interactive, so it MUST only be exposed on the
# tailnet/LAN (the Unraid template maps the port there). Default off.
# ---------------------------------------------------------------------------
start_ttyd() {
    [ "${TTYD_ENABLE:-0}" = "1" ] || return 0
    if ! command -v ttyd >/dev/null 2>&1; then
        echo "entrypoint: TTYD_ENABLE=1 but ttyd is not installed — skipping." >&2
        return 0
    fi
    local port="${TTYD_PORT:-7681}"
    echo "entrypoint: starting ttyd on port ${port} (writable, NO AUTH — expose on tailnet/LAN only) ..."
    # Log to /tmp (writable whether we're root or node) rather than /var/log.
    run_as_node ttyd --port "${port}" --writable tmux new -A -s work \
        >/tmp/ttyd.log 2>&1 &
}

if [ -n "${TS_AUTHKEY:-}" ] || [ "${TS_ENABLE:-}" = "1" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "entrypoint: Tailscale requested but not running as root; skipping." >&2
    else
        echo "entrypoint: starting tailscaled ..."
        mkdir -p /var/run/tailscale /var/lib/tailscale

        # TS_USERSPACE=1 runs tailscaled with userspace networking, so the
        # container needs neither NET_ADMIN nor /dev/net/tun. Default (unset/0)
        # keeps kernel TUN, matching the current NET_ADMIN + /dev/net/tun setup.
        TUN_ARG=""
        if [ "${TS_USERSPACE:-0}" = "1" ]; then
            TUN_ARG="--tun=userspace-networking"
            echo "entrypoint: TS_USERSPACE=1 — tailscaled using userspace networking."
        fi

        # Tee logs to stdout (Unraid/docker log viewer) as well as the file.
        tailscaled \
            ${TUN_ARG} \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/var/run/tailscale/tailscaled.sock \
            2>&1 | tee /var/log/tailscaled.log &

        # Wait for the daemon socket to be ready.
        for _ in $(seq 1 30); do
            [ -S /var/run/tailscale/tailscaled.sock ] && break
            sleep 0.5
        done

        echo "entrypoint: tailscale up (Tailscale SSH enabled) ..."
        # Non-fatal: if auth fails/expires, keep the container alive so you can
        # still `docker exec` in and re-run `tailscale up` with a fresh key.
        tailscale up \
            --ssh \
            --hostname="${TS_HOSTNAME:-claude-code}" \
            --timeout=30s \
            ${TS_AUTHKEY:+--authkey="${TS_AUTHKEY}"} \
            ${TS_EXTRA_ARGS:-} \
            || echo "entrypoint: 'tailscale up' did not complete (missing/expired TS_AUTHKEY?). Container stays up; exec in and re-run 'tailscale up'."

        tailscale status || true
        echo "entrypoint: tailnet IP: $(tailscale ip -4 2>/dev/null || echo 'pending')"
    fi

    start_ttyd

    # Remote box: tailnet join comes first (time-sensitive — remote.ps1 checks
    # status seconds after start-up). Claude Code update and plugin bootstrap
    # run in the background so they never delay that, then the update keeps
    # refreshing daily since this container stays up for weeks
    # (restart: unless-stopped / autostart, sleep infinity).
    ( update_claude_code; bootstrap_plugins; while true; do sleep 86400; update_claude_code; done ) &
else
    # Local interactive use (docker compose run --rm claude): no tight startup
    # timing to protect, so just update / bootstrap before launching.
    start_ttyd
    update_claude_code
    bootstrap_plugins
fi

exec "$@"
