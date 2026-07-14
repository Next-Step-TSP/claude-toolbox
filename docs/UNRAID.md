# Unraid deployment & cutover runbook

This is the step-by-step for standing up `claude-toolbox` on the always-on
Unraid server and retiring the PC-based remote box (`claude-remote` in
`docker-compose.yml`) in its favor. It assumes you're running these steps
from the PC, over LAN SSH to the Unraid box — the server does not need
Tailscale itself; the container brings its own.

Prerequisites to have in hand before starting:

- Unraid LAN IP address and SSH access (root).
- A fresh, reusable Tailscale auth key (`tskey-auth-...`) from
  <https://login.tailscale.com/admin/settings/keys>.
- A GitHub Personal Access Token scoped to **`read:packages` only**, for
  pulling the private `ghcr.io/next-step-tsp/claude-toolbox` image.
- A GitHub account with access to `Next-Step-TSP` repos, for `gh auth login`
  inside the container later.

Unraid's own "Tailscale" plugin (server-level, for managing the Unraid
web GUI itself over Tailscale) is **unrelated to this container** and
entirely optional. It's a reasonable thing to install for admin convenience,
but skip it if you don't need it — nothing here depends on it, and its
per-container "Use Tailscale" toggle must stay **off** on this container
specifically (see step 4).

## 1. Registry auth persistence (ghcr.io login)

Unraid's rootfs is a RAM disk rebuilt from `/boot` on every reboot, and
there's no GUI for private-registry credentials, so the login has to be
re-applied at every boot via a script.

```bash
ssh root@<unraid-lan-ip>

# One-time interactive login to confirm the PAT works:
docker login ghcr.io -u <your-github-username>
# paste the read:packages PAT when prompted for a password
```

Then make it durable across reboots: open `unraid/go-snippet.sh` from this
repo, fill in `GHCR_USER` / `GHCR_TOKEN`, and append the marked block to
`/boot/config/go` on the server (edit via the flash share, e.g.
`\\<unraid-ip>\flash\config\go`, or `nano /boot/config/go` over SSH).

Notes (see the comments in `go-snippet.sh` for the full rationale):

- The token sits in **plaintext on the flash drive** — only ever use a
  `read:packages`-scoped PAT here, never a broader one.
- This step becomes unnecessary once the GHCR package is flipped **public**
  (`docs/CA-CHECKLIST.md`) — anonymous pulls work at that point and the
  block (and the PAT) can be deleted.
- If you'd rather not hand-edit `/boot/config/go`, the "User Scripts" CA
  plugin's **"At First Array Start"** trigger is an equivalent alternative —
  see the snippet's comments.

Reboot (or just re-run the `docker login` command once by hand) to confirm.

## 2. OneDrive sync containers

The workspace content that used to be OneDrive-synced onto the PC
(`SP_Operations - Files\_Claude`, `SP_Operations - Files\_pallas`) needs a
Linux-side sync engine on the server, since there's no OneDrive client on
Unraid. Use the **abraunegg `onedrive`** container from Community
Applications — install **one instance per SharePoint library**:

| Instance | SharePoint library | Sync target |
| --- | --- | --- |
| `onedrive-claude` | `_Claude` | `/mnt/user/claude-workspace/_Claude` |
| `onedrive-pallas` | `_pallas` | `/mnt/user/claude-workspace/_pallas` |

For each instance: install from CA, point its config/state volume at its own
`/mnt/user/appdata/onedrive-<library>/` directory (don't share one config dir
between instances), run its one-time `onedrive --synchronize --verbose`
auth flow (device-code sign-in, same Microsoft account/tenant as the
library), and set its sync target to the path above. Consult the
abraunegg `onedrive` container's own documentation for library-scoped sync
configuration (`sync_list` / single-library mode) so each instance only
pulls its own library.

Once both are running and have completed an initial sync, `/workspace` as
seen by `claude-toolbox` will contain `_Claude/` and `_pallas/` populated
with real files (see step 4 for the mount).

## 3. Appdata directories

```bash
mkdir -p /mnt/user/appdata/claude-toolbox/home
mkdir -p /mnt/user/appdata/claude-toolbox/tailscale
mkdir -p /mnt/user/claude-workspace
```

`/mnt/user/claude-workspace` is the parent that both the OneDrive sync
containers (step 2) and `claude-toolbox` (step 4) mount into — the
container sees it as `/workspace`.

## 4. Install the template and create the container

Copy the template into Unraid's user-templates directory so it shows up in
the "Add Container" template picker:

```bash
scp unraid/claude-toolbox.xml root@<unraid-lan-ip>:/boot/config/plugins/dockerMan/templates-user/
```

Then, in the Unraid web UI: **Docker tab → Add Container → Template →
claude-toolbox**. Confirm/adjust before applying:

- **Paths**: Home → `/mnt/user/appdata/claude-toolbox/home`; Tailscale state
  → `/mnt/user/appdata/claude-toolbox/tailscale`; Workspace →
  `/mnt/user/claude-workspace`.
- **Port**: 7681 (ttyd web terminal) → `http://<unraid-ip>:7681/`.
- **Variables**: `TS_ENABLE=1`, `TS_HOSTNAME=claude-code`, `TS_AUTHKEY=`
  (paste the fresh key from the prerequisites — see the cutover warning in
  step 5 before doing this), `CLAUDE_PROFILES=nstsp extra`,
  `CLAUDE_MARKETPLACES`/`CLAUDE_PLUGINS` as needed, `PUID=99`, `PGID=100`,
  `TZ=America/Edmonton`, `TTYD_ENABLE=1`.
- **Extra Parameters** should already read
  `--cap-add=NET_ADMIN --device=/dev/net/tun --init` from the template —
  leave as-is.
- Leave Unraid's own per-container **"Use Tailscale"** toggle **OFF**. This
  container runs its own `tailscaled`; the two are mutually exclusive and
  will conflict if both are enabled.
- Set **Autostart** on, so the container survives an Unraid reboot without
  manual intervention (Unraid has no `--restart` policy concept — this is
  the equivalent).

Don't click Apply yet if you haven't done step 5's teardown of the old
node — see below.

## 5. Tailnet cutover (replacing the PC box)

The Unraid container is meant to **inherit the `claude-code` tailnet
hostname** from the PC's `claude-remote` service, not run alongside it as a
second node. Order matters:

1. **Stop the PC box first**: `docker compose --profile remote down` (or
   `.\remote.ps1 down`) in the old `docker` folder on the PC.
2. **Delete the old `claude-code` node** in the Tailscale admin console
   (<https://login.tailscale.com/admin/machines>) — find the machine, remove
   it. This frees up the hostname and drops the old node's identity/keys.
3. **Start the Unraid container** (Apply on the template from step 4, with
   `TS_AUTHKEY` populated). It will claim `claude-code` fresh using the new
   auth key.
4. Confirm it joined: `docker exec claude-toolbox tailscale status` (or
   check the Tailscale admin console for a new `claude-code` entry).
5. **Blank `TS_AUTHKEY`** back out in the Unraid template/container
   variables once joined — the node identity now persists in the
   `TailscaleState` path (`/mnt/user/appdata/claude-toolbox/tailscale`), so
   the key isn't needed again unless that path is wiped.

## 6. Seed logins and plugin bootstrap

Rather than re-running `/login` from scratch for every Claude Code profile,
copy the existing credentials over from the PC's `claude-home` Docker
volume (this has proven to be cross-OS-portable):

```bash
# On the PC, find the volume's host path:
docker volume inspect docker_claude-home

# Copy each profile's credentials + settings (adjust source path/profile names):
# .claude-nstsp/.credentials.json, .claude-nstsp/settings.json, etc.
# to the Unraid appdata home, e.g. via scp to
# /mnt/user/appdata/claude-toolbox/home/.claude-nstsp/
```

If you'd rather not copy credential files around, running `claude-nstsp` /
`claude-extra` and doing a fresh `/login` per profile inside the new
container works identically — just slower.

Then, inside the container:

```bash
docker exec -it claude-toolbox bash
gh auth login          # once, for private marketplace + repo access
claude-nstsp            # confirm the profile launches with marketplace plugins listed
claude-extra
```

The entrypoint's plugin bootstrap (`CLAUDE_MARKETPLACES` /
`CLAUDE_PLUGINS`) runs automatically on start for each profile in
`CLAUDE_PROFILES`, using whatever git/gh credentials are present at that
point — so it's worth doing the `gh auth login` above before restarting the
container, or just restarting it once afterward to let the bootstrap pick
up the new credentials.

## 7. GitHub repos workspace

`/workspace/repos` (backed by `/mnt/user/claude-workspace/repos` on the
host) is the persistent home for day-to-day `git`/`gh` work inside the
container — the Unraid equivalent of `nstsp-repos` on the PC. Seed-clone the
active `Next-Step-TSP` repos once `gh auth login` is done:

```bash
mkdir -p /workspace/repos && cd /workspace/repos
gh repo clone Next-Step-TSP/claude-toolbox
gh repo clone Next-Step-TSP/nstsp-claude-marketplace
# ... any other active repos
```

Because this is a bind-mounted host path (not a container-internal
directory), clones here survive container recreation/updates just like the
appdata paths do.

## 8. PC: retire the local remote profile

Once the Unraid container is confirmed healthy and reachable, on the PC:

- Point the local `claude` compose service at the published image
  (`image: ghcr.io/next-step-tsp/claude-toolbox:latest`, already set in
  `docker-compose.yml`) instead of building locally, if desired.
- The `claude-remote` service/profile is no longer needed for phone/remote
  access — the Unraid container has taken over the `claude-code` identity.
  Leave the compose file as historical reference or remove the profile in a
  later cleanup pass; no rush.

## Verification checklist

Run through this after cutover to confirm the migration is actually done,
not just "container is green":

- [ ] Container shows **healthy** in the Unraid Docker tab (healthcheck
      passing).
- [ ] `docker exec claude-toolbox tailscale status` shows the node online
      as `claude-code`.
- [ ] `ssh node@claude-code` from the PC (over the tailnet) connects with no
      password/key prompt.
- [ ] `tmux new -A -s work` and the ttyd WebUI (`http://<unraid-ip>:7681/`)
      both reach a working shell.
- [ ] `claude-nstsp` (and any other configured profile) launches already
      logged in, with the marketplace plugin(s) listed/available.
- [ ] `/workspace` shows real, current OneDrive-synced content (`_Claude/`,
      `_pallas/`), not empty placeholder folders.
- [ ] `/workspace/repos` clones can be pulled and pushed with `gh`/`git`
      from inside the container.
- [ ] Restarting the container (`docker restart claude-toolbox`, or an
      Unraid array restart) brings it back healthy, rejoined to the
      tailnet, and autostarted — with no manual steps.
- [ ] Phone check: ConnectBot (or equivalent) → `ssh node@claude-code` still
      works exactly as it did against the old PC box.
