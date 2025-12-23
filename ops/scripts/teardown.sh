#!/usr/bin/env bash
set -euo pipefail

# teardown.sh
#
# Removes what this repo's provisioning/deploy scripts install on a host.
# Designed for repeatability: re-run safely.
#
# What this script can remove:
# - systemd socket/service units (fastAPI-unix.socket / fastAPI-unix.service)
# - tmpfiles rule for /run/fastAPI
# - nginx vhost snippet for this project (00-fastAPI.conf and legacy fastAPI.conf)
# - (optional) project data dirs under /opt and /var/lib
# - (optional) /etc/fastAPI env dir
# - (optional) the 'fastapi' system user/group
#
# What this script does NOT do:
# - uninstall system packages (nginx, python, uv, etc.)
# - modify firewall settings
#
# Usage (recommended):
#   sudo bash ops/scripts/teardown.sh --with-nginx --purge
#
# Dry run:
#   sudo bash ops/scripts/teardown.sh --with-nginx --purge --dry-run

APP_NAME="fastAPI"
APP_USER="fastapi"
APP_GROUP="fastapi"

UNIT_SOCKET="fastAPI-unix.socket"
UNIT_SERVICE="fastAPI-unix.service"

BASE_DIR="/opt/fastAPI"
VENV_BASE_DIR="/var/lib/fastAPI"
ENV_DIR="/etc/fastAPI"

WITH_NGINX=0
PURGE=0
REMOVE_USER=0
RESTORE_NGINX_CONF=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  sudo bash ops/scripts/teardown.sh [--with-nginx] [--purge] [--remove-user] [--restore-nginx-conf] [--dry-run]

Options:
  --with-nginx           Remove nginx snippet and project-managed nginx config (if installed)
  --purge                Also remove /opt/fastAPI, /var/lib/fastAPI and /etc/fastAPI
  --remove-user          Also remove system user/group 'fastapi' (implies --purge is recommended)
  --restore-nginx-conf   Restore /etc/nginx/nginx.conf from /etc/nginx/nginx.conf.bak.fastapi if present
  --dry-run              Print actions without changing the system
  -h, --help             Show this help

Notes:
  - If you host other sites in nginx using conf.d/http.d, do NOT use teardown with --with-nginx
    unless you're sure it's safe to remove the snippets include.
EOF
}

log() { printf '%s\n' "$*"; }

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

detect_nginx_snippets_dir() {
  # Match provisioning.sh behavior: prefer the dir nginx.conf includes.
  local conf="/etc/nginx/nginx.conf"
  local cleaned
  cleaned="$(sed -E 's/#.*$//' "$conf" 2>/dev/null || true)"

  if grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/http\.d/\*\.conf[[:space:]]*;' <<<"$cleaned"; then
    printf '%s\n' "/etc/nginx/http.d"
    return 0
  fi
  if grep -Eq '^[[:space:]]*include[[:space:]]+/etc/nginx/conf\.d/\*\.conf[[:space:]]*;' <<<"$cleaned"; then
    printf '%s\n' "/etc/nginx/conf.d"
    return 0
  fi

  if [[ -d /etc/nginx/http.d ]]; then
    printf '%s\n' "/etc/nginx/http.d"
  else
    printf '%s\n' "/etc/nginx/conf.d"
  fi
}

remove_nginx_snippets_include() {
  local snippets_dir="$1"
  local conf="/etc/nginx/nginx.conf"
  local include_abs="${snippets_dir}/*.conf"
  local include_rel="${snippets_dir#/etc/nginx/}/*.conf"

  if [[ ! -f "$conf" ]]; then
    log "WARN: nginx.conf not found at $conf; skipping include cleanup."
    return 0
  fi

  local python_bin=""
  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    log "WARN: python not found; cannot automatically remove nginx include line(s)."
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] remove include lines for: $include_abs (and $include_rel) from $conf"
    return 0
  fi

  "$python_bin" - "$conf" "$include_abs" "$include_rel" <<'PY'
import re
import sys
from pathlib import Path

conf_path = Path(sys.argv[1])
include_abs = sys.argv[2]
include_rel = sys.argv[3]

text = conf_path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
targets = {include_abs, include_rel}

include_re = re.compile(r"^\s*include\s+([^;]+)\s*;\s*$")

def strip_comments(line: str) -> str:
    return line.split("#", 1)[0]

def parse_include_path(line: str) -> str | None:
    m = include_re.match(strip_comments(line).rstrip("\n"))
    if not m:
        return None
    path = m.group(1).strip()
    if (path.startswith('"') and path.endswith('"')) or (path.startswith("'") and path.endswith("'")):
        path = path[1:-1]
    return path

def is_target_include(line: str) -> bool:
    path = parse_include_path(line)
    return path in targets

out = [line for line in text if not is_target_include(line)]
conf_path.write_text("".join(out), encoding="utf-8")
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-nginx) WITH_NGINX=1; shift ;;
    --purge) PURGE=1; shift ;;
    --remove-user) REMOVE_USER=1; shift ;;
    --restore-nginx-conf) RESTORE_NGINX_CONF=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log "ERROR: unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "ERROR: run as root (example: sudo bash ops/scripts/teardown.sh)"
  exit 1
fi

require_cmd systemctl
require_cmd sed
require_cmd grep
require_cmd rm

log "[1/6] Stop + disable systemd units"
run systemctl stop "$UNIT_SOCKET" || true
run systemctl stop "$UNIT_SERVICE" || true
run systemctl disable --now "$UNIT_SOCKET" || true
run systemctl reset-failed "$UNIT_SOCKET" "$UNIT_SERVICE" || true

log "[2/6] Remove unit files + tmpfiles rule"
run rm -f "/etc/systemd/system/$UNIT_SOCKET" "/etc/systemd/system/$UNIT_SERVICE"
run rm -f "/etc/tmpfiles.d/$APP_NAME.conf"
run systemctl daemon-reload

log "[3/6] (Optional) Remove nginx config"
if [[ "$WITH_NGINX" == "1" ]]; then
  require_cmd nginx
  local_snippets_dir="$(detect_nginx_snippets_dir)"
  run rm -f "$local_snippets_dir/00-$APP_NAME.conf" "$local_snippets_dir/$APP_NAME.conf"
  # Remove managed nginx config + systemd drop-in (newer provisioning uses these when nginx.conf
  # does not already include conf.d/http.d snippets).
  run rm -f /etc/nginx/nginx-fastapi.conf
  run rm -f /etc/systemd/system/nginx.service.d/10-fastapi.conf
  run systemctl daemon-reload

  if [[ "$RESTORE_NGINX_CONF" == "1" ]] && [[ -f /etc/nginx/nginx.conf.bak.fastapi ]]; then
    run cp -a /etc/nginx/nginx.conf.bak.fastapi /etc/nginx/nginx.conf
  else
    remove_nginx_snippets_include "$local_snippets_dir"
  fi

  run nginx -t
  run systemctl reload nginx
else
  log "Skipping nginx cleanup (pass --with-nginx to enable)"
fi

log "[4/6] (Optional) Remove project directories"
if [[ "$PURGE" == "1" ]]; then
  run rm -rf "$BASE_DIR" "$VENV_BASE_DIR" "$ENV_DIR"
else
  log "Keeping $BASE_DIR, $VENV_BASE_DIR, $ENV_DIR (pass --purge to remove)"
fi

log "[5/6] (Optional) Remove user/group"
if [[ "$REMOVE_USER" == "1" ]]; then
  require_cmd userdel
  require_cmd groupdel
  run userdel "$APP_USER" || true
  run groupdel "$APP_GROUP" || true
else
  log "Keeping user/group ($APP_USER/$APP_GROUP) (pass --remove-user to remove)"
fi

log "[6/6] Done"
