#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# claude-toolbox: persist `docker login ghcr.io` across Unraid reboots.
#
# WHY THIS EXISTS
#   Unraid's rootfs is a RAM disk rebuilt from /boot on every boot, and there
#   is no GUI for private-registry credentials. Without this, `docker login`
#   done by hand from a terminal is lost on the next reboot, and the
#   claude-toolbox template's image pull fails with "unauthorized" as soon as
#   ghcr.io/next-step-tsp/claude-toolbox is treated as a private package again
#   (or on any host that hasn't logged in yet).
#
# WHAT TO DO WITH THIS FILE
#   Append the block below (edited with your real username + token) to
#   /boot/config/go on the Unraid server, so it runs once at every boot,
#   after the Docker service has started. Do NOT run this file standalone
#   with sh/bash — it's a snippet, meant to be appended.
#
# TOKEN
#   Create a dedicated GitHub PAT scoped to `read:packages` ONLY (classic PAT
#   or fine-grained with just that scope) — do not reuse a broader token here.
#   https://github.com/settings/tokens
#
# TRADEOFF: PLAINTEXT ON FLASH
#   /boot lives on the Unraid flash drive. Anything written into
#   /boot/config/go sits there UNENCRYPTED and is readable by anyone with
#   physical/SMB access to the flash share. This is an accepted, documented
#   tradeoff for a read-only-scoped token — never put a broader PAT (repo
#   write, admin, etc.) here. Rotate the token if the flash drive/backup is
#   ever exposed.
#
# THIS BECOMES UNNECESSARY LATER
#   Once ghcr.io/next-step-tsp/claude-toolbox is flipped to a PUBLIC package
#   (see docs/CA-CHECKLIST.md), anonymous `docker pull` works and this whole
#   block — and the PAT it depends on — can be deleted from /boot/config/go.
#
# ALTERNATIVE: User Scripts plugin ("At First Array Start")
#   Instead of editing /boot/config/go directly, you can install the
#   "User Scripts" Community Applications plugin and create a new script set
#   to run "At First Array Start". Paste the same docker login block there.
#   Pros: easier to find/edit/remove later from the web UI, keeps /boot/config/go
#   itself untouched. Cons: same plaintext-on-flash exposure (the script body
#   is still stored under /boot), and it depends on a plugin being installed
#   rather than stock Unraid. Either approach is fine — pick one, don't do both.
# ---------------------------------------------------------------------------

# --- begin: claude-toolbox ghcr.io login -----------------------------------
# Wait (briefly, non-blocking to boot) for the Docker daemon socket to come up
# before attempting login, since /boot/config/go can run before dockerd is
# ready. Gives up quietly after ~60s rather than hanging or failing boot.
(
  GHCR_USER="REPLACE_WITH_GITHUB_USERNAME"
  GHCR_TOKEN="REPLACE_WITH_read:packages_PAT"

  for _ in $(seq 1 60); do
    [ -S /var/run/docker.sock ] && break
    sleep 1
  done

  if [ -S /var/run/docker.sock ]; then
    echo "${GHCR_TOKEN}" | /usr/bin/docker login ghcr.io -u "${GHCR_USER}" --password-stdin \
      >>/var/log/claude-toolbox-ghcr-login.log 2>&1 \
      || echo "$(date -Is) claude-toolbox: docker login ghcr.io failed, see log" >>/var/log/claude-toolbox-ghcr-login.log
  else
    echo "$(date -Is) claude-toolbox: docker.sock never appeared, skipped login" >>/var/log/claude-toolbox-ghcr-login.log
  fi
) &
# --- end: claude-toolbox ghcr.io login -------------------------------------
