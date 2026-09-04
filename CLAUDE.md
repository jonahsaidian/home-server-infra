# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

Replaces `DO_infra` (the old DigitalOcean + Terraform setup at
`../DO_infra`). Jonah bought a home server (HP EliteDesk 800 G4 — i5
3.1GHz, 16GB RAM, 256GB internal SSD, no dedicated GPU) and is moving
`farsi-transcriber` off DigitalOcean onto it, plus adding a new Immich
photo-server (see sibling repo `../immich-infra`). This repo owns
everything except the Immich stack itself: the Cloudflare Tunnel, the
non-Immich apps, host bootstrap (including remote admin access and the
external-drive mount), and the shared Docker network both repos use to
let the tunnel reach both stacks.

Full original requirements/interview and the approved plan are preserved
at `C:\Users\jonah\.claude\plans\i-want-to-move-floating-tower.md` — read
that for the complete picture if this file is insufficient. See
`SETUP.md` for the current step-by-step provisioning runbook.

## Current status (as of 2026-09-03)

Scaffolded locally, **not yet committed**, **no GitHub remote created**,
**nothing deployed to the mini PC yet**. Jonah is reviewing the code
before committing. DigitalOcean droplet (`DO_infra`) is still live and
serving `farsi-transcriber.jonahsaidian.com` — do not touch/destroy it
until the home server is verified working and DNS has been cut over.

The original bootstrap plan (Cloudflare Tunnel + runner only) has been
expanded after a further design pass: Tailscale for remote admin access,
Syncthing for Obsidian vault sync, an external-drive mount shared by
Immich/backups/Syncthing, and automated nightly Immich Postgres backups.
`bootstrap.sh` does not yet implement all of this — `SETUP.md` is the
target design and marks what's automated today vs. still manual/planned.

Remaining work, in order (mirrors the plan file's "Migration/cutover
order", expanded per `SETUP.md`):
1. Jonah reviews and commits this repo + `immich-infra`, pushes to GitHub.
2. Consolidate `bootstrap.sh` into the full `setup.sh` described in
   `SETUP.md` (Docker + `sg docker` group-race fix, `ufw` incl.
   `tailscale0`, shared `edge` network, external-drive mount via
   UUID/fstab, Tailscale install/up, Syncthing install + GUI password,
   systemd Immich-backup timer, GitHub Actions runner auto-registration
   via PAT). Not yet implemented.
3. Run `setup.sh` on the mini PC.
4. Create the Cloudflare Tunnel, fill in `cloudflared/config.yml` and
   `credentials.json` (gitignored, not in this repo).
5. Bring up `farsi-transcriber` + `cloudflared` here, verify at a staging
   hostname before cutting live DNS.
6. Bring up `immich-infra` (see that repo's CLAUDE.md/README).
7. Verify push-to-deploy works via the self-hosted runners (both repos).
8. `cloudflared tunnel route dns` for both hostnames — this is the actual
   DNS cutover, replacing the DO A-record with a tunnel CNAME.
9. Monitor 24-48h, then `terraform destroy` in `DO_infra` and archive it.

## Key decisions and why

- **Cloudflare Tunnel, not port-forward/DDNS.** Home ISP doesn't reliably
  give a static IP, and Jonah wants zero inbound ports opened on the
  router. `cloudflared` makes an outbound-only connection, so nginx is
  gone entirely — tunnel ingress rules (`cloudflared/config.yml`) do the
  TLS-termination + reverse-proxy job nginx did in `DO_infra`.
- **Self-hosted GitHub Actions runner, not Watchtower.** Jonah explicitly
  wants git-push-triggered deploys with control over timing, not
  unattended polling. The runner lives on the mini PC and polls GitHub
  outbound, so — same as the tunnel — no inbound port is needed to trigger
  a deploy either.
- **Shared external Docker network named `edge`.** `immich-infra` is a
  separate compose project; `cloudflared` here needs to reach
  `immich-server` there. Created once by `bootstrap.sh`
  (`docker network create edge`), both repos attach their
  externally-reachable service to it. Everything else (postgres, redis,
  machine-learning) stays off `edge` entirely.
- **`clean: false` on `actions/checkout` in the deploy workflow.**
  `.env`, `cloudflared/config.yml`, and `cloudflared/credentials.json` are
  gitignored secrets that must be placed manually, once, in the
  self-hosted runner's working copy on the server. Default
  `actions/checkout` behavior (`git clean -ffdx`) would wipe them on every
  deploy — this is disabled deliberately, don't "fix" it back to default.
- **DO droplet decommissioned only after cutover is verified**, not
  before. `farsi-transcriber` is the only app that was on it — confirmed
  with Jonah, no other migration scope.
- **Security:** Cloudflare Rate Limiting on `/api/auth/login` and WAF
  managed rules / Bot Fight Mode are configured at the Cloudflare level
  (dashboard, or add to this repo later if we want it as code) — not yet
  done, still a TODO from the plan. Cloudflare Access in front of these
  apps was deliberately skipped (breaks mobile app auth flows without
  extra service-token complexity Jonah decided isn't worth it here).
- **Tailscale for remote admin access, not just LAN SSH.** `ufw` denies
  all inbound by default and only allows SSH from the LAN CIDR, so there
  was no way to administer the box remotely. Tailscale adds an
  outbound-only mesh VPN (same no-open-ports model as the tunnel) so SSH
  and internal-only tools are reachable from anywhere; `ufw allow in on
  tailscale0` trusts that interface since only tailnet-authenticated
  devices can reach it. This is additive, not a replacement — `photos`
  and `farsi-transcriber` still need to be reachable by people/apps
  without Tailscale installed, so Cloudflare Tunnel keeps that job.
- **Syncthing (Obsidian vault sync) is reachable over Tailscale only, and
  requires a GUI password.** The GUI is a web admin panel separate from
  Syncthing's own device-to-device trust model (cert/ID-paired) — binding
  it to `0.0.0.0` with no auth would let anything that can reach the port
  reconfigure Syncthing (add devices, change shared folders). Never
  exposed via Cloudflare Tunnel.
- **Master `.env` for server-wide secrets, per-service `.env` for the
  rest.** The root `.env` in this repo holds things the host itself needs
  (GitHub PAT for runner registration, Tailscale auth key). `immich-infra`
  keeps its own `.env` (`JWT_SECRET`, `DB_PASSWORD`, etc.) — each
  service's secrets stay with that service's repo/compose project.
- **GitHub Actions runner registration is automated via a PAT, not a
  pasted one-time token.** Runner registration tokens expire in about an
  hour, so they can't be pre-supplied for a non-interactive `setup.sh`
  the way other secrets can. Instead a GitHub PAT lives in the master
  `.env` and `setup.sh` calls the GitHub API to mint a fresh registration
  token at run time.
- **External drive mounted at the host level, in this repo, not inside
  `immich-infra`.** The mount (via UUID in `/etc/fstab`) is generic infra
  that multiple things depend on — Immich's media library, the Postgres
  backup script, Syncthing's vault — so provisioning it lives in
  `setup.sh` here even though Immich itself stays a separate, fully
  dockerized repo.
- **Nightly Immich Postgres backups, local-only for now.** `pg_dump -Fc`
  runs inside the Immich Postgres container, writes to the external
  drive, and is pruned after 14 days by a systemd user timer
  (`loginctl enable-linger` keeps it running without an active login).
  Offsite/second-copy backup is a known gap, deliberately deferred — not
  a current concern per Jonah, since the drive itself gets backed up
  separately/periodically.

## Planned, not yet designed

- **Jellyfin.** Will run alongside Immich on the mini PC. Exposure model
  (LAN-only vs. Tailscale vs. public via Cloudflare Tunnel) not yet
  decided — treat as theoretical, nothing built.
- **AI-agent stack.** A separate repo running Pydantic AI workloads,
  triggered by systemd timers/path-unit file watchers, was part of the
  original setup sketch. It hasn't had the same design review as
  Tailscale/Syncthing/backups — treat as theoretical until it gets its
  own pass.

## Related repos

- `../immich-infra` — the Immich photo-server stack, deployed the same
  way, shares the `edge` network with this repo.
- `../DO_infra` — the repo being replaced. Do not modify; only
  `terraform destroy` it, and only after cutover is confirmed.
