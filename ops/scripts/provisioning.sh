#!/usr/bin/env bash
set -euo pipefail

# provisioning.sh
#
# One-time host provisioning for Arch Linux bare metal:
# - Create the dedicated app user
# - Install systemd units (socket-activated Gunicorn/Uvicorn)
# - Install tmpfiles.d rule to create /run/fastAPI on boot
# - (Optional) Install nginx reverse proxy config and enable nginx
#
# This script is intended to be idempotent and safe to re-run.
#
# Run from the repository root on the server:
#   sudo ops/scripts/provisioning.sh --with-nginx
#
# Then deploy code (repeatable step):
#   sudo ops/scripts/deploy.sh

APP_NAME="fastAPI"
APP_USER="fastapi"
APP_GROUP="fastapi"
BASE_DIR="/opt/fastAPI"
ENV_DIR="/etc/fastAPI"
ENV_FILE="/etc/fastAPI/fastAPI.env"

UNIT_SOCKET="fastAPI-unix.socket"
UNIT_SERVICE="fastAPI-unix.service"

WITH_NGINX=0
SOCKET_GROUP=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  sudo ops/scripts/provisioning.sh [--with-nginx] [--socket-group GROUP] [--dry-run]

What it does (one-time provisioning):
  - Creates user/group: fastapi
  - Creates /opt/fastAPI and /etc/fastAPI
  - Installs systemd units:
      /etc/systemd/system/fastAPI-unix.socket
      /etc/systemd/system/fastAPI-unix.service
  - Installs tmpfiles rule:
      /etc/tmpfiles.d/fastAPI.conf
  - Enables socket activation:
      systemctl enable --now fastAPI-unix.socket
  - Optional nginx integration:
      /etc/nginx/conf.d/fastAPI.conf
      systemctl enable --now nginx

Notes:
  - This script does not install Arch packages (pacman). See README.md for the package list.
  - This script does not deploy code. Use ops/scripts/deploy.sh after provisioning.

Options:
  --with-nginx   Install nginx vhost + enable nginx
  --socket-group Unix socket group ownership (defaults to 'http' with nginx, otherwise 'fastapi')
  --dry-run      Print actions without changing the system
  -h, --help     Show this help
EOF
}

log() {
  printf '%s\n' "$*"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] $*"
    return 0
  fi
  log "+ $*"
  "$@"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: required command not found: $cmd"
    exit 1
  fi
}

ensure_group() {
  local group="$1"
  if getent group "$group" >/dev/null 2>&1; then
    return 0
  fi
  run groupadd --system "$group"
}

ensure_dir() {
  local path="$1"
  local mode="$2"
  if [[ -d "$path" ]]; then
    return 0
  fi
  run install -d -m "$mode" "$path"
}

ensure_user() {
  if id -u "$APP_USER" >/dev/null 2>&1; then
    return 0
  fi
  run useradd --system --create-home --shell /usr/bin/nologin --gid "$APP_GROUP" "$APP_USER"
}

install_file() {
  local src="$1"
  local dst="$2"
  local mode="$3"
  if [[ ! -f "$src" ]]; then
    log "ERROR: missing source file: $src"
    exit 1
  fi
  run install -m "$mode" "$src" "$dst"
}

is_arch_linux() {
  [[ -f /etc/os-release ]] && . /etc/os-release && [[ "${ID:-}" == "arch" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-nginx)
      WITH_NGINX=1
      shift
      ;;
    --socket-group)
      SOCKET_GROUP="${2:-}"
      if [[ -z "$SOCKET_GROUP" ]]; then
        log "ERROR: --socket-group requires a value"
        exit 2
      fi
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log "ERROR: unknown argument: $1"
      log
      usage
      exit 2
      ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "ERROR: run as root (example: sudo ops/scripts/provisioning.sh)"
  exit 1
fi

require_cmd install
require_cmd systemctl
require_cmd useradd
require_cmd groupadd
require_cmd getent
require_cmd id
require_cmd sed
require_cmd mktemp

if ! is_arch_linux; then
  log "WARN: this script is written for Arch Linux; continuing anyway."
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

SYSTEMD_SOCKET_SRC="$REPO_ROOT/ops/systemd/$UNIT_SOCKET"
SYSTEMD_SERVICE_SRC="$REPO_ROOT/ops/systemd/$UNIT_SERVICE"
NGINX_SRC="$REPO_ROOT/ops/nginx/$APP_NAME.conf"

if [[ -z "$SOCKET_GROUP" ]]; then
  if [[ "$WITH_NGINX" == "1" ]]; then
    SOCKET_GROUP="http"
  else
    SOCKET_GROUP="$APP_GROUP"
  fi
fi

log "[1/8] Create app user/group"
ensure_group "$APP_GROUP"
ensure_user

ensure_group "$SOCKET_GROUP"

log "[2/8] Create base directories"
ensure_dir "$BASE_DIR" 0755
ensure_dir "$BASE_DIR/releases" 0755
ensure_dir "$ENV_DIR" 0755

log "[3/8] Ensure environment file exists"
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] write: $ENV_FILE"
  else
    cat >"$ENV_FILE" <<'EOF'
# Environment variables for fastAPI systemd service.
#
# Format: KEY=value
# Lines starting with # are comments.
#
# Examples:
# LOG_LEVEL=info
# SOME_API_KEY=...
EOF
    chmod 0640 "$ENV_FILE"
    chown root:"$APP_GROUP" "$ENV_FILE"
  fi
fi

log "[4/8] Install tmpfiles rule (/run/fastAPI)"
if [[ "$DRY_RUN" == "1" ]]; then
  log "[dry-run] write: /etc/tmpfiles.d/$APP_NAME.conf (group=$SOCKET_GROUP)"
else
  cat >"/etc/tmpfiles.d/$APP_NAME.conf" <<EOF
# $APP_NAME runtime directory (created on boot by systemd-tmpfiles)
d /run/$APP_NAME 0750 $APP_USER $SOCKET_GROUP - -
EOF
  chmod 0644 "/etc/tmpfiles.d/$APP_NAME.conf"
fi
run systemd-tmpfiles --create "/etc/tmpfiles.d/$APP_NAME.conf"

log "[5/8] Install systemd units"
if [[ "$DRY_RUN" == "1" ]]; then
  log "[dry-run] render systemd socket: $SYSTEMD_SOCKET_SRC (SocketGroup=$SOCKET_GROUP)"
  install_file "$SYSTEMD_SOCKET_SRC" "/etc/systemd/system/$UNIT_SOCKET" 0644
else
  SOCKET_RENDERED="$(mktemp)"
  sed -E "s/^SocketGroup=.*/SocketGroup=${SOCKET_GROUP}/" "$SYSTEMD_SOCKET_SRC" >"$SOCKET_RENDERED"
  install_file "$SOCKET_RENDERED" "/etc/systemd/system/$UNIT_SOCKET" 0644
  rm -f "$SOCKET_RENDERED"
fi
install_file "$SYSTEMD_SERVICE_SRC" "/etc/systemd/system/$UNIT_SERVICE" 0644
run systemctl daemon-reload

log "[6/8] Enable socket activation"
run systemctl enable --now "$UNIT_SOCKET"

log "[7/8] Optional nginx integration"
if [[ "$WITH_NGINX" == "1" ]]; then
  require_cmd nginx
  ensure_dir /etc/nginx/conf.d 0755
  install_file "$NGINX_SRC" "/etc/nginx/conf.d/$APP_NAME.conf" 0644
  run nginx -t
  run systemctl enable --now nginx
  run systemctl reload nginx
else
  log "Skipping nginx (pass --with-nginx to enable)"
fi

log "[8/8] Done"
log "Next: deploy code from your repo checkout:"
log "  sudo ops/scripts/deploy.sh"
