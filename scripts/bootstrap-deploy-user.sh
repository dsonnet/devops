#!/bin/bash
# bootstrap-deploy-user.sh
# Run once as root (or with sudo) on the target VM.
# Sets up the hardened deploy user, directories, sudoers, and sshd config.
#
# Usage:
#   curl -O https://your-devops-repo/bootstrap-deploy-user.sh
#   sudo bash bootstrap-deploy-user.sh "ssh-ed25519 AAAA... github-actions-deploy"

set -euo pipefail

PUBLIC_KEY="${1:-}"
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Usage: $0 \"ssh-ed25519 AAAA... key-comment\""
  exit 1
fi

echo "==> Creating deploy user..."
if ! id deploy &>/dev/null; then
  useradd -m -s /bin/bash -c "CI/CD deploy account" deploy
fi

echo "==> Setting up SSH key with forced command..."
mkdir -p /home/deploy/.ssh
chmod 700 /home/deploy/.ssh

AUTH_KEYS="/home/deploy/.ssh/authorized_keys"
FORCED_LINE="command=\"/opt/deploy/run.sh\",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding $PUBLIC_KEY"

# Remove any existing entry for this key, then add the hardened one
grep -v "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null > /tmp/ak_tmp || true
echo "$FORCED_LINE" >> /tmp/ak_tmp
mv /tmp/ak_tmp "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown -R deploy:deploy /home/deploy/.ssh

echo "==> Installing deploy script..."
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

STACKS_ROOT="/opt/stacks"
STACK_DIR="$STACKS_ROOT/$APP"
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

echo "==> Setting up stacks directory..."
mkdir -p /opt/stacks
chown deploy:deploy /opt/stacks

echo "==> Setting up log directory..."
mkdir -p /var/log/deploy
chown deploy:deploy /var/log/deploy

echo "==> Installing sudoers rules..."
cat > /etc/sudoers.d/deploy << 'SUDOERS'
deploy ALL=(root) NOPASSWD: /usr/bin/docker login ghcr.io *
deploy ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/stacks/*/docker-compose.yml pull
deploy ALL=(root) NOPASSWD: /usr/bin/docker compose -f /opt/stacks/*/docker-compose.yml up -d --remove-orphans
deploy ALL=(root) NOPASSWD: /usr/bin/docker image prune -f
deploy ALL=(root) !NOPASSWD: /usr/bin/docker run *
deploy ALL=(root) !NOPASSWD: /usr/bin/docker exec *
deploy ALL=(root) !NOPASSWD: /usr/bin/docker rm *
deploy ALL=(root) !NOPASSWD: /usr/bin/docker rmi *
SUDOERS
chmod 440 /etc/sudoers.d/deploy
visudo -c && echo "sudoers OK" || { echo "ERROR: sudoers syntax error!"; rm /etc/sudoers.d/deploy; exit 1; }

echo "==> Configuring sshd AcceptEnv..."
SSHD_DROP="/etc/ssh/sshd_config.d/deploy-env.conf"
cat > "$SSHD_DROP" << 'SSHD'
AcceptEnv APP IMAGE SUBDOMAIN PORT GHCR_TOKEN
PasswordAuthentication no
PermitRootLogin no
SSHD
systemctl reload ssh

echo ""
echo "==> Done. Summary:"
echo "    deploy user:    $(id deploy)"
echo "    authorized_keys: $AUTH_KEYS"
echo "    deploy script:  /opt/deploy/run.sh"
echo "    sudoers:        /etc/sudoers.d/deploy"
echo "    sshd config:    $SSHD_DROP"
echo "    stacks dir:     /opt/stacks"
echo "    log dir:        /var/log/deploy"
