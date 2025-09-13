#!/usr/bin/env bash
# Install Sysbox runtime and Docker CE on Debian/Ubuntu in strict mode
# and set Sysbox as the default Docker runtime (including systemd override fix).

set -Eeuo pipefail
IFS=$'\n\t'

# ---------- helpers ----------
err() { echo "ERROR: $*" >&2; }
log() { echo "[+] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
  fi
}

require_cmds() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    err "Missing required commands: ${missing[*]}"
    err "Install them and re-run."
    exit 1
  fi
}

has_systemctl() { command -v systemctl >/dev/null 2>&1; }

# Cleanup temp dir on exit
_tmp_dir=""
cleanup() {
  [[ -n "${_tmp_dir}" && -d "${_tmp_dir}" ]] && rm -rf "${_tmp_dir}"
}
trap cleanup EXIT

# ---------- pre-checks ----------
require_root
require_cmds apt-get dpkg tee chmod awk sed grep

if [[ ! -r /etc/os-release ]]; then
  err "/etc/os-release not found; unsupported system."
  exit 1
fi

. /etc/os-release
ID_LIKE_LOWER="$(echo "${ID_LIKE:-$ID}" | tr '[:upper:]' '[:lower:]')"
if ! echo "${ID_LIKE_LOWER} ${ID,,}" | grep -Eq '\bdebian\b|\bubuntu\b'; then
  err "This script targets Debian/Ubuntu-family systems. Detected: ${PRETTY_NAME:-unknown}"
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
if [[ "${ARCH}" != "amd64" ]]; then
  err "Sysbox .deb below is amd64; detected architecture: ${ARCH}"
  exit 1
fi

DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

APT_FLAGS=(-y -o Dpkg::Use-Pty=0 -o Acquire::Retries=3)

# ---------- apt refresh & base tools ----------
log "Updating APT package lists..."
apt-get update -o Acquire::Retries=3

log "Upgrading base system (safe, non-interactive)..."
apt-get upgrade "${APT_FLAGS[@]}"

log "Installing prerequisites (curl, ca-certificates, wget, gnupg, jq)..."
apt-get install "${APT_FLAGS[@]}" curl ca-certificates wget gnupg jq

# ---------- work dir ----------
_tmp_dir="$(mktemp -d -p /tmp sysbox-docker-XXXXXX)"
log "Using temp dir: ${_tmp_dir}"
cd "${_tmp_dir}"

# ---------- install Sysbox ----------
SYSBOX_VER="0.6.7"
SYSBOX_DEB="sysbox-ce_${SYSBOX_VER}-0.linux_amd64.deb"
SYSBOX_URL="https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VER}/${SYSBOX_DEB}"

if [[ ! -f "${SYSBOX_DEB}" ]]; then
  log "Downloading Sysbox ${SYSBOX_VER}..."
  wget -q --show-progress --progress=dot:giga "${SYSBOX_URL}"
else
  log "Sysbox package already present, skipping download."
fi

log "SHA256 of downloaded Sysbox package (for your records):"
sha256sum "${SYSBOX_DEB}"

log "Installing Sysbox..."
apt-get install "${APT_FLAGS[@]}" "./${SYSBOX_DEB}"

# ---------- install Docker CE (from Docker's official repo) ----------
log "Setting up Docker’s official APT repository..."
install -m 0755 -d /etc/apt/keyrings

# Use ASCII-armored keyring (Docker now publishes docker.asc)
curl -fsSL "https://download.docker.com/linux/debian/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Determine codename (Ubuntu & Debian)
CODENAME="$(
  . /etc/os-release
  echo "${VERSION_CODENAME:-}"
)"
if [[ -z "${CODENAME}" ]]; then
  CODENAME="$(awk -F'[= "]' '/VERSION=/ {print tolower($NF)}' /etc/os-release || true)"
fi
if [[ -z "${CODENAME}" ]]; then
  err "Could not determine distro codename."
  exit 1
fi

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

log "Refreshing APT after adding Docker repo..."
apt-get update -o Acquire::Retries=3

log "Installing Docker Engine, CLI, containerd, Buildx, and Compose plugin..."
apt-get install "${APT_FLAGS[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ---------- configure Docker to use Sysbox runtime (and set it as default) ----------
log "Configuring Docker daemon to register 'sysbox-runc' and set it as default..."
install -d -m 0755 /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP="/etc/docker/daemon.json.bak.$(date +%s)"

# Back up existing config if present (even empty)
if [[ -e "${DAEMON_JSON}" ]]; then
  cp -a "${DAEMON_JSON}" "${BACKUP}" || true
  log "Existing daemon.json backed up to ${BACKUP}"
fi

# Merge or create daemon.json
if [[ -s "${DAEMON_JSON}" ]]; then
  TMP_JSON="$(mktemp)"
  if jq '
      .runtimes = (.runtimes // {}) |
      .runtimes["sysbox-runc"] = {"path":"/usr/bin/sysbox-runc"} |
      .["default-runtime"] = "sysbox-runc"
    ' "${DAEMON_JSON}" > "${TMP_JSON}"; then
    mv "${TMP_JSON}" "${DAEMON_JSON}"
  else
    err "daemon.json contains invalid JSON; writing a fresh config."
    tee "${DAEMON_JSON}" >/dev/null <<'EOF'
{
  "runtimes": {
    "sysbox-runc": { "path": "/usr/bin/sysbox-runc" }
  },
  "default-runtime": "sysbox-runc"
}
EOF
  fi
else
  tee "${DAEMON_JSON}" >/dev/null <<'EOF'
{
  "runtimes": {
    "sysbox-runc": { "path": "/usr/bin/sysbox-runc" }
  },
  "default-runtime": "sysbox-runc"
}
EOF
fi

# ---------- systemd override fix (remove any --default-runtime=runc) ----------
if has_systemctl; then
  log "Ensuring systemd unit does not force '--default-runtime runc'..."
  mkdir -p /etc/systemd/system/docker.service.d

  # Build ExecStart similar to package default, but without any default-runtime flag.
  DOCKERD="/usr/bin/dockerd"
  DOCKERD_OPTS="-H fd://"
  if [[ -S /run/containerd/containerd.sock ]]; then
    DOCKERD_OPTS+=" --containerd=/run/containerd/containerd.sock"
  fi

  cat >/etc/systemd/system/docker.service.d/override.conf <<EOF
[Service]
# Reset ExecStart defined by the packaged unit
ExecStart=
# Start dockerd without forcing a default-runtime; it will honor /etc/docker/daemon.json
ExecStart=${DOCKERD} ${DOCKERD_OPTS}
EOF
fi

# ---------- reload/restart daemon ----------
if has_systemctl; then
  log "Reloading systemd units..."
  systemctl daemon-reload

  log "Restarting Docker..."
  systemctl restart docker
else
  log "systemctl not found; attempting service restart via service(8)..."
  if command -v service >/dev/null 2>&1; then
    service docker restart || true
  else
    err "Could not restart Docker automatically (no systemctl/service). Restart it manually."
  fi
fi

# ---------- final verification ----------
log "Verifying Docker runtime configuration..."
if ! command -v docker >/dev/null 2>&1; then
  err "docker command not found after installation."
  exit 1
fi

# Short summary (prints default and runtimes); fallback to full info if templating unsupported
if ! docker info --format $'Default runtime: {{.DefaultRuntime}}\nRuntimes: {{range $k,$v := .Runtimes}}{{printf "%s " $k}}{{end}}\nInit Binary: {{.InitBinary}}\ncontainerd version: {{.ContainerdVersion}}'; then
  log "Falling back to full 'docker info' output:"
  docker info || true
fi

log "Done. Docker should now use 'sysbox-runc' as the default runtime."
