#!/bin/bash
# bootstrap-server.sh
# Sets up a fresh Ubuntu server as a deployment host.
# Run as root.
#
# Usage:
#   curl -o /tmp/bootstrap-server.sh \
#     https://raw.githubusercontent.com/Smartoys/devops/main/scripts/bootstrap-server.sh
#   bash /tmp/bootstrap-server.sh \
#     --pubkey "ssh-ed25519 AAAA... github-actions-deploy" \
#     --tunnel-token "eyJ..." \
#     --email "you@example.com" \
#     --cf-token "cfut_..."

set -euo pipefail

# ── Arguments ─────────────────────────────────────────────────────────────────

PUBKEY=""
TUNNEL_TOKEN=""
EMAIL=""
CF_TOKEN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --pubkey)        PUBKEY="$2";        shift 2 ;;
    --tunnel-token)  TUNNEL_TOKEN="$2";  shift 2 ;;
    --email)         EMAIL="$2";         shift 2 ;;
    --cf-token)      CF_TOKEN="$2";      shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ -z "$PUBKEY" || -z "$TUNNEL_TOKEN" || -z "$EMAIL" || -z "$CF_TOKEN" ]]; then
  echo "Usage: $0 --pubkey \"ssh-ed25519 ...\" --tunnel-token \"eyJ...\" --email \"you@example.com\" --cf-token \"cfut_...\""
  exit 1
fi

echo ""
echo "=========================================="
echo " CLD Distribution — Server Bootstrap"
echo "=========================================="
echo ""

# ── 1. System update ──────────────────────────────────────────────────────────

echo "==> [1/7] Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git jq

# ── 2. Docker ─────────────────────────────────────────────────────────────────

echo "==> [2/7] Installing Docker..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
else
  echo "    Docker already installed: $(docker --version)"
fi

# ── 3. Traefik network + stack ────────────────────────────────────────────────

echo "==> [3/7] Setting up Traefik..."
docker network create traefik 2>/dev/null || echo "    traefik network already exists"

mkdir -p /opt/stacks/traefik/certs
touch /opt/stacks/traefik/certs/acme.json
chmod 600 /opt/stacks/traefik/certs/acme.json

# Store CF token for Traefik DNS challenge
cat > /opt/stacks/traefik/.env <<EOF
CF_DNS_API_TOKEN=${CF_TOKEN}
EOF
chmod 600 /opt/stacks/traefik/.env

cat > /opt/stacks/traefik/docker-compose.yml <<EOF
services:
  traefik:
    image: traefik:v3.6
    restart: unless-stopped
    command:
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.docker.network=traefik"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/stacks/traefik/certs:/certs
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF

docker compose -f /opt/stacks/traefik/docker-compose.yml up -d
echo "    Traefik started."

# ── 4. cloudflared ────────────────────────────────────────────────────────────

echo "==> [4/7] Setting up Cloudflare Tunnel..."
mkdir -p /opt/stacks/cloudflared

cat > /opt/stacks/cloudflared/.env <<EOF
TUNNEL_TOKEN=${TUNNEL_TOKEN}
EOF
chmod 600 /opt/stacks/cloudflared/.env

cat > /opt/stacks/cloudflared/docker-compose.yml <<'EOF'
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    networks:
      - traefik

networks:
  traefik:
    external: true
EOF

docker compose -f /opt/stacks/cloudflared/docker-compose.yml up -d
echo "    cloudflared started."

# ── 5. Tailscale ──────────────────────────────────────────────────────────────

echo "==> [5/7] Installing Tailscale..."
if ! command -v tailscale &>/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
  echo ""
  echo "    !! ACTION REQUIRED: Authenticate Tailscale !!"
  echo "    Run: tailscale up"
  echo "    Open the URL it prints and authenticate."
  echo "    Then re-run this script or continue manually."
  echo ""
else
  echo "    Tailscale already installed: $(tailscale version)"
fi

# ── 6. Deploy user ────────────────────────────────────────────────────────────

echo "==> [6/7] Setting up deploy user..."

if ! id deploy &>/dev/null; then
  useradd -m -s /bin/bash -c "CI/CD deploy account" deploy
fi

mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh

AUTH_KEYS="/home/deploy/.ssh/authorized_keys"
FORCED_LINE="command=\"/opt/deploy/run.sh\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUBKEY"
echo "$FORCED_LINE" > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R deploy:deploy /home/deploy/.ssh

mkdir -p /opt/deploy
cat > /opt/deploy/run.sh << 'DEPLOY_SCRIPT'
#!/bin/bash
set -euo pipefail

validate() {
  local name="$1" value="$2" pattern="$3"
  if [[ ! "$value" =~ $pattern ]]; then
    echo "ERROR: Invalid value for $name: '$value'" >&2
    exit 1
  fi
}

validate "APP"       "$APP"       '^[a-z0-9_-]{1,64}$'
validate "IMAGE"     "$IMAGE"     '^ghcr\.io/[a-zA-Z0-9_./:-]{1,200}$'
validate "SUBDOMAIN" "$SUBDOMAIN" '^[a-z0-9.-]{1,253}$'
validate "PORT"      "$PORT"      '^[0-9]{1,5}$'

if (( PORT < 1 || PORT > 65535 )); then
  echo "ERROR: PORT out of range: $PORT" >&2
  exit 1
fi

STACK_DIR="/opt/stacks/$APP"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
LOG_FILE="/var/log/deploy/$APP.log"

mkdir -p "$STACK_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"; }

log "Deploy started: app=$APP image=$IMAGE subdomain=$SUBDOMAIN port=$PORT"

TMPFILE=$(mktemp "$STACK_DIR/.docker-compose.XXXXXX")
cat > "$TMPFILE" <<EOF
services:
  app:
    image: ${IMAGE}
    restart: unless-stopped
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.${APP}.rule=Host(\`${SUBDOMAIN}\`)"
      - "traefik.http.routers.${APP}.entrypoints=web"
networks:
  traefik:
    external: true
EOF
mv "$TMPFILE" "$COMPOSE_FILE"
log "Compose file written."

echo "$GHCR_TOKEN" | sudo docker login ghcr.io -u deploy --password-stdin 2>&1 | tee -a "$LOG_FILE"
sudo docker compose -f "$COMPOSE_FILE" pull 2>&1 | tee -a "$LOG_FILE"
sudo docker compose -f "$COMPOSE_FILE" up -d --remove-orphans 2>&1 | tee -a "$LOG_FILE"
sudo docker image prune -f 2>&1 | tee -a "$LOG_FILE"

log "Deploy complete: $APP"
DEPLOY_SCRIPT

chmod 750 /opt/deploy/run.sh
chown root:deploy /opt/deploy/run.sh

mkdir -p /opt/stacks
chown deploy:deploy /opt/stacks
mkdir -p /var/log/deploy
chown deploy:deploy /var/log/deploy

cat > /etc/sudoers.d/deploy << 'SUDOERS'
deploy ALL=(root) NOPASSWD: /usr/bin/docker login ghcr.io *
deploy ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/stacks/*/docker-compose.yml pull
deploy ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/stacks/*/docker-compose.yml up -d --remove-orphans
deploy ALL=(root) NOPASSWD: /usr/bin/docker image prune -f
SUDOERS
chmod 440 /etc/sudoers.d/deploy
visudo -c && echo "    sudoers OK" || { echo "ERROR in sudoers!"; rm /etc/sudoers.d/deploy; exit 1; }

cat > /etc/ssh/sshd_config.d/deploy-env.conf << 'SSHD'
AcceptEnv APP IMAGE SUBDOMAIN PORT GHCR_TOKEN
PasswordAuthentication no
PermitRootLogin no
SSHD
systemctl reload ssh

# ── 7. Verify ─────────────────────────────────────────────────────────────────

echo "==> [7/7] Verifying..."
echo ""
echo "    Docker:      $(docker --version)"
echo "    Compose:     $(docker compose version)"
echo "    Tailscale:   $(tailscale version 2>/dev/null || echo 'not authenticated yet')"
echo "    Tailscale IP: $(tailscale ip -4 2>/dev/null || echo 'not authenticated yet')"
echo ""
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
echo ""
echo "=========================================="
echo " Bootstrap complete!"
echo "=========================================="
echo ""
echo " Next steps:"
echo "   1. Run: tailscale up  (if not done yet)"
echo "   2. Add Tailscale IP to GitHub org secret DEPLOY_HOST"
echo "   3. Add Cloudflare public hostname for this server in Zero Trust"
echo "   4. Push a repo with deploy.yml to trigger your first deploy"
echo ""
