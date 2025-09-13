#!/usr/bin/env bash
# Idempotent setup of nginx-proxy + acme-companion using named volumes & a dedicated network.
# Requires a contact email for Let's Encrypt; prompts via /dev/tty (works even when piped).

set -Eeuo pipefail
IFS=$'\n\t'

log(){ echo "[+] $*"; }
err(){ echo "ERROR: $*" >&2; }

IMG_PROXY="nginxproxy/nginx-proxy:latest"
IMG_ACME="nginxproxy/acme-companion:latest"

NET="proxy"
VOL_CERTS="np-certs"
VOL_HTML="np-html"
VOL_VHOSTD="np-vhost.d"
VOL_ACME="np-acme"

NAME_PROXY="nginx-proxy"
NAME_ACME="nginx-proxy-acme"

# ---- sanity: docker available ----
command -v docker >/dev/null 2>&1 || { err "Docker is required but not found."; exit 1; }
docker info >/dev/null 2>&1 || { err "Docker daemon not responding."; exit 1; }

# ---- email handling (prompt via /dev/tty if needed) ----
EMAIL=""                                 # initialize so set -u can't trip
: "${LETSENCRYPT_EMAIL:=}"               # define (possibly empty) to satisfy -u
EMAIL="${LETSENCRYPT_EMAIL}"

trim() { awk '{$1=$1; print}' <<<"$1"; } # trim leading/trailing spaces

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

prompt_email_tty() {
  local input
  while true; do
    # shellcheck disable=SC2162
    read -p "Enter a contact email for Let's Encrypt (required): " input < /dev/tty || true
    input="$(trim "${input:-}")"
    if [[ -n "$input" ]] && valid_email "$input"; then
      printf '%s' "$input"
      return 0
    fi
    echo "Invalid or empty email. Please try again." > /dev/tty
  done
}

if [[ -z "${EMAIL}" || ! $(valid_email "${EMAIL}") ]]; then
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    EMAIL="$(prompt_email_tty)"
  else
    err "A valid contact email is required, but no TTY is available for prompting.
Set it via environment variable, e.g.:
  LETSENCRYPT_EMAIL=you@example.com bash <(curl -fsSL https://raw.githubusercontent.com/LeNeRoTeX/setup/refs/heads/main/setup-proxy.sh)"
    exit 1
  fi
fi

# ---- helpers ----
ensure_network() {
  local net="$1"
  if ! docker network inspect "$net" >/dev/null 2>&1; then
    log "Creating network '$net'..."
    docker network create "$net" >/dev/null
  else
    log "Network '$net' exists."
  fi
}

ensure_volume() {
  local vol="$1"
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    log "Creating volume '$vol'..."
    docker volume create "$vol" >/dev/null
  else
    log "Volume '$vol' exists."
  fi
}

recreate_container() {
  local name="$1"; shift
  if docker ps -a --format '{{.Names}}' | grep -qx "$name"; then
    log "Recreating container '$name'..."
    docker rm -f "$name" >/dev/null || true
  else
    log "Creating container '$name'..."
  fi
  # shellcheck disable=SC2068
  docker run $@ >/dev/null
}

# ---- ensure resources ----
ensure_network "${NET}"
ensure_volume "${VOL_CERTS}"
ensure_volume "${VOL_HTML}"
ensure_volume "${VOL_VHOSTD}"
ensure_volume "${VOL_ACME}"

# ---- pull images (best effort) ----
log "Pulling images (may use cache)..."
docker pull "${IMG_PROXY}" >/dev/null || true
docker pull "${IMG_ACME}"  >/dev/null || true

# ---- (re)deploy nginx-proxy ----
recreate_container "${NAME_PROXY}" \
  -d \
  --name "${NAME_PROXY}" \
  --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v "${VOL_CERTS}:/etc/nginx/certs:ro" \
  -v "${VOL_VHOSTD}:/etc/nginx/vhost.d" \
  -v "${VOL_HTML}:/usr/share/nginx/html" \
  -v /var/run/docker.sock:/tmp/docker.sock:ro \
  --network "${NET}" \
  --label managed-by=setup-proxy.sh \
  "${IMG_PROXY}"

# ---- (re)deploy acme-companion (with REQUIRED email) ----
recreate_container "${NAME_ACME}" \
  -d \
  --name "${NAME_ACME}" \
  --restart unless-stopped \
  -e "DEFAULT_EMAIL=${EMAIL}" \
  -v "${VOL_CERTS}:/etc/nginx/certs" \
  -v "${VOL_VHOSTD}:/etc/nginx/vhost.d" \
  -v "${VOL_HTML}:/usr/share/nginx/html" \
  -v "${VOL_ACME}:/etc/acme.sh" \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --network "${NET}" \
  --label managed-by=setup-proxy.sh \
  "${IMG_ACME}"

log "Stack state:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

cat <<EOF

[OK] nginx-proxy + acme-companion are running.
Contact email: ${EMAIL}

Notes:
  • Re-run this script any time; it's idempotent and converges state.
  • Ports 80 and 443 must be reachable from the Internet.
  • Certs and ACME state persist in volumes: ${VOL_CERTS}, ${VOL_ACME}.

Next:
  ./add-demo.sh   # to add a demo site (will prompt for domain/subdomain)
EOF
