# Claude Code in Docker

A custom Linux image that runs [Claude Code](https://www.anthropic.com/claude-code)
in a container, with an M365 / Azure PowerShell admin toolbox baked in.

## What's installed

| Tool | Version (at build) |
| --- | --- |
| Claude Code | kept current automatically — see [Claude Code updates](#claude-code-updates) |
| Node.js | 22 |
| PowerShell | 7.6.3 |
| Python | 3.11 |
| GitHub CLI (`gh`) | 2.95 |
| git, ripgrep | system |
| Az (PowerShell) | Az.Accounts 5.5, Az.Resources 10, full Az |
| Microsoft.Graph | Authentication, Users, Groups, Sites, Files, Mail (2.38) |
| PnP.PowerShell | 3.2 |
| ExchangeOnlineManagement | 3.10 |
| Tailscale | 1.98 (for remote/phone access) |
| tmux | 3.3a (detachable sessions) |

Runs as the non-root `node` user (uid 1000). The Tailscale daemon is dormant
unless you start the `remote` profile (below).

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Image definition. |
| `install-psmodules.ps1` | PowerShell modules installed during build. |
| `docker-compose.yml` | Mounts SharePoint folders + persists login; defines local + remote services. |
| `entrypoint.sh` | Conditionally brings up Tailscale, sets up the multi-account `claude-<name>` profiles, then runs the command. |
| `run.ps1` | Convenience launcher for local use (build + run). |
| `remote.ps1` | Manage the persistent Tailscale box (up/down/status). |
| `.env.example` | API-key + Tailscale config. |

## Mounts

Two OneDrive-synced SharePoint folders are bind-mounted (the container uses the
local copy; OneDrive handles cloud sync — no second sync engine):

| Host | Container |
| --- | --- |
| `...\SP_Operations - Files\_Claude` | `/workspace/_Claude` |
| `...\SP_Operations - Files\_pallas` | `/workspace/_pallas` |

> If a mounted folder ever appears empty, set it to **"Always keep on this
> device"** in OneDrive — Files On-Demand placeholders don't materialize inside
> a Linux container.

## Quick start

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
the PC. Tailscale's daemon is the SSH server — there are **no passwords and no SSH
keys**; auth is your tailnet identity.

### One-time setup

1. **Tailscale on the PC** (installed here via `winget install Tailscale.Tailscale`)
   signed into your tailnet, and **Tailscale on the phone** signed into the *same*
   account. Install an SSH terminal app on the phone (ConnectBot, Termius, etc.).
2. **Generate an auth key:** <https://login.tailscale.com/admin/settings/keys>
   - Use a reusable, non-ephemeral key so the box survives restarts.
   - ⚠️ The key is shown **only once** — copy the whole string in one go. A valid
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

- The PC must be **awake with Docker running** (sleep was disabled here — see
  Maintenance below).
- Your Claude login and SharePoint mounts are identical to local use (shared
  `claude-home` volume and the same binds).
- After the first successful join you can **blank `TS_AUTHKEY` in `.env`** — the
  node identity persists in the `tailscale-state` volume and re-authenticates on
  restart without a key. (Done here, so no live key sits in the synced folder.)
- To re-key later (e.g. identity wiped), put a fresh key back in `.env` and run
  `docker compose --profile remote up -d --force-recreate claude-remote`.

## This deployment (as configured)

| Item | Value |
| --- | --- |
| Container tailnet name | `claude-code` |
| SSH user | `node` (no password) |
| Phone client | ConnectBot, connecting to `node@claude-code` |
| PC sleep | disabled (`powercfg /change standby-timeout-ac/dc 0`) |
| Auth key in `.env` | blanked (identity persisted in `tailscale-state` volume) |
| Restart policy | `unless-stopped` (box comes back after reboot/Docker restart) |

## Claude Code updates

Claude Code is **not version-pinned** and updates itself automatically — no
manual `npm update` or image rebuild needed going forward:

- The npm global prefix (`/home/node/.npm-global`) is owned by the `node`
  user and lives inside the persisted `claude-home` volume.
- `entrypoint.sh` runs `npm install -g @anthropic-ai/claude-code@latest`
  every time a container starts. For the local `claude` service
  (`docker compose run --rm`), that's every launch. For the persistent
  `claude-remote` box, it also re-checks every 24 hours in the background
  so a box left running for weeks doesn't go stale.
- Update failures (e.g. no internet) are logged and non-fatal — the
  container falls back to whichever version is already installed.

To check the version Claude Code is currently running:

```powershell
docker compose run --rm claude bash -c "claude --version"
```

If you ever want to force a fresh check on the remote box without waiting
for the daily refresh:

```powershell
docker compose exec claude-remote npm install -g @anthropic-ai/claude-code@latest
```

## Maintenance

```powershell
# Is the box up and on the tailnet?
docker compose --profile remote ps
docker compose exec claude-remote tailscale status

# Stop / start the remote box
docker compose --profile remote down
docker compose --profile remote up -d claude-remote

# Re-confirm PC won't sleep
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE
```

## Reset saved login/settings

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
| Mounted folder looks empty in the container | OneDrive Files On-Demand — set the folder to "Always keep on this device". |
| Box unreachable after the PC rebooted | Ensure Docker Desktop is running; the container auto-restarts (`unless-stopped`) once Docker is up. |
