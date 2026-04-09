# Smartoys Deployment Infrastructure — LLM Instructions

You are an AI assistant helping deploy containerized projects to the Smartoys
infrastructure. This document gives you everything you need to deploy a new
project from scratch: what files to create, what values to use, what the
operator needs to do manually, and how to verify success.

---

## Architecture overview

```
GitHub repo (any project)
  └── push to main
        └── GitHub Actions (.github/workflows/deploy.yml)
              └── calls Smartoys/devops reusable workflow
                    ├── builds Docker image → pushes to ghcr.io/smartoys/<app>
                    ├── Cloudflare API → adds tunnel ingress rule
                    ├── Cloudflare API → creates/updates DNS CNAME record
                    └── SSHs via Tailscale → deploy user → run.sh on server
                              └── docker compose up on dockerone VM
                                    └── Traefik picks up labels → routes traffic
```

**Key facts:**
- GitHub org: `Smartoys` (github.com/Smartoys)
- Devops repo: `Smartoys/devops`
- Reusable workflow: `Smartoys/devops/.github/workflows/reusable-deploy.yml@main`
- GHCR prefix: `ghcr.io/smartoys/<app>` (always lowercase)
- Deployment server: `dockerone` — Ubuntu VM behind NAT
- Traefik entrypoint: `web` (port 80, HTTP only — Cloudflare handles TLS)
- TLS: terminated at Cloudflare edge using `*.kemushi.eu` wildcard cert
- Tunnel: cloudflared container on dockerone, connects to Cloudflare Zero Trust
- SSH access: via Tailscale (`DEPLOY_HOST` = Tailscale IP stored in org secret)
- Domain: `kemushi.eu` (Cloudflare-managed)

---

## What the operator must do manually (one-time per new project)

**Nothing.** The pipeline is fully automated:
- Builds and pushes the Docker image to GHCR
- Adds the Cloudflare tunnel ingress rule via API
- Creates or updates the DNS CNAME record via API
- SSHes into dockerone and deploys the container
- Traefik picks up routing automatically

The only optional human step is approving the GitHub Actions
`production` environment gate if it is enabled.

---

## Files to create in the project repo

### 1. `deploy.yml` — place at repo root

```yaml
app: <app-name>               # lowercase, hyphens ok, no spaces (e.g. my-app)
subdomain: <app-name>.kemushi.eu
internal_port: <PORT>         # the port your container listens on internally
cloudflare_mode: tunnel       # always "tunnel" for dockerone (behind NAT)
```

**Rules:**
- `app` must match the repo name exactly (lowercase, hyphens only)
- `subdomain` must be `<app>.kemushi.eu`
- `internal_port` is the port INSIDE the container, not the host port
- `cloudflare_mode` is always `tunnel` for dockerone

**Example:**
```yaml
app: my-api
subdomain: my-api.kemushi.eu
internal_port: 3000
cloudflare_mode: tunnel
```

### 2. `.github/workflows/deploy.yml` — place in repo

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    uses: Smartoys/devops/.github/workflows/reusable-deploy.yml@main
    secrets: inherit
```

Do not modify this file. It always calls the central reusable workflow.

### 3. `Dockerfile` — must exist at repo root

The pipeline runs `docker build .` from the repo root. A `Dockerfile` must
exist. If the project already has one, no changes needed.

**Minimal example (Node.js):**
```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
CMD ["node", "index.js"]
```

**Minimal example (Python):**
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["python", "app.py"]
```

---

## GitHub org secrets (already configured — do not recreate)

These are set at org level and inherited by all Smartoys repos automatically:

| Secret | Purpose |
|---|---|
| `DEPLOY_SSH_KEY` | Ed25519 private key for deploy user on dockerone |
| `DEPLOY_HOST` | Tailscale IP of dockerone (100.66.20.103) |
| `GHCR_TOKEN` | GitHub classic PAT with read:packages scope |
| `CF_API_TOKEN` | Cloudflare API token (DNS Edit + Tunnel Edit) |
| `CF_ZONE_ID` | kemushi.eu zone ID |
| `CF_ACCOUNT_ID` | Cloudflare account ID |
| `CF_TUNNEL_ID` | Cloudflare tunnel ID (328f55bf-8db5-43a9-85a8-fe0a7d438b70) |
| `TAILSCALE_AUTH_KEY` | Tailscale ephemeral auth key for GitHub Actions runner |

**Do not ask the operator to add these** — they are already there. If a secret
is missing, tell the operator which one and where to add it:
github.com/organizations/Smartoys → Settings → Secrets and variables → Actions

---

## GitHub Actions environment gate

The reusable workflow uses `environment: production`. This means every deploy
requires manual approval in the GitHub Actions UI before the SSH deploy step
runs. Tell the operator to check the Actions tab and click Approve when prompted.

To remove the approval gate (for fully automatic deploys), remove the
`environment: production` line from the reusable workflow in Smartoys/devops.

---

## How the deploy works on the server

When GitHub Actions SSHes into dockerone as the `deploy` user, it runs
`/opt/deploy/run.sh` with these env vars:

| Var | Source |
|---|---|
| `APP` | `deploy.yml` → `app` field |
| `IMAGE` | `ghcr.io/smartoys/<app>:latest` |
| `SUBDOMAIN` | `deploy.yml` → `subdomain` field |
| `PORT` | `deploy.yml` → `internal_port` field |
| `GHCR_TOKEN` | org secret |

The script:
1. Validates all inputs (regex — rejects shell metacharacters)
2. Writes `/opt/stacks/<app>/docker-compose.yml`
3. Logs in to GHCR and pulls the image
4. Runs `docker compose up -d --remove-orphans`
5. Prunes dangling images
6. Logs everything to `/var/log/deploy/<app>.log`

The generated compose file looks like:
```yaml
services:
  app:
    image: ghcr.io/smartoys/<app>:latest
    restart: unless-stopped
    networks:
      - traefik
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<app>.rule=Host(`<subdomain>`)"
      - "traefik.http.routers.<app>.entrypoints=web"
networks:
  traefik:
    external: true
```

Traefik picks up the labels automatically and starts routing within seconds.

---

## Environment variables for the container

If the project needs env vars (database URLs, API keys, etc.), they cannot be
passed through the current pipeline automatically. Two options:

**Option A — add to the deploy.yml and run.sh (recommended for non-secrets):**
Tell the operator to add them to the compose template in `/opt/deploy/run.sh`
on the server under the `environment:` key.

**Option B — create a .env file on the server manually:**
```bash
# On dockerone, after first deploy:
cat > /opt/stacks/<app>/.env <<EOF
DATABASE_URL=postgres://...
API_KEY=...
EOF
# Then add env_file to the compose:
# env_file: .env
```

Then redeploy by pushing an empty commit.

---

## Verifying a deployment

After the pipeline succeeds, verify end to end:

**1. Check the container is running (on dockerone):**
```bash
docker ps --filter name=<app>
```
Should show status `Up`.

**2. Check deploy log (on dockerone):**
```bash
tail -20 /var/log/deploy/<app>.log
```
Should end with `Deploy complete: <app>`.

**3. Check Traefik picked up the router (on dockerone):**
```bash
docker logs traefik-traefik-1 2>&1 | grep <app>
```
Should show no errors.

**4. Test the public URL:**
```bash
curl https://<app>.kemushi.eu
```
Should return a valid HTTP 200 response from the container.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `404 page not found` | Traefik has no matching router | Check container labels, check Traefik logs |
| `502 Bad Gateway` | Container not reachable by Traefik | Check container is on `traefik` network |
| `ERR EntryPoint doesn't exist entryPointName=websecure` | Old compose file with wrong entrypoint | Update `/opt/stacks/<app>/docker-compose.yml` entrypoints to `web` |
| Pipeline fails at SSH step | Tailscale not connected | Check `tailscale status` on dockerone |
| Pipeline fails at build step | Image name not lowercase | Ensure `app` in deploy.yml is all lowercase |
| `invalid tag` GHCR error | Uppercase in image name | Fix app name to lowercase in deploy.yml |
| Cloudflare tunnel step fails | Missing CF secrets | Check org secrets CF_API_TOKEN, CF_ACCOUNT_ID, CF_TUNNEL_ID |
| Container starts but 404 | DNS CNAME not yet propagated | Wait 30s and retry — pipeline creates it automatically |

---

## Adding a second deployment server

If a new server needs to be added to the infrastructure:

1. Run the bootstrap script on the new server:
```bash
curl -o /tmp/bootstrap-server.sh \
  https://raw.githubusercontent.com/Smartoys/devops/main/scripts/bootstrap-server.sh

bash /tmp/bootstrap-server.sh \
  --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG8CMRMKE9vCerU63mDl9K/i+Wd0HEcwLsY/oL0Kk9/k github-actions-deploy" \
  --tunnel-token "<NEW_TUNNEL_TOKEN>" \
  --email "david@kemushi.eu" \
  --cf-token "<CF_API_TOKEN>"
```

2. Run `tailscale up` on the new server and authenticate.

3. Get the new Tailscale IP: `tailscale ip -4`

4. Update the `DEPLOY_HOST` org secret with the new IP (or create a
   server-specific secret and update the reusable workflow to use it).

5. Add a new Cloudflare Tunnel in Zero Trust. Public hostnames and DNS
   CNAME records are created automatically by the pipeline on first deploy.

---

## Quick reference — deploying a new project

```
1. Create deploy.yml at repo root
2. Create .github/workflows/deploy.yml at repo root
3. Ensure Dockerfile exists at repo root
4. Push to main
5. Approve the GitHub Actions production environment gate (if enabled)
6. Verify with: curl https://<app>.kemushi.eu
```
