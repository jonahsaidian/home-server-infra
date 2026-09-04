# SETUP.md

Step-by-step runbook for provisioning the mini PC from scratch. This is
the target design agreed after reviewing the original setup strategy
against this repo (see git history / conversation log for the review) --
not everything below is implemented yet. Each automated step notes its
current status.

Status legend:
- **(done)** -- exists in `bootstrap.sh` today
- **(planned)** -- described here, not yet written

## 1. Hardware, OS, network (manual, outside any repo)

1. Install minimal Ubuntu Server via USB on the mini PC (enable OpenSSH
   during install; skip the "import SSH identity from GitHub" prompt --
   see step 2 below for why).
2. Connect the external storage drive.
3. In the router admin page, lock the mini PC's MAC address to a static
   local IP (DHCP reservation).
4. In BIOS setup (F10 at boot on this HP EliteDesk), set **Power ->
   After Power Loss** (or "Restore on AC/Power Loss") to **Power On**, so
   the box comes back up on its own after an outage instead of staying
   off. There's no Linux-side equivalent for this on HP business
   desktops -- it has to be set in BIOS.

## 2. Base access and secrets (manual, one-time)

1. Set up key-based login for yourself (client -> server, separate from
   the server's own GitHub key below): generate a personal key on your
   own machine if needed, then `ssh-copy-id user@server-ip` (or the
   manual `cat pubkey | ssh user@server-ip "cat >> ~/.ssh/authorized_keys"`
   equivalent on Windows without Git Bash) to install it. Verify
   password-less login before continuing.
2. Generate an SSH key (`ssh-keygen`) *on the server* and add it to
   GitHub, so the server can clone private repos. This is a distinct key
   from step 1 -- it's the server's own identity to GitHub, not yours to
   the server.
3. Clone this repo and `immich-infra` as siblings under the home
   directory (`~/home-server-infra`, `~/immich-infra`) -- matches the
   `../immich-infra` relative-path convention already used in
   `CLAUDE.md`. No renaming.
4. Create the master `.env` at `~/home-server-infra/.env`. This holds
   secrets the **host itself** needs, not any one service:
   - `GITHUB_PAT` -- used by `setup.sh` to mint a fresh, short-lived
     GitHub Actions runner registration token at run time (registration
     tokens expire in ~1 hour, so they can't be pre-supplied).
   - `TAILSCALE_AUTHKEY` -- for non-interactive `tailscale up`.
   - `OPENAI_API_KEY` -- consumed by `farsi-transcriber` (see
     `.env.example`).
   Copy it from your local machine with `scp`, or create it directly on
   the server -- either way this is a manual, one-time step.
5. Create `immich-infra`'s own `.env` there (`JWT_SECRET`, `DB_PASSWORD`,
   etc.) -- separate from the master `.env` above. See that repo's docs.

## 3. Storage discovery (manual, 1 minute)

Run `blkid` and note the `UUID=` of the external drive. This gets passed
into `setup.sh` in the next step.

## 4. Run `setup.sh` (planned -- not yet written; `bootstrap.sh` covers a subset today)

```
cd ~/home-server-infra && ./setup.sh <DRIVE_UUID>
```

Runs once, non-interactively, and is expected to handle:

- **System base (done)** -- `apt update`/`upgrade`, core tools
  (`curl`, `git`, `jq`).
- **Docker (done, needs a fix)** -- installs Docker + Compose plugin,
  `usermod -aG docker "$USER"`. The immediately-following
  `docker network create edge` call in today's `bootstrap.sh` actually
  runs before the new group membership takes effect in that same shell --
  needs wrapping in `sg docker -c '...'` (or an equivalent re-exec) so a
  truly fresh run doesn't fail here. **(planned fix)**
- **`ufw` (done, extended)** -- default deny incoming / allow outgoing,
  LAN-only SSH. Adding: `ufw allow in on tailscale0`, trusting that
  interface since only tailnet-authenticated devices can reach it.
  **(planned addition)**
- **Shared `edge` Docker network (done)** -- `docker network create edge`,
  used by `cloudflared` here and `immich-server` in `immich-infra`.
- **External drive mount (planned)** -- creates the mount point, maps the
  drive by the UUID passed in, and writes the `/etc/fstab` entry so it
  remounts automatically on reboot. Shared by Immich's media library, the
  Postgres backup script, and the Syncthing vault.
- **Tailscale (planned)** -- installs Tailscale, brings it up
  non-interactively using `TAILSCALE_AUTHKEY` from the master `.env`, and
  enables Tailscale SSH.
- **Syncthing + Obsidian vault (planned)** -- installs Syncthing, does a
  temporary initial launch to generate its config XML, sets a GUI
  username/password (required -- the GUI is a web admin panel, separate
  from Syncthing's own device-to-device trust model, and must not be
  reachable unauthenticated), binds the GUI so it's reachable over
  Tailscale, and creates `~/obsidian-vault/`.
- **Systemd automation (planned)** -- `loginctl enable-linger` so user
  units survive logout; installs the nightly Immich Postgres backup timer
  (see below). AI-agent systemd triggers are out of scope until that
  stack gets its own design pass (see `CLAUDE.md`).
- **GitHub Actions runner (planned)** -- calls the GitHub API with
  `GITHUB_PAT` from the master `.env` to mint a fresh runner registration
  token, registers the runner for this repo, and installs it as a
  service (`./svc.sh install && ./svc.sh start`) so it survives reboots.
  Repeat separately for `immich-infra` (its own runner, registered the
  same way from that repo).
- **Container stack launch (done, via `docker compose up -d`)** -- brings
  up `cloudflared` + `farsi-transcriber` here. `immich-infra` is brought
  up separately (step 6).

## 5. Cloudflare Tunnel (manual, one-time -- unchanged)

1. Install `cloudflared`, run `cloudflared tunnel login` and
   `cloudflared tunnel create home-server`. Copy the resulting
   credentials JSON to `cloudflared/credentials.json` (gitignored).
2. Copy `cloudflared/config.yml.example` to `cloudflared/config.yml` and
   fill in the tunnel UUID.
3. `docker compose up -d` (if not already brought up by `setup.sh`).

## 6. Bring up `immich-infra`

See that repo's own CLAUDE.md/README. It attaches `immich-server` to the
shared `edge` network created in step 4; the external drive mounted in
step 4 is where its media library lives.

## 7. Verify before cutover

Confirm both apps work at their tunnel hostnames, and that push-to-deploy
works end-to-end (push to `main` on both repos, confirm the self-hosted
runners pick it up) before touching DNS.

## 8. DNS cutover (manual)

```
cloudflared tunnel route dns home-server farsi-transcriber.jonahsaidian.com
cloudflared tunnel route dns home-server photos.jonahsaidian.com
```

This replaces the DO A-record with a tunnel CNAME -- the actual cutover.

## 9. Monitor and decommission

Monitor 24-48h, then `terraform destroy` in `DO_infra` and archive it.
Do not touch `DO_infra` before this point.

## Ongoing operations

**Deploys.** Push to `main` on either repo; the self-hosted runner there
pulls and runs `docker compose up -d`. No manual SSH needed after initial
setup.

**Immich Postgres backups (planned).** A systemd user timer
(`immich-backup.timer`, daily) runs `immich-backup.service`, which:

```bash
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/mnt/<drive-label>/backups/immich"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
docker exec immich_postgres pg_dump -U postgres -d immich -Fc \
  > "$BACKUP_DIR/immich-$TIMESTAMP.dump"
find "$BACKUP_DIR" -name 'immich-*.dump' -mtime +14 -delete
```

Writes to the external drive (outside any git repo), keeps 14 days,
`Persistent=true` on the timer so a missed run (machine off overnight)
fires on next boot. No DB password needed in the script -- `pg_dump` runs
inside the Postgres container via `docker exec`, using local trust auth.

Restore: `docker exec -i immich_postgres pg_restore -U postgres -d immich
--clean < immich-<timestamp>.dump`, after the stack is up but before
first use.

Offsite/second-copy backup is a known gap, deliberately deferred for now
-- the external drive itself gets backed up separately/periodically.

**Syncthing.** Reachable only over Tailscale, GUI password required.
Never exposed via Cloudflare Tunnel.

**Disaster recovery.** If the mini PC fails entirely: get a replacement,
run `setup.sh` again with the same (or a new) drive, restore the latest
Immich Postgres dump, and re-supply the master `.env` and
`immich-infra`'s `.env` from wherever they're kept safe (e.g. a password
manager) -- neither is recoverable from the drive itself.

## Planned, not yet designed

- **Jellyfin.** Will run alongside Immich. Exposure model (LAN-only vs.
  Tailscale vs. public) undecided -- nothing built.
- **AI-agent stack.** Separate repo, Pydantic AI workloads, systemd
  timer/file-watcher triggers. Part of the original setup sketch but not
  yet reviewed the way the rest of this document was -- theoretical only.
