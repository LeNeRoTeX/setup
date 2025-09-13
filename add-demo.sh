#!/usr/bin/env bash
# Demo: nginx hello-world behind nginx-proxy + acme-companion.
# Works with prompts (on a real TTY), or non-interactively via:
#   FQDN=demo.example.com LETSENCRYPT_EMAIL=you@example.com ./add-demo.sh
#   DOMAIN=example.com SUBDOMAIN=demo LETSENCRYPT_EMAIL=you@example.com ./add-demo.sh
#   ./add-demo.sh -f demo.example.com -e you@example.com
#   ./add-demo.sh -d example.com -s demo -e you@example.com

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
valid_domain()    { [[ "$1" =~ ^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$ ]]; }
valid_subdomain() { [[ "$1" =~ ^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$ ]]; }
valid_email()     { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

usage() {
  cat >&2 <<USAGE
Usage:
  add-demo.sh [-f FQDN] [-d DOMAIN -s SUBDOMAIN] [-e EMAIL]

Examples:
  FQDN=demo.example.com LETSENCRYPT_EMAIL=you@example.com ./add-demo.sh
  ./add-demo.sh -f demo.example.com -e you@example.com
  ./add-demo.sh -d example.com -s demo -e you@example.com
USAGE
}

# ---- inputs: flags -> env -> prompt ----
FQDN="${FQDN:-}"
DOMAIN="${DOMAIN:-}"
SUBDOMAIN="${SUBDOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

while getopts ":f:d:s:e:h" opt; do
  case "$opt" in
    f) FQDN="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    s) SUBDOMAIN="$OPTARG" ;;
    e) LETSENCRYPT_EMAIL="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) err "Unknown flag: -$OPTARG"; usage; exit 1 ;;
    :)  err "Flag -$OPTARG requires a value"; usage; exit 1 ;;
  esac
done

FQDN="$(sanitize "${FQDN}")"
DOMAIN="$(sanitize "${DOMAIN}")"
SUBDOMAIN="$(sanitize "${SUBDOMAIN}")"
EMAIL="$(sanitize "${LETSENCRYPT_EMAIL}")"

# fetch default email from companion if not provided
if [[ -z "$EMAIL" ]]; then
  EMAIL="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' nginx-proxy-acme 2>/dev/null \
     | awk -F= '/^DEFAULT_EMAIL=/{print $2; exit}' || true)"
  EMAIL="$(sanitize "${EMAIL}")"
fi

# open a prompt fd if possible (for curl|bash)
PROMPT_FD=""
if [[ -t 0 ]]; then
  PROMPT_FD=0
elif [[ -r /dev/tty ]]; then
  exec 3</dev/tty
  PROMPT_FD=3
elif [[ -r /dev/console ]]; then
  exec 3</dev/console
  PROMPT_FD=3
fi

prompt() {
  # $1=message $2=default(optional)
  local msg="$1" def="${2:-}" in=""
  if [[ -n "$def" ]]; then
    printf "%s [%s]: " "$msg" "$def" >&2
  else
    printf "%s: " "$msg" >&2
  fi
  if [[ -n "$PROMPT_FD" ]]; then
    IFS= read -r -u "$PROMPT_FD" in || in=""
  else
    err "No TTY available to prompt. Provide values via flags or env."
    usage
    exit 1
  fi
  printf '%s' "$(sanitize "${in:-$def}")"
}

# FQDN / DOMAIN+SUBDOMAIN
if [[ -n "$FQDN" ]]; then
  fq="${FQDN,,}"
  if ! valid_domain "$fq"; then err "FQDN='${FQDN}' is invalid. Use e.g. demo.example.com"; exit 1; fi
  SUBDOMAIN="${fq%%.*}"
  DOMAIN="${fq#${SUBDOMAIN}.}"
else
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(prompt "Enter your top-level domain (e.g., example.com)")"
  fi
  DOMAIN="${DOMAIN,,}"
  if ! valid_domain "$DOMAIN"; then err "'$DOMAIN' is invalid. Expected something like 'example.com'."; exit 1; fi

  if [[ -z "$SUBDOMAIN" ]]; then
    SUBDOMAIN="$(prompt 'Enter your subdomain (e.g., demo)')"
  fi
  SUBDOMAIN="${SUBDOMAIN,,}"
  if ! valid_subdomain "$SUBDOMAIN"; then err "'$SUBDOMAIN' is invalid. Use lowercase letters/numbers/hyphens (no leading/trailing '-')."; exit 1; fi
fi

FQDN="${SUBDOMAIN}.${DOMAIN}"

# Email
if [[ -z "$EMAIL" ]]; then
  EMAIL="$(prompt "Enter Let's Encrypt email (required)")"
fi
if ! valid_email "$EMAIL"; then err "'$EMAIL' is invalid (e.g., you@example.com)."; exit 1; fi

log "FQDN: ${FQDN}"
log "Email: ${EMAIL}"

# ---- pull image (best-effort) ----
docker pull "${IMG_DEMO}" >/dev/null || true

# ---- (re)deploy ----
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME_DEMO}"; then
  log "Recreating ${NAME_DEMO}..."
  docker rm -f "${NAME_DEMO}" >/dev/null || true
else
  log "Creating ${NAME_DEMO}..."
fi

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

Re-run to change domain/subdomain/email, or remove with:
  docker rm -f ${NAME_DEMO}
EOF
