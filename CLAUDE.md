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

## Current status (as of 2026-09-17)

Both repos are committed and pushed to GitHub (`main`). On the mini PC:
`farsi-transcriber` + `cloudflared` are up and serving (transcriber verified
working by Jonah); the Immich stack (sibling repo) is up at v3.2.2 with its
library on the mounted external HDD (canary marker in place) and a fresh,
empty database. Tailscale is up (outbound-only) for remote admin access.
The DigitalOcean droplet (`DO_infra`) is still live and serving
`farsi-transcriber.jonahsaidian.com` — do not touch/destroy it until the home
server is verified working and DNS has been cut over.

Remaining work, in order:
1. Jonah tests Immich (re-create the admin account, upload a photo, check
   thumbnails) via the temporary SSH tunnel forward.
2. Verify push-to-deploy works via the self-hosted runners (both repos) —
   runners still need installing; manual registration for now.
3. DNS cutover, together with Jonah: `cloudflared tunnel route dns` for both
   hostnames (replacing the DO A-record with tunnel CNAMEs), enable the
   `photos.jonahsaidian.com` ingress, and remove both temporary forward
   containers.
4. Monitor 24-48h, then `terraform destroy` in `DO_infra` and archive it.

Still planned / not yet implemented: full `setup.sh` consolidation (see
`SETUP.md`), `systemd/immich.service` install, nightly Immich Postgres backup
timer, second backup drive (immich-infra Phase 2), Syncthing vault.
Jellyfin and the AI-agent stack remain theoretical.

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
  `cloudflared/config.yml` and `cloudflared/credentials.json` are
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
- **No master `.env` — deliberate.** `farsi-transcriber` needs no
  server-side secrets: each visitor pastes their own OpenAI key into the
  app UI (the `OPENAI_API_KEY` env var is only an optional auto-fill,
  empty by default — verified in the app source). `immich-infra` keeps
  its own `.env` (`JWT_SECRET`, `DB_PASSWORD`, etc.). Tailscale came up
  manually and runner registration is manual for now, so nothing needs a
  server-wide env file.
- **GitHub Actions runner registration is automated via a PAT, not a
  pasted one-time token.** Runner registration tokens expire in about an
  hour, so they can't be pre-supplied for a non-interactive `setup.sh`.
  `setup.sh` will take a GitHub PAT as an argument (no master `.env`) and
  call the GitHub API to mint a fresh registration token at run time.
  Manual registration until then.
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
