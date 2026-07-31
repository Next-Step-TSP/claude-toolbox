# claude-toolbox

Docker image for NSTSP's standard Claude Code + M365/Azure PowerShell toolbox.
See `README.md` for full architecture, env vars, and runbooks — this file only
covers what isn't obvious from reading the code.

## FROZEN — do not edit the container assets here

`Dockerfile`, `docker-compose.yml`, `entrypoint.sh`, `healthcheck.sh`,
`install-psmodules.ps1` and `.env.example` are **frozen**. Refactored copies are
maintained in `claude-ssh-solutions/docker/`. Make changes there and, if the
image needs rebuilding, read that repo's "Open question: who publishes the
image" first — `.github/workflows/publish.yml` here still pushes the tag the
live Unraid node pulls.

`remote.ps1` is deprecated in favour of
`claude-ssh-solutions\Setup-ClaudeDockerHost.ps1`. `run.ps1` and
`docs/UNRAID.md` are still current. See the status table at the top of
`README.md` for the full mapping.

## No test suite

There's no local test/lint command. CI (`.github/workflows/publish.yml`) only
builds and pushes the image to GHCR, on push to `main`, `v*` tags, weekly
cron, or manual dispatch. "Does it work" means building the image and running
it via `run.ps1` / `docker compose`, not a test command.

## Gotchas

- **Claude Code is intentionally unpinned.** `entrypoint.sh` runs
  `npm install -g @anthropic-ai/claude-code@latest` on every container start
  (gated by `UPDATE_CLAUDE_ON_START`). Don't pin a version in the Dockerfile.
- **npm global prefix must stay owned by `node`, not `root`**
  (`Dockerfile`, `/home/node/.npm-global`) — required for the update-on-start
  design to work without root.
- **The GHCR package is private.** Pulling requires `docker login ghcr.io`
  with a PAT scoped to `read:packages`. Don't assume public-pull will work.
  Before any change aimed at making the repo/image public, see
  `docs/CA-CHECKLIST.md` — the "Claude Toolbox" name needs a trademark/naming
  review first.
