# Sucket Activation (FastAPI + systemd socket activation + nginx)

Minimal FastAPI app with a `/health` endpoint, intended to run on Linux via **systemd socket activation** (Unix domain socket) and optionally be reverse-proxied by **nginx**.

Repository URL (current upstream): `https://github.com/endiesworld/socket-activation-Nginx-FastAPI.git`

## Workflow (recommended)

Keep **two separate phases**:

- **Provisioning (one-time per server):** install OS packages, create user, install systemd/nginx config.
- **Deployment (repeatable):** copy code into `/opt/fastAPI/releases/<id>` and flip `/opt/fastAPI/current`.

This repo provides:

- Provisioning script: `ops/scripts/provisioning.sh` (one-time)
- Deployment script: `ops/scripts/deploy.sh` (repeatable)

## Getting the code onto your server

### Recommended: clone with git

```bash
sudo pacman -S --needed git
git clone https://github.com/endiesworld/socket-activation-Nginx-FastAPI.git
cd socket-activation-Nginx-FastAPI
```

### Alternative: download a ZIP (no git history)

```bash
sudo pacman -S --needed curl unzip
curl -L -o project.zip https://github.com/endiesworld/socket-activation-Nginx-FastAPI/archive/refs/heads/main.zip
unzip project.zip
cd socket-activation-Nginx-FastAPI-main
```

## What you get

- FastAPI app: `app/main.py` (`GET /health`)
- Dependency management with `uv` (`pyproject.toml`, `uv.lock`)
- production wiring:
  - systemd units in `ops/systemd/` (socket-activated Gunicorn/Uvicorn)
  - tmpfiles rule in `ops/tmpfiles.d/` (creates `/run/fastAPI/`)
  - nginx vhost in `ops/nginx/` (proxies to the Unix socket)
  - simple release-based deploy script in `ops/scripts/deploy.sh`

---

## Production-ish on bare metal Arch (systemd + socket activation + nginx)

This setup:

- Listens on a Unix socket at `/run/fastAPI/fastAPI.sock`
- Starts the app **on demand** when something connects (systemd socket activation)
- Lets nginx proxy HTTP requests to that Unix socket

### Phase 0: Install required packages (run anywhere)

```bash
sudo pacman -Syu
sudo pacman -S --needed git python uv rsync curl nginx
```

```bash
sudo pacman -S --needed git python uv rsync curl nginx
```

Note: The Unix socket is group-owned by `http` so nginx can connect. If you provision without nginx, `ops/scripts/provisioning.sh` defaults the socket group to `fastapi`. Override with `--socket-group <group>`.

### Phase 1: Create a source checkout on the server (run as your normal user)

Create a git workspace, clone anywhere you want (example: `/srv/fastapi-src`):

```bash 
sudo mkdir -p /srv/fastapi-src
sudo chown "$USER":"$USER" /srv/fastapi-src
cd /srv/fastapi-src
git clone https://github.com/endiesworld/socket-activation-Nginx-FastAPI.git
cd socket-activation-Nginx-FastAPI
```

### Phase 2: Provision the host (one-time, run from the repo root)

From your source checkout on the server (example: `/srv/fastapi-src/socket-activation-Nginx-FastAPI`), run:

```bash
chmod +x ops/scripts/provisioning.sh
sudo ops/scripts/provisioning.sh --with-nginx
```

Without nginx:

```bash
sudo ops/scripts/provisioning.sh
```

Provisioning installs/creates:

- User: `fastapi`
- systemd units: `/etc/systemd/system/fastAPI-unix.{socket,service}`
- tmpfiles rule: `/etc/tmpfiles.d/fastAPI.conf` (creates `/run/fastAPI` on boot)
- env file: `/etc/fastAPI/fastAPI.env`
- nginx vhost (if enabled): `/etc/nginx/conf.d/fastAPI.conf`

### Activity diagram for the Provisioning script. 
![Activity-diagram](https://github.com/endiesworld/socket-activation-Nginx-FastAPI/tree/main/Assets/Activity-diagram-provisioning.png)

### Phase 3: Deploy the application (repeatable, run from the repo root)

From the same repo root on the server (example: `/srv/fastapi-src/socket-activation-Nginx-FastAPI`):

```bash
chmod +x ops/scripts/deploy.sh
sudo ops/scripts/deploy.sh
```

Deployment is release-based:

- Code syncs to: `/opt/fastAPI/releases/<timestamp>/`
- Symlink flips to: `/opt/fastAPI/current -> /opt/fastAPI/releases/<timestamp>/`

### Phase 4: Verify (run anywhere)

Via Unix socket (also triggers service start if needed):

```bash
sudo curl --unix-socket /run/fastAPI/fastAPI.sock -fsS http://localhost/health
```

Check status/logs:

```bash
systemctl status fastAPI-unix.socket
systemctl status fastAPI-unix.service
sudo journalctl -u fastAPI-unix.service -n 200 --no-pager
```

Via nginx (if you provisioned with `--with-nginx`):

```bash
curl -fsS http://127.0.0.1/health
```

---

## Updating (deploying a new version)

From your source checkout on the server (example: `/srv/fastapi-src/socket-activation-Nginx-FastAPI`), pull and redeploy:

```bash
git pull
sudo ops/scripts/deploy.sh
```

Each deploy creates a new directory under `/opt/fastAPI/releases/` and repoints `/opt/fastAPI/current` to it.

## Configuration notes

- App environment: put `KEY=value` lines in `/etc/fastAPI/fastAPI.env` (read by `/etc/systemd/system/fastAPI-unix.service`).
- Gunicorn settings: edit `/etc/systemd/system/fastAPI-unix.service` (for example `--workers`) then run `sudo systemctl daemon-reload && sudo systemctl restart fastAPI-unix.service`.
- Socket path/permissions: edit `/etc/systemd/system/fastAPI-unix.socket` and `/etc/tmpfiles.d/fastAPI.conf`, then restart the socket: `sudo systemctl restart fastAPI-unix.socket`.

## Rollback (manual)

There is no automated rollback script yet (`ops/scripts/rollback.sh` is empty). To roll back:

```bash
ls -1 /opt/fastAPI/releases
sudo ln -sfn /opt/fastAPI/releases/<RELEASE_ID> /opt/fastAPI/current
sudo systemctl restart fastAPI-unix.service
```

---

## Troubleshooting (Arch + systemd)

### Nginx returns 502 / cannot connect to upstream

- Confirm the socket exists: `ls -la /run/fastAPI/fastAPI.sock`
- Confirm socket unit is active: `systemctl status fastAPI-unix.socket`
- Trigger the service manually: `sudo curl --unix-socket /run/fastAPI/fastAPI.sock http://localhost/health`
- Inspect logs: `sudo journalctl -u fastAPI-unix.service -n 200 --no-pager`

### `permission denied` when nginx connects to the socket

- Confirm nginx runs as user/group `http` on Arch: `ps -o user,group,comm -C nginx`
- Confirm socket ownership/mode: `ls -la /run/fastAPI/fastAPI.sock` (should be `fastapi:http` and `srw-rw----` when using nginx)
- If you use a different nginx user/group, update:
  - `/etc/systemd/system/fastAPI-unix.socket` (`SocketGroup=...`)
  - `/etc/tmpfiles.d/fastAPI.conf` (directory group)
  - then run `sudo systemctl daemon-reload && sudo systemctl restart fastAPI-unix.socket`

### `/run/fastAPI` missing after reboot

Recreate it:

```bash
sudo systemd-tmpfiles --create /etc/tmpfiles.d/fastAPI.conf
```

### Dependency install fails during deploy

- Ensure `uv` is installed system-wide: `command -v uv`
- Re-run in the release directory to see the error:
  - `cd /opt/fastAPI/current && sudo -u fastapi uv sync --locked`

---

## Layout

- `app/` – FastAPI application code
- `tests/` – pytest tests
- `ops/systemd/` – systemd unit files (socket + service)
- `ops/nginx/` – nginx reverse proxy config (Unix socket upstream)
- `ops/tmpfiles.d/` – runtime directory creation for `/run/fastAPI`
- `ops/scripts/` – `provisioning.sh` (one-time) and `deploy.sh` (repeatable)
