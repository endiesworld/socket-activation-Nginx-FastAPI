#!/usr/bin/env bash

set -euo pipefail


APP_NAME="fastAPI"
BASE="/opt/fastAPI"

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

echo "[5/7] Restart (or trigger) socket/service"
# Restart the main application logic.
# we use Type=notify, this command BLOCKS until the app is healthy.
# If the app crashes, this command fails, and the script exits here (thanks to set -e).
sudo systemctl restart "$UNIT_SERVICE" 

# Restart the socket (if you are using socket activation) to ensure fresh connections. This is sometimes frawned at.
# sudo systemctl restart "$UNIT_SOCKET"

echo "[6/7] Smoke test"
# Check if the app is actually alive.
# -f: Fail silently (no output) on HTTP errors (404/500).
# -s: Silent mode (no progress bar).
# -S: Show errors if -f triggers.
curl --unix-socket /run/fastAPI/fastAPI.sock -fsS http://localhost/health >/dev/null

echo "[7/7] Done: $RELEASE_ID"
