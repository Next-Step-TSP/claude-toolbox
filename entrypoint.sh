#!/usr/bin/env bash
# Container entrypoint.
#
# If Tailscale is enabled (TS_AUTHKEY set, or TS_ENABLE=1 with persisted state),
# bring up tailscaled with Tailscale SSH so the box is reachable on your tailnet.
# Otherwise this is a no-op and we just run the given command — so local
# interactive use (docker compose run --rm claude) is unaffected.
set -euo pipefail

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
# whatever is already installed.
# ---------------------------------------------------------------------------
update_claude_code() {
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


if [ -n "${TS_AUTHKEY:-}" ] || [ "${TS_ENABLE:-}" = "1" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        echo "entrypoint: Tailscale requested but not running as root; skipping." >&2
    else
        echo "entrypoint: starting tailscaled ..."
        mkdir -p /var/run/tailscale /var/lib/tailscale
        tailscaled \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/var/run/tailscale/tailscaled.sock \
            >/var/log/tailscaled.log 2>&1 &

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

    # Remote box: tailnet join comes first (time-sensitive — remote.ps1 checks
    # status seconds after start-up). Claude Code update runs in the
    # background so it never delays that, then keeps refreshing daily since
    # this container stays up for weeks (restart: unless-stopped, sleep infinity).
    ( update_claude_code; while true; do sleep 86400; update_claude_code; done ) &
else
    # Local interactive use (docker compose run --rm claude): no tight startup
    # timing to protect, so just update before launching.
    update_claude_code
fi

exec "$@"
