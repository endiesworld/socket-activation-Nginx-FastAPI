#!/usr/bin/env bash
set -euo pipefail

# provisioning.sh
#
# One-time host provisioning for Arch Linux bare metal:
# - Create the dedicated app user
# - Install systemd units (socket-activated Gunicorn/Uvicorn)
# - Install tmpfiles.d rule to create /run/fastAPI on boot
# - (Optional) Install nginx reverse proxy config and enable nginx
# - Prepare a venv base directory under /var/lib/fastAPI (used by deploy.sh)
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
VENV_BASE_DIR="/var/lib/fastAPI"
ENV_DIR="/etc/fastAPI"
ENV_FILE="/etc/fastAPI/fastAPI.env"

UNIT_SOCKET="fastAPI-unix.socket"
UNIT_SERVICE="fastAPI-unix.service"

WITH_NGINX=0
SOCKET_GROUP=""
NGINX_SERVER_NAME=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  sudo ops/scripts/provisioning.sh [--with-nginx] [--nginx-server-name NAMES] [--socket-group GROUP] [--dry-run]

What it does (one-time provisioning):
  - Creates user/group: fastapi
  - Creates /opt/fastAPI and /etc/fastAPI
  - Creates /var/lib/fastAPI (venv base)
  - Installs systemd units:
      /etc/systemd/system/fastAPI-unix.socket
      /etc/systemd/system/fastAPI-unix.service
  - Installs tmpfiles rule:
      /etc/tmpfiles.d/fastAPI.conf
  - Enables socket activation:
      systemctl enable --now fastAPI-unix.socket
  - Optional nginx integration:
      Installs a vhost snippet into the directory that your nginx config includes
      (commonly /etc/nginx/http.d on Arch, sometimes /etc/nginx/conf.d).
      systemctl enable --now nginx

Notes:
  - This script does not install Arch packages (pacman). See README.md for the package list.
  - This script does not deploy code. Use ops/scripts/deploy.sh after provisioning.

Options:
  --with-nginx   Install nginx vhost + enable nginx
  --nginx-server-name Override the nginx `server_name` line (example: "example.com www.example.com")
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
    --nginx-server-name)
      NGINX_SERVER_NAME="${2:-}"
      if [[ -z "$NGINX_SERVER_NAME" ]]; then
        log "ERROR: --nginx-server-name requires a value"
        exit 2
      fi
      shift 2
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

detect_nginx_snippets_dir() {
  # Determine where nginx loads per-site snippets from.
  #
  # On Arch, /etc/nginx/nginx.conf typically contains:
  #   include /etc/nginx/http.d/*.conf;
  #
  # Other distros may use:
  #   include /etc/nginx/conf.d/*.conf;
  #
  # We only inspect /etc/nginx/nginx.conf here (not nginx -T) so this works even
  # before nginx is enabled.
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

ensure_nginx_includes_dir() {
  # Ensure /etc/nginx/nginx.conf loads per-site snippets from the given directory.
  #
  # If nginx.conf already includes it *inside the http {} block*, do nothing.
  # Otherwise:
  #  - remove any include of this dir outside of http {} (invalid for server/upstream snippets)
  #  - insert an `include <dir>/*.conf;` immediately after the `http {` opening.
  local snippets_dir="$1"
  local conf="/etc/nginx/nginx.conf"
  local include_line="    include ${snippets_dir}/*.conf;"
  local include_abs="${snippets_dir}/*.conf"
  local include_rel="${snippets_dir#/etc/nginx/}/*.conf"
  local python_bin=""

  if command -v python3 >/dev/null 2>&1; then
    python_bin="python3"
  elif command -v python >/dev/null 2>&1; then
    python_bin="python"
  else
    log "ERROR: python is required to edit $conf automatically (install python/python3)."
    exit 1
  fi

  if [[ ! -f "$conf" ]]; then
    log "ERROR: nginx config not found: $conf"
    exit 1
  fi

  log "nginx: ensuring $conf includes snippets inside http {}: ${include_line#????}"

  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  # Use a small Python helper for correctness across awk implementations.
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
    # Good enough for nginx.conf (we don't try to parse quoted # chars).
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

open_brace_idx: int | None = None

for i, raw in enumerate(text):
    s = strip_comments(raw)
    if re.match(r"^\s*http\s*\{", s):
        open_brace_idx = i
        break
    if re.match(r"^\s*http\s*$", s):
        if i + 1 < len(text) and re.match(r"^\s*\{", strip_comments(text[i + 1])):
            open_brace_idx = i + 1
            break

if open_brace_idx is None:
    raise SystemExit("ERROR: could not find an 'http { }' block in /etc/nginx/nginx.conf")

out: list[str] = []
inserted = False

for i, raw in enumerate(text):
    # Remove any target include anywhere (inside or outside http). We'll re-add in the right place.
    if is_target_include(raw):
        continue

    out.append(raw)

    if i == open_brace_idx and not inserted:
        out.append("    include " + include_abs + ";\n")
        inserted = True

backup = conf_path.with_suffix(conf_path.suffix + ".bak.fastapi")
if not backup.exists():
    backup.write_text("".join(text), encoding="utf-8")

conf_path.write_text("".join(out), encoding="utf-8")
PY
}

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
ensure_dir "$VENV_BASE_DIR" 0755
ensure_dir "$VENV_BASE_DIR/venvs" 0755
run chown -R "$APP_USER":"$APP_GROUP" "$VENV_BASE_DIR"

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
run systemctl reset-failed "$UNIT_SOCKET" "$UNIT_SERVICE"
run systemctl enable --now "$UNIT_SOCKET"

log "[7/8] Optional nginx integration"
if [[ "$WITH_NGINX" == "1" ]]; then
  require_cmd nginx
  NGINX_SNIPPETS_DIR="$(detect_nginx_snippets_dir)"
  ensure_nginx_includes_dir "$NGINX_SNIPPETS_DIR"
  ensure_dir "$NGINX_SNIPPETS_DIR" 0755
  # Clean up legacy/duplicate installs from earlier versions of this repo.
  # (Having both fastAPI.conf and 00-fastAPI.conf loaded causes duplicate upstream/server errors.)
  run rm -f "$NGINX_SNIPPETS_DIR/$APP_NAME.conf" || true
  # Install with a "00-" prefix to make it the default vhost on setups that
  # don't explicitly configure a default_server (common on minimal hosts).
  if [[ -n "$NGINX_SERVER_NAME" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "[dry-run] render nginx vhost: $NGINX_SRC (server_name=$NGINX_SERVER_NAME)"
      install_file "$NGINX_SRC" "$NGINX_SNIPPETS_DIR/00-$APP_NAME.conf" 0644
    else
      NGINX_RENDERED="$(mktemp)"
      sed -E "s/^([[:space:]]*server_name)[[:space:]]+.*;/\\1 ${NGINX_SERVER_NAME};/" "$NGINX_SRC" >"$NGINX_RENDERED"
      install_file "$NGINX_RENDERED" "$NGINX_SNIPPETS_DIR/00-$APP_NAME.conf" 0644
      rm -f "$NGINX_RENDERED"
    fi
  else
    install_file "$NGINX_SRC" "$NGINX_SNIPPETS_DIR/00-$APP_NAME.conf" 0644
  fi
  run nginx -t
  run systemctl enable --now nginx
  run systemctl reload nginx
else
  log "Skipping nginx (pass --with-nginx to enable)"
fi

log "[8/8] Done"
log "Next: deploy code from your repo checkout:"
log "  sudo bash ops/scripts/deploy.sh"
