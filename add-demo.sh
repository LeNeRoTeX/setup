#!/usr/bin/env bash
# Improved demo: nginx hello-world behind nginx-proxy + acme-companion.
# Prompts for domain (example.com) and subdomain (demo) -> demo.example.com
# Idempotent & works when piped (prompts via /dev/tty).

set -Eeuo pipefail
IFS=$'\n\t'

log(){ echo "[+] $*"; }
err(){ echo "ERROR: $*" >&2; }

IMG_DEMO="nginx:alpine"
NET="proxy"
NAME_DEMO="demo-hello"

# ---- sanity checks ----
command -v docker >/dev/null 2>&1 || { err "Docker is required but not found."; exit 1; }
docker info >/dev/null 2>&1 || { err "Docker daemon not responding."; exit 1; }
docker network inspect "${NET}" >/dev/null 2>&1 || { err "Network '${NET}' not found. Run ./setup-proxy.sh first."; exit 1; }
docker ps --format '{{.Names}}' | grep -qx 'nginx-proxy'      || { err "nginx-proxy not running. Run ./setup-proxy.sh first."; exit 1; }
docker ps --format '{{.Names}}' | grep -qx 'nginx-proxy-acme' || { err "acme-companion not running. Run ./setup-proxy.sh first."; exit 1; }

# ---- helpers ----
sanitize() { printf '%s' "$1" | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

valid_domain() {
  # basic FQDN (no scheme, no path), at least one dot, TLD 2+ chars
  [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]
}

valid_subdomain() {
  # label rules: a-z0-9 and hyphen (not starting/ending with hyphen)
  [[ "$1" =~ ^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$ ]]
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

prompt_tty() {
  # $1=message  $2=default (optional)
  local msg="$1" def="${2:-}" in
  if [[ -n "$def" ]]; then
    printf "%s [%s]: " "$msg" "$def" > /dev/tty
  else
    printf "%s: " "$msg" > /dev/tty
  fi
  IFS= read -r in < /dev/tty || in=""
  in="$(sanitize "${in}")"
  [[ -n "$in" ]] && printf '%s' "$in" || printf '%s' "$def"
}

# Try to get DEFAULT_EMAIL from acme-companion; allow env override
ACME_EMAIL="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' nginx-proxy-acme 2>/dev/null | awk -F= '/^DEFAULT_EMAIL=/{print $2; exit}' || true)"
: "${LETSENCRYPT_EMAIL:=${ACME_EMAIL:-}}"
EMAIL="$(sanitize "${LETSENCRYPT_EMAIL}")"

# Inputs via env (non-interactive friendly)
: "${DOMAIN:=''}"
: "${SUBDOMAIN:=''}"

DOMAIN="$(sanitize "${DOMAIN}")"
SUBDOMAIN="$(sanitize "${SUBDOMAIN}")"

# ---- prompt (via /dev/tty) if needed, with validation and friendly errors ----
if [[ -z "${DOMAIN}" ]]; then
  while :; do
    in="$(prompt_tty "Enter your top-level domain (e.g., example.com)")"
    in="$(sanitize "${in}")"
    if valid_domain "${in}"; then DOMAIN="${in,,}"; break; fi
    echo "'${in}' is invalid. Expected something like 'example.com'." > /dev/tty
  done
elif ! valid_domain "${DOMAIN}"; then
  err "DOMAIN='${DOMAIN}' is invalid. Use e.g. example.com"
  exit 1
else
  DOMAIN="${DOMAIN,,}"
fi

if [[ -z "${SUBDOMAIN}" ]]; then
  while :; do
    in="$(prompt_tty "Enter your subdomain (e.g., demo)")"
    in="$(sanitize "${in}")"
    if valid_subdomain "${in}"; then SUBDOMAIN="${in,,}"; break; fi
    echo "'${in}' is invalid. Use lowercase letters/numbers/hyphens (no leading/trailing '-' )." > /dev/tty
  done
elif ! valid_subdomain "${SUBDOMAIN}"; then
  err "SUBDOMAIN='${SUBDOMAIN}' is invalid."
  exit 1
else
  SUBDOMAIN="${SUBDOMAIN,,}"
fi

FQDN="${SUBDOMAIN}.${DOMAIN}"

# Email: prefer env/ACME; if missing or invalid, prompt
if [[ -z "${EMAIL}" || ! valid_email "${EMAIL}" ]]; then
  while :; do
    in="$(prompt_tty "Enter Let's Encrypt email (required)" "${EMAIL}")"
    in="$(sanitize "${in}")"
    if valid_email "${in}"; then EMAIL="${in}"; break; fi
    echo "'${in}' is invalid. Please enter a valid email (e.g., you@example.com)." > /dev/tty
  done
fi

log "FQDN: ${FQDN}"
log "Email: ${EMAIL}"

# ---- pull demo image (best effort) ----
docker pull "${IMG_DEMO}" >/dev/null || true

# ---- (re)deploy the demo container (idempotent) ----
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME_DEMO}"; then
  log "Recreating ${NAME_DEMO}..."
  docker rm -f "${NAME_DEMO}" >/dev/null || true
else
  log "Creating ${NAME_DEMO}..."
fi

# Create a simple custom page + /health and run nginx
docker run -d \
  --name "${NAME_DEMO}" \
  --restart unless-stopped \
  --network "${NET}" \
  -e "VIRTUAL_HOST=${FQDN}" \
  -e "LETSENCRYPT_HOST=${FQDN}" \
  -e "LETSENCRYPT_EMAIL=${EMAIL}" \
  --label managed-by=add-demo.sh \
  "${IMG_DEMO}" \
  sh -c 'set -e
         cat > /usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html>
<html lang="en">
<meta charset="utf-8">
<title>Hello from '"${FQDN}"'</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 2rem; }
  .card { max-width: 720px; padding: 1.25rem 1.5rem; border: 1px solid #ddd; border-radius: 12px; }
  h1 { margin: 0 0 .5rem 0; font-size: 1.75rem; }
  code { background: #f6f8fa; padding: .125rem .375rem; border-radius: 6px; }
</style>
<body>
  <div class="card">
    <h1>It works! 🎉</h1>
    <p>This is the demo site for <strong>'"${FQDN}"'</strong> behind <code>nginx-proxy</code> with automatic TLS.</p>
    <ul>
      <li>Backend container: <code>'"${IMG_DEMO}"'</code></li>
      <li>Health endpoint: <code>https://'"${FQDN}"'/health</code></li>
    </ul>
    <p>Edit this page by recreating the demo container with your own content.</p>
  </div>
</body>
</html>
HTML
         printf "ok" > /usr/share/nginx/html/health
         exec nginx -g "daemon off;"
        '

log "Current containers:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

cat <<EOF

[OK] Demo is (re)deployed at: https://${FQDN}

DNS & firewall checklist for automatic TLS:
  • Create an A/AAAA record: ${FQDN} -> your server's public IP
  • Ensure TCP 80 and 443 are open

Quick tests (after DNS propagates):
  curl -I http://${FQDN}
  curl -I https://${FQDN}
  curl -s https://${FQDN}/health

Re-run this script anytime to change domain/subdomain or email.
To remove the demo:
  docker rm -f ${NAME_DEMO}
EOF
