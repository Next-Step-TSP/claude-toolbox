# Community Applications (CA) readiness checklist

This is the **deferred** checklist for the day we decide to flip
`claude-toolbox` from an internal, private-repo tool into something publicly
listed in Unraid's Community Applications. Nothing here needs doing now —
it's the punch list for that later decision, kept in the repo so it isn't
lost.

Do not start this without explicit sign-off — flipping a private repo/image
public and listing it publicly are both one-way-ish decisions worth a
deliberate go/no-go, not something to do incidentally while working on
something else.

## 0. Naming flag — read this first

**"Claude Toolbox" leans on Anthropic's "Claude" trademark.** Before any
public listing:

- Check Anthropic's current brand/trademark guidelines for third-party tool
  naming (usage of "Claude" in a product name, logo, etc.).
- Consider shipping the **public-facing display name** as something like
  "Claude Toolbox (Unofficial)" or a name that doesn't use "Claude" as the
  lead noun, even if the GitHub repo/image slug stays `claude-toolbox`
  internally. The Unraid template's user-visible `<Name>`/`Overview` are the
  first things to revisit if guidance suggests a change.
- This is a trademark/branding judgment call, not a technical one — get a
  second opinion before submitting.

## 1. Repo and license

- [ ] Add an OSI-approved LICENSE file at repo root (MIT is the common
      default for CA-listed tools unless there's a reason otherwise).
- [ ] README polish pass: confirm no internal-only references (private
      marketplace names, internal server hostnames, tenant-specific
      details) remain in anything a public visitor would read.
- [ ] Flip the GitHub repo `Next-Step-TSP/claude-toolbox` from private to
      **public**.

## 2. GHCR package

- [ ] Flip the `ghcr.io/next-step-tsp/claude-toolbox` package visibility to
      **public** (package Settings → Change visibility, in the GitHub
      package UI). Confirm an anonymous `docker pull` works from a machine
      with no prior `docker login`.
- [ ] Once public, remove the `docker login ghcr.io` dependency from the
      Unraid deployment: delete the block added to `/boot/config/go` (see
      `unraid/go-snippet.sh`) and drop the read:packages PAT.

## 3. CA template repo (from the official starter)

- [ ] Create `Next-Step-TSP/unraid-templates` from the official starter
      template repo, `unraid/unraid-community-apps-starter`
      (<https://github.com/unraid/unraid-community-apps-starter>) — this
      gives the required `ca_profile.xml` at repo root, an `icon.svg`, and
      the `templates/*.xml` layout CA's scanner expects.
- [ ] Move/adapt `unraid/claude-toolbox.xml` from this repo into that new
      template repo's `templates/` directory.
- [ ] Set the template's `<TemplateURL>` to the **raw GitHub URL** of the
      template file in `Next-Step-TSP/unraid-templates` (not this repo) —
      CA pulls the live template from that URL, so the template repo becomes
      the source of truth going forward.
- [ ] Fill in `ca_profile.xml` (maintainer name/contact, support URL, etc.)
      per the starter's own README.

## 4. Icon

- [ ] Replace the `unraid/icon/` TODO with a real, finished icon:
      **512x512 PNG** (transparent background preferred) is what this
      repo's template references; the CA starter repo separately wants an
      `icon.svg` for its own branding — check the starter's current
      requirements, they may have evolved since this was written.
- [ ] Re-check the naming flag (section 0) against whatever imagery is
      used — avoid reproducing Anthropic's own Claude mark/logo styling.

## 5. Account requirements

- [ ] Confirm **GitHub two-factor authentication (2FA)** is enabled on the
      account/org that will own the public repo and submit to CA — this is
      a hard requirement of the submission process, not optional.

## 6. Submission

- [ ] Submit at <https://ca.unraid.net/submit>, pointing at the
      `Next-Step-TSP/unraid-templates` repo.
- [ ] The submission runs a **live scan** of the template — it must
      successfully pull the (by now public) GHCR image and validate the XML
      against CA's schema. Fix and resubmit if the scan flags anything.
- [ ] After acceptance, spot-check that `claude-toolbox` actually appears in
      Unraid's Apps tab search from a clean Unraid install/test box.

## 7. Optional hardening for the public image

- [ ] Consider adopting Anthropic's own devcontainer `init-firewall.sh`
      pattern (an opt-in egress allowlist restricting the container's
      outbound network access to a known-good set of hosts) as an optional
      flag for the public image. This was intentionally deferred out of v1
      scope but is worth reconsidering once the image is world-reachable via
      a public template, since the audience/risk profile changes.
