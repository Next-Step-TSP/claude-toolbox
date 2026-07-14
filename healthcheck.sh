#!/usr/bin/env bash
# Container HEALTHCHECK. Exit 0 = healthy, 1 = unhealthy.
#
# Runs as whatever user the container runs as (root for the Tailscale/remote
# service, node for local use) — keep it independent of $PATH inheritance and
# of socket ownership assumptions.
set -uo pipefail

# The healthcheck may run before any login shell has set PATH (Docker execs it
# directly), so pin a sane one.
export PATH="/home/node/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ts_enabled() {
    [ "${TS_ENABLE:-0}" = "1" ] || [ -n "${TS_AUTHKEY:-}" ]
}

if ts_enabled; then
    # Tailscale mode: the tailnet is the reason this container exists, so its
    # health is the daemon's backend state. NeedsLogin is treated as HEALTHY on
    # purpose — an expired/absent auth key leaves the container up intentionally
    # so an operator can exec in and re-run `tailscale up`; flapping it
    # unhealthy would just trigger pointless restarts. Starting is transient.
    state=$(tailscale status --json 2>/dev/null \
        | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n1 \
        | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
    case "$state" in
        Running|NeedsLogin|Starting)
            exit 0
            ;;
        *)
            # JSON parse failed or an unexpected state — fall back to the plain
            # status exit code (0 while connected) before giving up.
            tailscale status >/dev/null 2>&1 && exit 0
            exit 1
            ;;
    esac
fi

# Tailscale disabled: basic liveness. Claude Code on PATH is the primary
# signal; a working shell is the floor.
if command -v claude >/dev/null 2>&1; then
    exit 0
fi
[ -x /bin/bash ] || [ -x /bin/sh ] && exit 0
exit 1
