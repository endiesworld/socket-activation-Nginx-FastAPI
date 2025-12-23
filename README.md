# Socket Activation (FastAPI + systemd socket activation + nginx)

Minimal FastAPI app with a `/health` endpoint, intended to run on Linux via **systemd socket activation** (Unix domain socket) and optionally be reverse-proxied by **nginx**.

Repository URL (current upstream): `https://github.com/endiesworld/socket-activation-Nginx-FastAPI.git`

## Workflow (recommended)

Keep **two separate phases**:

- **Provisioning (one-time per server):** install OS packages, create user, install systemd/nginx config.
- **Deployment (repeatable):** copy code into `/opt/fastAPI/releases/<id>` and flip `/opt/fastAPI/current`.

This repo provides:

- Provisioning script: `ops/scripts/provisioning.sh` (one-time)
- Deployment script: `ops/scripts/deploy.sh` (repeatable)

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
sudo bash ops/scripts/provisioning.sh --with-nginx
```

Note: run scripts via `bash` (no `chmod +x` needed). Changing execute bits on tracked files can make `git pull` fail with “local changes would be overwritten”.

Without nginx:

```bash
sudo bash ops/scripts/provisioning.sh
```

Provisioning installs/creates:

- User: `fastapi`
- systemd units: `/etc/systemd/system/fastAPI-unix.{socket,service}`
- tmpfiles rule: `/etc/tmpfiles.d/fastAPI.conf` (creates `/run/fastAPI` on boot)
- env file: `/etc/fastAPI/fastAPI.env`
- nginx vhost (if enabled): installed into nginx’s included snippets dir (commonly `/etc/nginx/http.d/00-fastAPI.conf` on Arch)
- venv base: `/var/lib/fastAPI` (per-release venvs under `/var/lib/fastAPI/venvs/`)

### Activity diagram for the Provisioning script. 
![Activity-diagram](#) ![./Assets/Activity-diagram-provisioning.png](https://github.com/endiesworld/socket-activation-Nginx-FastAPI/blob/main/Assets/Activity-diagram-provisioning.png)

### Phase 3: Deploy the application (repeatable, run from the repo root)

From the same repo root on the server (example: `/srv/fastapi-src/socket-activation-Nginx-FastAPI`):

```bash
sudo bash ops/scripts/deploy.sh
```

Deployment is release-based:

- Code syncs to: `/opt/fastAPI/releases/<timestamp>/`
- Symlink flips to: `/opt/fastAPI/current -> /opt/fastAPI/releases/<timestamp>/`
- Venv syncs to: `/var/lib/fastAPI/venvs/<timestamp>/`
- Venv symlink flips to: `/var/lib/fastAPI/current-venv -> /var/lib/fastAPI/venvs/<timestamp>/`
- Deploy restarts the socket and triggers startup via a local `/health` request (socket activation).

### Phase 4: Verify (run anywhere)

Via Unix socket (also triggers service start if needed):

```bash
sudo curl --unix-socket /run/fastAPI/fastAPI.sock -fsS http://localhost/health
```

If you want to run `curl` without `sudo`, add your user to the socket group (default: `http`) and re-login:

```bash
sudo usermod -aG http "$USER"
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

From another machine (public access), use your server IP or DNS name:

- `http://<server-ip>/health`
- `http://your-domain.example/health`

If it works locally but not remotely, ensure port `80/tcp` is reachable (cloud security group / firewall / router).

If `/health` works over the Unix socket but nginx returns `404`, verify nginx is loading the intended vhost and reload:

```bash
sudo grep -nE 'include\\s+(/etc/nginx/)?(http\\.d|conf\\.d)/\\*\\.conf' /etc/nginx/nginx.conf || true
sudo nginx -T | grep -nE "/etc/nginx/(http\\.d|conf\\.d)/00-fastAPI\\.conf|fastapi_upstream|/run/fastAPI/fastAPI\\.sock"
sudo nginx -t
sudo systemctl reload nginx
```

---

## Updating (deploying a new version)

From your source checkout on the server (example: `/srv/fastapi-src/socket-activation-Nginx-FastAPI`), pull and redeploy:

```bash
git pull --rebase --autostash
sudo bash ops/scripts/deploy.sh
```

If you pulled changes that touch `ops/systemd/` or `ops/nginx/`, re-run provisioning (safe/idempotent) to install the updated unit/config files:

```bash
sudo bash ops/scripts/provisioning.sh --with-nginx
```

If `git pull` aborts with “Your local changes would be overwritten”, you have modified tracked files (for example, `ops/scripts/deploy.sh`). Either:

- Keep your changes: `git stash push -m "local changes" && git pull --rebase && git stash pop`
- Discard your changes: `git restore --source=HEAD --worktree --staged ops/scripts/deploy.sh` (or `git reset --hard HEAD`) then `git pull`

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

## Troubleshooting

### `curl --unix-socket ...` fails with “Could not connect to server”

Run these on the server:

```bash
sudo systemctl status fastAPI-unix.socket --no-pager -l
sudo systemctl status fastAPI-unix.service --no-pager -l
sudo journalctl -u fastAPI-unix.service -n 200 --no-pager
```

Common cause: the runtime dir under `/run` is missing after reboot (it’s a tmpfs). Fix:

```bash
sudo systemd-tmpfiles --create /etc/tmpfiles.d/fastAPI.conf
sudo systemctl restart fastAPI-unix.socket
```

If `/etc/tmpfiles.d/fastAPI.conf` does not exist, re-run provisioning:

```bash
cd /srv/fastapi-src/socket-activation-Nginx-FastAPI
sudo bash ops/scripts/provisioning.sh --with-nginx
```

If the units show `service-start-limit-hit`, clear the start-limit and retry:

```bash
sudo systemctl reset-failed fastAPI-unix.socket fastAPI-unix.service
sudo systemctl restart fastAPI-unix.socket
```

If the service shows `status=203/EXEC` and “Unable to locate executable .../bin/python: No such file or directory”, re-run provisioning to install the latest unit file; this repo uses `ProtectHome=read-only` so the service can still access the Python interpreter used by the venv.

If the service shows `OSError: [Errno 9] Bad file descriptor`, it usually means Gunicorn tried to consume the inherited socket fd twice (common when both `--bind fd://3` and `LISTEN_FDS` activation are enabled at the same time). Re-run provisioning to install the current unit file, which binds explicitly to `fd://3` and disables `LISTEN_FDS` via `UnsetEnvironment=...`. Also note the service is configured with `RefuseManualStart=yes`—start the socket (`fastAPI-unix.socket`) and connect to it.

## Layout

- `app/` – FastAPI application code
- `tests/` – pytest tests
- `ops/systemd/` – systemd unit files (socket + service)
- `ops/nginx/` – nginx reverse proxy config (Unix socket upstream)
- `ops/tmpfiles.d/` – runtime directory creation for `/run/fastAPI`
- `ops/scripts/` – `provisioning.sh` (one-time) and `deploy.sh` (repeatable)
