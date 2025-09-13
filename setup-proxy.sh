#!/usr/bin/env bash
# Sets up nginx-proxy + acme-companion with named volumes & a dedicated network.
# Ports 80/443 must be reachable from the Internet.

set -Eeuo pipefail
IFS=$'\n\t'

log(){ echo "[+] $*"; }
err(){ echo "ERROR: $*" >&2; }

# ---- images / names / resources ----
IMG_PROXY="nginxproxy/nginx-proxy:latest"
IMG_ACME="nginxproxy/acme-companion:latest"

NET="proxy"
VOL_CERTS="np-certs"
VOL_HTML="np-html"
VOL_VHOSTD="np-vhost.d"
VOL_ACME="np-acme"

NAME_PROXY="nginx-proxy"
NAME_ACME="nginx-proxy-acme"

# ---- sanity checks ----
if ! command -v docker >/dev/null 2>&1; then
  err "Docker is required but not found. Install Docker and re-run."
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon not responding. Start Docker and re-run."
  exit 1
fi

# ---- ask for optional default email for ACME ----
read -rp "Enter a contact email for Let's Encrypt (optional, press Enter to skip): " EMAIL_INPUT
EMAIL="${EMAIL_INPUT:-}"

# ---- network & volumes ----
log "Creating network '${NET}' (ok if exists)..."
docker network inspect "${NET}" >/dev/null 2>&1 || docker network create "${NET}" >/dev/null

log "Creating named volumes (ok if exist)..."
docker volume create "${VOL_CERTS}"  >/dev/null
docker volume create "${VOL_HTML}"   >/dev/null
docker volume create "${VOL_VHOSTD}" >/dev/null
docker volume create "${VOL_ACME}"   >/dev/null

# ---- pull images (best-effort) ----
log "Pulling images (may use cache)..."
docker pull "${IMG_PROXY}" >/dev/null || true
docker pull "${IMG_ACME}"  >/dev/null || true

# ---- (re)deploy nginx-proxy ----
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME_PROXY}"; then
  log "Recreating ${NAME_PROXY}..."
  docker rm -f "${NAME_PROXY}" >/dev/null || true
fi
log "Starting ${NAME_PROXY}..."
docker run -d \
  --name "${NAME_PROXY}" \
  --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v "${VOL_CERTS}:/etc/nginx/certs:ro" \
  -v "${VOL_VHOSTD}:/etc/nginx/vhost.d" \
  -v "${VOL_HTML}:/usr/share/nginx/html" \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
  --network "${NET}" \
  "${IMG_PROXY}" >/dev/null

# ---- (re)deploy acme-companion ----
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME_ACME}"; then
  log "Recreating ${NAME_ACME}..."
  docker rm -f "${NAME_ACME}" >/dev/null || true
fi

log "Starting ${NAME_ACME} (Let's Encrypt companion)..."
if [[ -n "${EMAIL}" ]]; then
  docker run -d \
    --name "${NAME_ACME}" \
    --restart unless-stopped \
    -e "DEFAULT_EMAIL=${EMAIL}" \
    -v "${VOL_CERTS}:/etc/nginx/certs" \
    -v "${VOL_VHOSTD}:/etc/nginx/vhost.d" \
    -v "${VOL_HTML}:/usr/share/nginx/html" \
    -v "${VOL_ACME}:/etc/acme.sh" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    --network "${NET}" \
    "${IMG_ACME}" >/dev/null
else
  docker run -d \
    --name "${NAME_ACME}" \
    --restart unless-stopped \
    -v "${VOL_CERTS}:/etc/nginx/certs" \
    -v "${VOL_VHOSTD}:/etc/nginx/vhost.d" \
    -v "${VOL_HTML}:/usr/share/nginx/html" \
    -v "${VOL_ACME}:/etc/acme.sh" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    --network "${NET}" \
    "${IMG_ACME}" >/dev/null
fi

log "Stack is up."
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

cat <<'EOF'

[INFO] Next step: run ./add-demo.sh to add a demo site behind the proxy.

Tips:
  - Make sure TCP 80 & 443 are open to the Internet.
  - Certs & ACME state persist in named volumes (np-certs, np-acme).
  - To update the default ACME email, recreate the acme container with DEFAULT_EMAIL.
EOF
