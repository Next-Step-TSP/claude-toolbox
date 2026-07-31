# claude-toolbox — ARCHIVED

**Moved to [`claude-ssh-solutions`](https://github.com/Next-Step-TSP/claude-ssh-solutions).**
This repository is archived and read-only. Nothing here is maintained.

## Why

This repo held NSTSP's standard Claude Code container image (Debian + Claude Code + an M365/Azure
PowerShell toolbox, with Tailscale SSH and tmux baked in) plus its Unraid deployment.

`claude-ssh-solutions` covers the same ground and more: it adds **direct SSH into Windows machines
with no container involved**, using Claude Code's own `--bg` / `attach` background sessions instead
of tmux. Keeping the container assets in a separate repo left them split from the scripts that drive
them, and — because the publish workflow here rebuilt `:latest` on a weekly cron — meant fixes made
in the new repo would never have reached production. So everything was absorbed and this was closed.

## Where things went

| Was here | Now in `claude-ssh-solutions` |
|---|---|
| `Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `healthcheck.sh`, `install-psmodules.ps1`, `.env.example` | `docker/` |
| `.github/workflows/publish.yml` | `.github/workflows/publish.yml` (build context `./docker`) |
| `unraid/` (CA template, `go-snippet.sh`, icon) | `unraid/` |
| `docs/UNRAID.md` | `docs/UNRAID.md` — still authoritative for the live node |
| `docs/CA-CHECKLIST.md` | `docs/CA-CHECKLIST.md`, marked **closed** — no public Community Applications listing |
| `run.ps1` | `docker/Run-ClaudeContainer.ps1` |
| `remote.ps1` | dropped — superseded by `Setup-ClaudeDockerHost.ps1` |

## What did *not* change

The running deployment is untouched:

- **Image tag** is still `ghcr.io/next-step-tsp/claude-toolbox:latest`. The Unraid node pulls that
  exact tag; only the repo that builds it moved.
- **Unraid appdata paths** are still `/mnt/user/appdata/claude-toolbox/{home,tailscale}`.
- **Tailnet hostname** is still `claude-code`.

## Bugs fixed during the migration

Recorded here because they were live in this repo's assets and someone reading an old clone should
know:

- `docker volume rm docker_claude-home` in the old README and `docs/UNRAID.md` §6 used a prefix left
  over from a directory rename. It matched **no volume**, so a "reset the login state" step appeared
  to succeed while doing nothing. The compose file now pins `name: claude-toolbox`, making the
  volumes `claude-toolbox_claude-home` and `claude-toolbox_tailscale-state`.
- The `WORKSPACE_CLAUDE` / `WORKSPACE_PALLAS` bind mounts had no defaults, so `docker compose` failed
  immediately on any machine without the SharePoint/OneDrive folders synced. They now default.
- Nothing started a tmux server, so the first attach after every container start was a manual
  `tmux new -A -s work`. `AUTOSTART_TMUX=1` now creates it at boot.
- ttyd runs `--writable` with **no authentication** and was published on all interfaces, so on a PC it
  was LAN-exposed to anyone who could reach the port. It is now loopback-bound by default.
