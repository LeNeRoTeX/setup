#!/usr/bin/env bash
# Demo: nginx hello-world behind nginx-proxy + acme-companion.
# Prompts with a real TTY; works non-interactively via flags or env:
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

# ---------- sanity ----------
command -v docker >/dev/null 2>&1 || { err "Docker is required but not found."; exit 1; }
docker info >/dev/null 2>&1 || { err "Docker daemon not responding."; exit 1; }
docker network inspect "${NET}" >/dev/null 2>&1 || { err "Network '${NET}' not found. Run ./setup-proxy.sh first."; exit 1; }
docker ps --format '{{.Names}}' | grep -qx 'nginx-proxy'      || { err "nginx-proxy not running. Run ./setup-proxy.sh first."; exit 1; }
docker ps --format '{{.Names}}' | grep -qx 'nginx-proxy-acme' || { err "acme-companion not running. Run ./setup-proxy.sh first."; exit 1; }

# ---------- helpers ----------
sanitize() { printf '%s' "$1" | sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

valid_label() {
  # DNS label: 1-63 chars, a-z0-9 and '-', no leading/trailing '-'
  local L="$1"
  [[ -n "$L" ]] || return 1
  (( ${#L} <= 63 )) || return 1
  case "$L" in
    -*|*-)   ;;  # we'll check edges next
  esac
  # only a-z0-9- allowed
  case "$L" in (*[!a-z0-9-]* ) return 1;; esac
  # no leading/trailing '-'
  [[ "${L:0:1}" != "-" && "${L: -1}" != "-" ]] || return 1
  return 0
}

valid_domain() {
  # domain: 2-253 chars, at least one dot, each label valid
  local D="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  (( ${#D} >= 3 && ${#D} <= 253 )) || return 1
  [[ "$D" == *.* ]] || return 1
  IFS='.' read -r -a parts <<<"$D"
  local p
  for p in "${parts[@]}"; do
    valid_label "$p" || return 1
  done
  return 0
}

valid_subdomain() {
  # subdomain is a single label
  local S="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  valid_label "$S"
}

valid_email() {
  # simple but safe check: one '@', non-empty local & domain, valid domain on RHS
  local E="$1"
  [[ "$E" == *"@"* ]] || return 1
  local localpart="${E%@*}"
  local domainpart="${E#*@}"
  [[ -n "$localpart" && -n "$domainpart" ]] || return 1
  valid_domain "$domainpart"
}

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

# ---------- inputs: flags -> env -> prompt ----------
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

# open prompt FD so prompts work even with curl|bash
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
  if [[ -n "$def" ]]; then printf "%s [%s]: " "$msg" "$def" >&2; else printf "%s: " "$msg" >&2; fi
  if [[ -n "$PROMPT_FD" ]]; then
    IFS= read -r -u "$PROMPT_FD" in || in=""
  else
    err "No TTY available to prompt. Provide values via flags or env."
    usage
    exit 1
  fi
  printf '%s' "$(sanitize "${in:-$def}")"
}

# Parse FQDN or DOMAIN+SUBDOMAIN
if [[ -n "$FQDN" ]]; then
  FQDN="$(printf '%s' "$FQDN" | tr 'A-Z' 'a-z')"
  valid_domain "$FQDN" || { err "FQDN='${FQDN}' is invalid. Use e.g. demo.example.com"; exit 1; }
  SUBDOMAIN="${FQDN%%.*}"
  DOMAIN="${FQDN#${SUBDOMAIN}.}"
else
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(prompt "Enter your top-level domain (e.g., example.com)")"
  fi
  DOMAIN="$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z')"
  valid_domain "$DOMAIN" || { err "'$DOMAIN' is invalid. Expected something like 'example.com'."; exit 1; }

  if [[ -z "$SUBDOMAIN" ]]; then
    SUBDOMAIN="$(prompt "Enter your subdomain (e.g., demo)")"
  fi
  SUBDOMAIN="$(printf '%s' "$SUBDOMAIN" | tr 'A-Z' 'a-z')"
  valid_subdomain "$SUBDOMAIN" || { err "'$SUBDOMAIN' is invalid. Use lowercase letters/numbers/hyphens (no leading/trailing '-')."; exit 1; }
fi

FQDN="${SUBDOMAIN}.${DOMAIN}"

# Email: default from companion if not provided
if [[ -z "$EMAIL" ]]; then
  EMAIL="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' nginx-proxy-acme 2>/dev/null \
     | awk -F= '/^DEFAULT_EMAIL=/{print $2; exit}' || true)"
  EMAIL="$(sanitize "${EMAIL}")"
fi
if [[ -z "$EMAIL" ]]; then
  EMAIL="$(prompt "Enter Let's Encrypt email (required)")"
fi
valid_email "$EMAIL" || { err "'$EMAIL' is invalid (e.g., you@example.com)."; exit 1; }

log "FQDN: ${FQDN}"
log "Email: ${EMAIL}"

# ---------- deploy ----------
docker pull "${IMG_DEMO}" >/dev/null || true

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
EOF
