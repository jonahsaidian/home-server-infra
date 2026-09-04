# home-server-infra

Infrastructure for apps running on the home server, replacing `DO_infra`
(DigitalOcean + Terraform). Handles public exposure, remote admin access,
shared local infra (external-drive mount, backups), and everything that
isn't Immich (that lives in the sibling `immich-infra` repo).

## Architecture

```
Internet
    |
Cloudflare (DNS + WAF + rate limiting)
    |  (outbound-only connection, no ports opened on the router)
cloudflared  --- edge network ---> immich-server (in immich-infra)
    |
    | default network
    v
farsi-transcriber

Tailscale (outbound-only mesh VPN, no ports opened on the router either)
    |
    +--> SSH (remote admin access, anywhere -- not just the LAN)
    +--> Syncthing GUI (password-protected, Obsidian vault sync)
```

No nginx, no exposed ports, no firewall rules to manage on the droplet
level -- `cloudflared` terminates TLS at Cloudflare's edge and proxies
straight to each container over Docker networks. The mini PC's `ufw` denies
all inbound traffic by default; LAN SSH and the `tailscale0` interface are
allowed (the latter is trusted because only devices authenticated to the
tailnet can reach it at all).

Tailscale is additive, not a replacement for the tunnel: `farsi-transcriber`
and `photos` still need to be reachable by people/apps without Tailscale
installed, so they stay on Cloudflare Tunnel. Tailscale exists because
`ufw` alone gave no way to administer the box remotely, and because
Syncthing's GUI shouldn't be public.

Two Docker networks are involved:
- `default` (this compose project's own network) -- `cloudflared` and
  `farsi-transcriber` share it.
- `edge` (external, created once by `bootstrap.sh`) -- shared with
  `immich-infra` so `cloudflared` can also reach `immich-server` there.

An external drive is mounted at the host level (UUID in `/etc/fstab`) and
shared by things that don't belong in any one compose project: Immich's
media library, the nightly Immich Postgres backup dump, and the Syncthing
Obsidian vault.

## Prerequisites

- Docker installed (`bootstrap.sh` does this)
- A Cloudflare account managing `jonahsaidian.com`
- A Tailscale account, plus an auth key for non-interactive `tailscale up`
- `cloudflared` CLI installed on the host for one-time tunnel setup

## Setup

See `SETUP.md` for the full step-by-step runbook, from hardware prep
through DNS cutover. `bootstrap.sh` automates part of it today; `SETUP.md`
marks what's automated vs. still manual or planned.

## Deploys

Push to `main` and the self-hosted GitHub Actions runner (installed on the
mini PC) pulls the change and runs `docker compose up -d`. No inbound
access is required to trigger a deploy -- the runner polls GitHub
outbound. See `.github/workflows/deploy.yml`.

Secrets (`.env`, `cloudflared/config.yml`, `cloudflared/credentials.json`)
are gitignored and live only in the runner's working copy on the server --
place them there once during setup, they persist across deploys.

## Adding a New App

1. Add a service in `docker-compose.yml` (see the commented `app2` block)
2. Add a hostname -> service rule in `cloudflared/config.yml`
3. `cloudflared tunnel route dns home-server <new-hostname>`
4. Push to `main`

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | `cloudflared` + `farsi-transcriber` service definitions |
| `cloudflared/config.yml` | Tunnel ingress rules (hostname -> internal service); gitignored, copy from `.example` |
| `bootstrap.sh` | Host setup: Docker, ufw, shared `edge` network. Being consolidated into `setup.sh` -- see `SETUP.md` |
| `SETUP.md` | Full provisioning runbook: hardware prep through DNS cutover, marks what's automated vs. planned |
| `.github/workflows/deploy.yml` | Self-hosted-runner auto-deploy on push to `main` |
