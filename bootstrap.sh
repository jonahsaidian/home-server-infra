#!/usr/bin/env bash
# One-time setup for the home server mini PC. Run once, manually, as a user
# with sudo access. Replaces what Terraform + cloud-init used to do for the
# DigitalOcean droplet.
set -euo pipefail

echo "==> Installing Docker"
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"

echo "==> Installing ufw and locking down inbound traffic"
sudo apt-get update
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
# LAN-only SSH, scoped to the actual home network range (192.168.4.29/22).
sudo ufw allow from 192.168.4.0/22 to any port 22 proto tcp
# Trust the tailscale0 interface -- only devices authenticated to the
# tailnet can reach it at all, so this is how remote admin SSH and
# internal-only tools (e.g. Syncthing) get reached off-LAN.
sudo ufw allow in on tailscale0
sudo ufw --force enable

echo "==> Creating shared 'edge' Docker network"
echo "    (used by cloudflared here and by immich-server in immich-infra"
echo "    so the tunnel can reach both stacks)"
# usermod -aG docker above doesn't take effect in this same shell/script --
# sg docker runs the command in a subshell with the new group active
# without needing a fresh login.
sg docker -c "docker network create edge" || true

cat <<'EOF'

==> Manual steps remaining:

1. Install cloudflared and create the tunnel:
     curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
     sudo dpkg -i cloudflared.deb
     cloudflared tunnel login
     cloudflared tunnel create home-server
   This writes a credentials JSON file -- copy it to
   cloudflared/credentials.json in this repo (gitignored).

2. Copy cloudflared/config.yml.example to cloudflared/config.yml and fill
   in the tunnel UUID.

3. Route DNS for both hostnames (creates CNAMEs, no manual Cloudflare
   dashboard edit needed):
     cloudflared tunnel route dns home-server farsi-transcriber.jonahsaidian.com
     cloudflared tunnel route dns home-server photos.jonahsaidian.com

4. Master .env (OPENAI_API_KEY, GITHUB_PAT, TAILSCALE_AUTHKEY) should
   already exist at this point -- see SETUP.md step 2.

5. Install a GitHub Actions self-hosted runner for this repo:
     https://github.com/<your-username>/home-server-infra/settings/actions/runners/new
   Run it as a service (./svc.sh install && ./svc.sh start) so it survives
   reboots. Repeat this step separately for the immich-infra repo.

6. docker compose up -d
EOF
