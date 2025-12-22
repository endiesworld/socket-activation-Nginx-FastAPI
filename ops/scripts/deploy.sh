#!/usr/bin/env bash

set -euo pipefail


APP_NAME="fastAPI"
BASE="/opt/fastAPI"
TMPFILES_CONF="/etc/tmpfiles.d/fastAPI.conf"

SOCKET_UNIT_FILE="/etc/systemd/system/fastAPI-unix.socket"
FALLBACK_SOCKET_PATH="/run/fastAPI/fastAPI.sock"
FALLBACK_SOCKET_USER="fastapi"
FALLBACK_SOCKET_GROUP="http"

get_systemd_value() {
  local file="$1"
  local key="$2"
  awk -F= -v k="$key" '$1==k {print $2}' "$file" | tail -n 1
}

SOCKET_PATH="$FALLBACK_SOCKET_PATH"
SOCKET_USER="$FALLBACK_SOCKET_USER"
SOCKET_GROUP="$FALLBACK_SOCKET_GROUP"

if [[ -f "$SOCKET_UNIT_FILE" ]]; then
  SOCKET_PATH="$(get_systemd_value "$SOCKET_UNIT_FILE" "ListenStream")"
  SOCKET_USER="$(get_systemd_value "$SOCKET_UNIT_FILE" "SocketUser")"
  SOCKET_GROUP="$(get_systemd_value "$SOCKET_UNIT_FILE" "SocketGroup")"
fi

SOCKET_DIR="$(dirname "$SOCKET_PATH")"

# Generates a unique ID based on the current time (UTC).
# This creates a unique folder for every single deployment history.
RELEASE_ID="$(date -u +%Y%m%d%H%M%S)"

# The full path where THIS specific version of the code will live.
RELEASE_DIR="$BASE/releases/$RELEASE_ID"

# The "Pointer" path. The live web server will always look at this path.
# We will point this symlink to the new RELEASE_DIR at the very end.
CURRENT="$BASE/current"

# --- SERVICE DEFINITIONS ---
# "${VAR:-default}" syntax means: If UNIT_SOCKET is passed in via environment, use it.
# Otherwise, default to 'fastAPI-unix.socket'.
UNIT_SOCKET="${UNIT_SOCKET:-fastAPI-unix.socket}" 
UNIT_SERVICE="${UNIT_SERVICE:-fastAPI-unix.service}"

echo "[1/7] Create release dir"
# 1. Create the timestamped directory. -p ensures parent folders exist and no error if it exists.
sudo mkdir -p "$RELEASE_DIR"

# 2. Set the owner to the 'fastapi' user so the app has permission to write logs/files.
sudo chown fastapi "$RELEASE_DIR"

# 3. Set the group to 'fastapi'.
sudo chgrp fastapi "$RELEASE_DIR"

echo "[2/7] Sync code into release"
# Copy files from current directory (./) to the new release directory.
# -a: Archive mode (preserves permissions, timestamps, symbolic links).
# --delete: Remove files in destination that aren't in source (ensures exact mirror).
sudo rsync -a --delete ./ "$RELEASE_DIR/"

# Ensure that ALL copied files (recursively with -R) belong to the application user.
sudo chown -R fastapi:fastapi "$RELEASE_DIR"

echo "[3/7] Create venv + install deps from uv.lock"
# Run the installation as the 'fastapi' user (security best practice).
# bash -lc: Start a 'login' shell so it loads ~/.bashrc (paths, env vars).
# Use 'uv' to sync dependencies based EXACTLY on uv.lock.
# --locked: Fail if the lockfile is out of date (prevents accidental upgrades).
sudo -u fastapi bash -lc "
  
  cd '$RELEASE_DIR'
  
  uv sync --locked
"

echo "[4/7] Flip current symlink"
# This is the "Atomic Switch". 
# ln -s: Create a symbolic link.
# -f (force): Overwrite the existing link if it exists.
# -n (no-dereference): Treat '$CURRENT' as a file, not a directory. 
# Result: Instantly points /opt/fastAPI/current -> /opt/fastAPI/releases/2025...
sudo ln -sfn "$RELEASE_DIR" "$CURRENT"

echo "[5/7] Restart via socket activation"
# This service is configured to bind to an inherited systemd socket (gunicorn --bind fd://3).
# Starting/restarting the service directly may fail (no FD 3 passed), so we:
#  1) stop the running service (if any) so it will pick up the new /opt/fastAPI/current symlink
#  2) restart the socket listener
#  3) perform a request that triggers systemd to start the service
sudo systemctl stop "$UNIT_SERVICE" || true

# Ensure the socket runtime directory exists (it is tmpfs and may be missing after reboot).
# Prefer tmpfiles.d if present; otherwise create it based on the installed socket unit config.
if [[ -f "$TMPFILES_CONF" ]]; then
  sudo systemd-tmpfiles --create "$TMPFILES_CONF"
else
  sudo install -d -m 0750 -o "$SOCKET_USER" -g "$SOCKET_GROUP" "$SOCKET_DIR"
fi

sudo systemctl restart "$UNIT_SOCKET"

echo "[6/7] Smoke test"
# Check if the app is actually alive.
# -f: Fail silently (no output) on HTTP errors (404/500).
# -s: Silent mode (no progress bar).
# -S: Show errors if -f triggers.
# Add a timeout so deployments don't hang forever if the service fails to come up.
for _ in {1..50}; do
  if sudo systemctl is-active --quiet "$UNIT_SOCKET" && [[ -S "$SOCKET_PATH" ]]; then
    break
  fi
  sleep 0.1
done

if ! curl --max-time 10 --unix-socket "$SOCKET_PATH" -fsS http://localhost/health >/dev/null; then
  echo "ERROR: smoke test failed (cannot connect to $SOCKET_PATH)."
  echo
  echo "Debug info:"
  echo "- Socket: $UNIT_SOCKET"
  echo "- Service: $UNIT_SERVICE"
  echo "- Socket path: $SOCKET_PATH"
  echo "- Socket dir: $SOCKET_DIR ($SOCKET_USER:$SOCKET_GROUP)"
  echo "- Tmpfiles: $TMPFILES_CONF"
  echo
  sudo ls -la "$SOCKET_DIR" || true
  sudo ls -la "$SOCKET_PATH" || true
  sudo systemctl status "$UNIT_SOCKET" --no-pager -l || true
  sudo systemctl status "$UNIT_SERVICE" --no-pager -l || true
  sudo journalctl -u "$UNIT_SERVICE" -n 200 --no-pager || true
  exit 1
fi

echo "[7/7] Done: $RELEASE_ID"
