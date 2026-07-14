# claude-toolbox

NSTSP's standard [Claude Code](https://www.anthropic.com/claude-code) image: a
Linux container that runs Claude Code alongside an M365/Azure PowerShell
administration toolbox, with baked-in Tailscale SSH for remote/phone access.
Built and published to GHCR by CI; usable locally via Docker Compose on a PC,
or deployed persistently on the NSTSP Unraid server.

## What's installed

| Tool | Version |
| --- | --- |
| Claude Code | kept current automatically — see [Claude Code updates](#claude-code-updates) |
| Node.js | 24 (Active LTS) on Debian 13 "trixie" |
| PowerShell | 7.6.3 (LTS, .NET 10) |
| Python | 3 (Debian trixie's `python3`) |
| GitHub CLI (`gh`) | current stable, via GitHub's apt repo |
| git, ripgrep | system |
| Az (PowerShell) | full `Az` module |
| Microsoft.Graph | Authentication, Users, Groups, Sites, Files, Mail |
| PnP.PowerShell | current |
| ExchangeOnlineManagement | current |
| Tailscale | current stable, via Tailscale's trixie apt channel (for remote/phone access) |
| tmux | detachable terminal sessions |
| ttyd | optional browser-based terminal (`TTYD_ENABLE=1`) |

Runs as the non-root `node` user. The Tailscale daemon and ttyd are both
dormant unless enabled (`TS_ENABLE=1`, `TTYD_ENABLE=1`) — see
[Remote / phone access](#remote--phone-access-tailscale-ssh) below.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Image definition. |
| `install-psmodules.ps1` | PowerShell modules installed during build. |
| `entrypoint.sh` | Brings up Tailscale/ttyd as configured, sets up multi-account `claude-<name>` profiles, runs the plugin bootstrap, then runs the command. |
| `healthcheck.sh` | Container `HEALTHCHECK` — validates the tailnet connection when Tailscale is enabled, otherwise a basic liveness check. |
| `docker-compose.yml` | Mounts SharePoint folders + persists login; defines local + remote services for PC use. |
| `.env.example` | API-key, Tailscale, and profile config for PC/Compose use. |
| `run.ps1` | Convenience launcher for local PC use (build + run). |
| `remote.ps1` | Manage the persistent PC-hosted Tailscale box (up/down/status). |
| `.github/workflows/publish.yml` | CI: builds and pushes the image to GHCR. |
| `.github/dependabot.yml` | Weekly dependency updates for the base image and pinned Actions. |
| `unraid/claude-toolbox.xml` | Unraid Docker template (side-loaded today; see [Unraid deployment](#unraid-deployment)). |
| `unraid/go-snippet.sh` | Persists `docker login ghcr.io` across Unraid reboots. |
| `unraid/icon/` | Template icon asset (512x512 PNG — **not yet created**, see the TODO in that folder). |
| `docs/UNRAID.md` | Full Unraid deployment + cutover runbook. |
| `docs/CA-CHECKLIST.md` | Deferred checklist for a future public Community Applications listing. |

## Mounts (PC / Compose use)

Two OneDrive-synced SharePoint folders are bind-mounted (the container uses the
local copy; OneDrive handles cloud sync — no second sync engine):

| Host | Container |
| --- | --- |
| `...\SP_Operations - Files\_Claude` | `/workspace/_Claude` |
| `...\SP_Operations - Files\_pallas` | `/workspace/_pallas` |

> If a mounted folder ever appears empty, set it to **"Always keep on this
> device"** in OneDrive — Files On-Demand placeholders don't materialize inside
> a Linux container.

(On the Unraid deployment, the equivalent content is kept current by
Linux-side `onedrive` sync containers instead of a Windows OneDrive client —
see `docs/UNRAID.md`.)

## Quick start (PC)

```powershell
.\run.ps1            # launch Claude Code
.\run.ps1 -Shell     # bash shell instead
```

First launch prompts you to authenticate; the login is saved in the
`claude-home` Docker volume and reused on every later run.

### PowerShell session inside the container

```powershell
docker compose run --rm claude pwsh
# then e.g. Connect-MgGraph -Scopes "Sites.Read.All"
#          Connect-ExchangeOnline
#          Connect-PnPOnline -Url https://<tenant>.sharepoint.com -Interactive
#          Connect-AzAccount
```

> Microsoft sign-ins from the container use device-code / browser auth. Tokens
> persist in the `claude-home` volume between runs.

## Authentication options

- **Subscription login (default):** run it and log in once when prompted.
- **API key:** copy `.env.example` to `.env`, set `ANTHROPIC_API_KEY=...`.

## Multiple Claude accounts

You can run more than one Claude account side-by-side, each with its own
isolated login/settings/history. This works because Claude Code stores its
credentials in a file inside its config dir, and `CLAUDE_CONFIG_DIR` relocates
that dir per session.

The profiles are defined by `CLAUDE_PROFILES` (space-separated, default
`nstsp extra` — set in `.env`). On every container start, `entrypoint.sh`
creates for each name:

- an isolated config dir `~/.claude-<name>`, and
- a shell function `claude-<name>` that launches Claude Code against it.

Because the entrypoint regenerates these on every start, the **commands persist
even after a `claude-home` volume reset** (you'd just re-run `/login` in each).

```bash
# Inside the container (e.g. over SSH), in separate tmux windows:
claude-nstsp      # first run: /login with account A
claude-extra      # first run: /login with account B  (headless: opens a URL to approve)
```

Bare `claude` still uses the default `~/.claude` login, untouched.

> The same pattern works on the **Windows host** without Docker: small
> `claude-<name>.cmd` wrappers on `PATH` that set `CLAUDE_CONFIG_DIR` before
> calling `claude.exe`.

## Without the helper script

```powershell
docker compose build
docker compose run --rm claude          # Claude Code
docker compose run --rm claude bash     # shell
docker compose run --rm claude pwsh     # PowerShell
```

## Remote / phone access (Tailscale SSH)

The container joins your tailnet as its **own machine** named `claude-code`
(it runs its own `tailscaled`). You SSH **directly to the container**, not through
the host. Tailscale's daemon is the SSH server — there are **no passwords and no
SSH keys**; auth is your tailnet identity.

A browser-based alternative is also available: with `TTYD_ENABLE=1`, ttyd
serves a terminal over HTTP on port 7681 (`TTYD_PORT`) — useful when a
tailnet SSH client isn't handy, but note it has **no built-in authentication**
of its own, so only ever expose that port on the tailnet/LAN.

### One-time setup

1. **Tailscale on the PC** (installed here via `winget install Tailscale.Tailscale`)
   signed into your tailnet, and **Tailscale on the phone** signed into the *same*
   account. Install an SSH terminal app on the phone (ConnectBot, Termius, etc.).
2. **Generate an auth key:** <https://login.tailscale.com/admin/settings/keys>
   - Use a reusable, non-ephemeral key so the box survives restarts.
   - The key is shown **only once** — copy the whole string in one go. A valid
     key starts with `tskey-auth-`. If yours doesn't, it was truncated on paste —
     generate a fresh one. (`backend error: invalid key: API key does not exist`
     in the logs = a bad/incomplete/expired key.)
3. Put it in `.env`:  `TS_AUTHKEY=tskey-auth-...`

### Start the box

```powershell
.\remote.ps1 up        # build + start, prints tailscale status
.\remote.ps1 status    # check it later
.\remote.ps1 ssh-info  # show tailnet IP + connect string
.\remote.ps1 down      # stop it
```

After it joins, `claude-code` appears in the Tailscale admin console alongside
your other machines.

> This PC-hosted remote box is being superseded by a persistent Unraid
> deployment that inherits the same `claude-code` tailnet identity — see
> [Unraid deployment](#unraid-deployment).

### Connect from the phone (ConnectBot on Android)

The Tailscale app **must be connected on the phone first** — ConnectBot isn't
Tailscale-aware, it just rides the tunnel. Then in ConnectBot:

| Field | Value |
| --- | --- |
| Protocol | SSH |
| Connection string | `node@claude-code` (the MagicDNS hostname — works in ConnectBot; a raw `100.x` tailnet IP may not resolve) |
| Port | 22 |
| Password | **leave blank** |
| Use pubkey authentication | **none** (avoids repeated key prompts) |

First connection may print a Tailscale "check mode" approval URL in the terminal —
open it in the phone browser, approve once, and the session continues.

Once in:

```bash
tmux new -A -s work     # re-attaches to the same live session next time
cd /workspace/_pallas
claude
```

### Notes

- The host must be **awake with Docker running** (on the PC deployment; the
  Unraid deployment is always-on by nature).
- Your Claude login and SharePoint mounts are identical to local use (shared
  `claude-home` volume and the same binds).
- After the first successful join you can **blank `TS_AUTHKEY` in `.env`** — the
  node identity persists in the `tailscale-state` volume and re-authenticates on
  restart without a key.
- To re-key later (e.g. identity wiped), put a fresh key back in `.env` and run
  `docker compose --profile remote up -d --force-recreate claude-remote`.

## GHCR image and tags

CI (`.github/workflows/publish.yml`) builds `linux/amd64` and pushes to
`ghcr.io/next-step-tsp/claude-toolbox` on every push to `main`, on `v*` tags,
weekly (security repave of `:latest`), and on manual dispatch. Tags produced:

| Trigger | Tags |
| --- | --- |
| `v1.2.3` tag | `1.2.3`, `1.2`, `1`, `latest`, plus a `sha-<short>` tag |
| push to `main` | `main`, `latest`, plus a `sha-<short>` tag |
| weekly cron | re-pushes `latest` (and its `sha` tag) from `main`, picking up upstream security patches |

The package is currently **private** — pulling it (from a PC or from Unraid)
requires `docker login ghcr.io` with a GitHub PAT scoped to `read:packages`.
See `docs/CA-CHECKLIST.md` for the plan to flip it public.

## Environment variable reference

This is the full set of variables the image understands, across both the
Compose (PC) and Unraid deployment paths. Not every variable is wired into
`docker-compose.yml` today — check that file / `.env.example` for what the PC
path currently forwards, and `unraid/claude-toolbox.xml` for the Unraid
template's defaults.

| Variable | Default | Purpose |
| --- | --- | --- |
| `TS_ENABLE` | `0` (unset) | Start `tailscaled` and join the tailnet on container start. |
| `TS_AUTHKEY` | _(blank)_ | Tailscale reusable auth key, needed only for the first tailnet join; blank it out once joined. |
| `TS_HOSTNAME` | `claude-code` | Tailnet machine name this container appears as. |
| `TS_EXTRA_ARGS` | _(blank)_ | Extra arguments appended to `tailscale up`. |
| `TS_USERSPACE` | `0` | Run `tailscaled` in userspace-networking mode (no TUN/NET_ADMIN needed) instead of kernel TUN. |
| `TTYD_ENABLE` | `0` (unset) | Enable the ttyd browser terminal on `TTYD_PORT`. |
| `TTYD_PORT` | `7681` | Port ttyd listens on. |
| `PUID` | _(unset — PC path runs as the built-in `node` uid)_ | Remaps the `node` user's UID at start (Unraid convention: `99`). |
| `PGID` | _(unset)_ | Remaps the `node` user's GID at start (Unraid convention: `100`). |
| `TZ` | _(unset — container default)_ | Timezone for logs/timestamps. |
| `UMASK` | `022` | Umask applied to files the entrypoint creates. |
| `CLAUDE_PROFILES` | `nstsp extra` | Space-separated Claude Code account profile names — see [Multiple Claude accounts](#multiple-claude-accounts). |
| `CLAUDE_MARKETPLACES` | _(blank)_ | Private Claude Code plugin marketplace(s) to register at runtime, per profile. Never baked into the image. |
| `CLAUDE_PLUGINS` | _(blank)_ | Plugin(s) to install from the marketplace(s) above, per profile. |
| `UPDATE_CLAUDE_ON_START` | `1` | Re-install the latest Claude Code on every start (and periodically while the container stays up). Set `0` to pin the existing install. |
| `ANTHROPIC_API_KEY` | _(blank)_ | Use an API key instead of interactive subscription login. |

## Unraid deployment

The always-on NSTSP Unraid server runs `claude-toolbox` persistently,
replacing the PC-hosted remote box and inheriting its `claude-code` tailnet
identity. Server-side setup, the OneDrive sync containers, the tailnet
cutover from the PC box, and a verification checklist are all in
**[`docs/UNRAID.md`](docs/UNRAID.md)**. The Unraid Docker template itself is
`unraid/claude-toolbox.xml`.

## Community Applications (CA) roadmap

This repo and image are private for now. There's a deferred checklist for
eventually making the repo/image public and submitting a template to
Unraid's Community Applications — see
**[`docs/CA-CHECKLIST.md`](docs/CA-CHECKLIST.md)**. Notably: the "Claude
Toolbox" name leans on Anthropic's trademark and needs a naming review
before any public listing.

## Claude Code updates

Claude Code is **not version-pinned** and updates itself automatically — no
manual `npm update` or image rebuild needed going forward:

- The npm global prefix (`/home/node/.npm-global`) is owned by the `node`
  user and lives inside the persisted home directory (the `claude-home`
  volume on the PC path; the Home path on the Unraid template).
- `entrypoint.sh` runs `npm install -g @anthropic-ai/claude-code@latest`
  every time a container starts (gated by `UPDATE_CLAUDE_ON_START`, default
  on). For the local `claude` service (`docker compose run --rm`), that's
  every launch. For a persistent box (PC `claude-remote` or the Unraid
  deployment), it also re-checks periodically in the background so a box
  left running for weeks doesn't go stale.
- Update failures (e.g. no internet) are logged and non-fatal — the
  container falls back to whichever version is already installed.

To check the version Claude Code is currently running:

```powershell
docker compose run --rm claude bash -c "claude --version"
```

If you ever want to force a fresh check on a persistent box without waiting
for the periodic refresh:

```powershell
docker compose exec claude-remote npm install -g @anthropic-ai/claude-code@latest
```

## Maintenance (PC)

```powershell
# Is the box up and on the tailnet?
docker compose --profile remote ps
docker compose exec claude-remote tailscale status

# Stop / start the remote box
docker compose --profile remote down
docker compose --profile remote up -d claude-remote
```

## Reset saved login/settings (PC)

```powershell
docker volume rm docker_claude-home       # Claude + M365 logins
docker volume rm docker_tailscale-state   # Tailscale node identity (needs re-key)
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Phone can't connect at all | Tailscale app not connected on the phone. Open it and toggle on. |
| `invalid key: API key does not exist` in `docker compose logs claude-remote` | Bad/incomplete/expired `TS_AUTHKEY`. Generate a fresh key (starts with `tskey-auth-`), paste it whole, `--force-recreate`. |
| ConnectBot keeps asking for a key/password | Set "Use pubkey authentication" to **none**; leave password blank. |
| Hostname `claude-code` won't resolve | Use it via the phone's Tailscale (MagicDNS); if still failing, get the IP from `.\remote.ps1 ssh-info`. |
| Mounted folder looks empty in the container | OneDrive Files On-Demand — set the folder to "Always keep on this device" (PC path), or check the Unraid `onedrive` sync container's status (Unraid path). |
| Box unreachable after the PC rebooted | Ensure Docker Desktop is running; the container auto-restarts (`unless-stopped`) once Docker is up. |
| Unraid: image pull fails with "unauthorized" | GHCR login on the Unraid host has expired or was never persisted — see `docs/UNRAID.md` and `unraid/go-snippet.sh`. |
