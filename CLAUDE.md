# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **NetBox deployment configuration** using Podman Quadlet (systemd-native container management). It deploys [NetBox](https://github.com/netbox-community/netbox) — an open-source IPAM and DCIM tool built on Django — via containerized services defined as systemd unit files.

This is **not** the NetBox source code repository. It contains only deployment configuration: container definitions, environment files, and application settings.

## Architecture

All services run inside a single Podman pod (`netbox.pod`) on a dedicated bridge network (`172.16.0.0/24`) with the pod at `172.16.0.172`.

### Services

| Unit File | Container | Image | Role |
|---|---|---|---|
| `netbox-netbox.container` | netbox-netbox | `netboxcommunity/netbox:latest-4.0.0` | Web app (port 8080 internal, 8000 published) |
| `netbox-worker.container` | netbox-worker | `netboxcommunity/netbox:latest-4.0.0` | RQ background worker (`manage.py rqworker`) |
| `netbox-postgres.container` | netbox-postgres | `postgres:17-alpine` | PostgreSQL database |
| `netbox-redis.container` | netbox-redis | `valkey/valkey:8.1-alpine` | Task queue (port 6380) |
| `netbox-redis-cache.container` | netbox-redis-cache | `valkey/valkey:8.1-alpine` | Cache (port 6379) |

### Startup Dependencies

```
netbox-postgres, netbox-redis, netbox-redis-cache
    └──> netbox-netbox
              └──> netbox-worker
```

### Volumes

Persistent data uses named Podman volumes defined in `*.volume` files: `netbox-postgres-data`, `netbox-media-files`, `netbox-reports-files`, `netbox-scripts-files`, `netbox-redis-data`, `netbox-redis-cache-data`.

The `netbox-configuration/` directory is bind-mounted read-only to `/etc/netbox/config` in NetBox containers.

## Common Operations

```bash
# Start/stop the entire stack
systemctl --user start netbox-pod.service
systemctl --user stop netbox-pod.service

# Check service status
systemctl --user status netbox-netbox.service
systemctl --user status netbox-worker.service

# View logs
journalctl --user -u netbox-netbox.service -f
journalctl --user -u netbox-worker.service -f

# Access the web UI
# http://localhost:8000

# Exec into the NetBox container
podman exec -it netbox-netbox /bin/bash

# Run NetBox management commands
podman exec netbox-netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py <command>
```

## Configuration Structure

### Environment Files (`env/`)

- `netbox.env` — Main NetBox settings (DB connection, Redis, email, secrets)
- `postgres.env` — PostgreSQL credentials
- `redis.env` — Task queue Redis password and port
- `redis-cache.env` — Cache Redis password

### Application Config (`netbox-configuration/`)

- `configuration.py` — Main Django settings. Reads all values from environment variables using helper functions (`_environ_get_and_map`, `_read_secret`). Supports type coercion via `_AS_BOOL`, `_AS_INT`, `_AS_LIST`. **Do not edit directly** — use environment variables or `extra.py`.
- `extra.py` — Override settings that can't be expressed as environment variables (e.g., `REMOTE_AUTH_DEFAULT_PERMISSIONS`, `PLUGINS_CONFIG`, `STORAGE_BACKEND`). Also contains `API_TOKEN_PEPPERS`.
- `plugins.py` — Plugin registration (currently all commented out).
- `logging.py` — Logging config template (currently commented out).
- `ldap/ldap_config.py` — Full LDAP/AD authentication setup, all driven by environment variables.

### Key Configuration Pattern

Settings in `configuration.py` follow this pattern — only set if the env var exists:
```python
if 'SETTING_NAME' in environ:
    SETTING_NAME = _environ_get_and_map('SETTING_NAME', None, _AS_BOOL)
```

Secrets can come from either environment variables or files at `/run/secrets/<name>`.

## File Naming Convention

Quadlet unit files follow the pattern `netbox-<component>.<type>` where type is one of: `.container`, `.pod`, `.volume`, `.network`.

## Bootstrap (Quick Start)

```bash
# Spin up a fresh NetBox stack with random credentials:
./bootstrap.sh

# Same, but output connection details as JSON (for test harnesses):
CONFIG=$(./bootstrap.sh --json)

# Restrict to localhost only:
./bootstrap.sh --bind=127.0.0.1

# Tear down everything when done:
./teardown.sh
```

**`bootstrap.sh`** will:
1. Tear down any existing NetBox stack (calls `teardown.sh`)
2. Generate random secrets (DB, Redis, Django secret key, API token pepper, admin password)
3. Resolve `{{PLACEHOLDER}}` tokens in env files → `generated/` directory (templates stay untouched)
4. Install Quadlet units to `~/.config/containers/systemd/` pointing at resolved files
5. Start the pod and wait for all health checks to pass
6. Create an `admin` superuser and print login credentials

With `--json`, progress goes to stderr and a JSON object with all connection details (url, credentials, DB/Redis passwords, etc.) is printed to stdout.

**`teardown.sh`** will:
1. Stop all NetBox systemd units (pod + network)
2. Remove containers, pod, volumes, and network
3. Remove Quadlet units from `~/.config/containers/systemd/`
4. Delete the `generated/` directory

The `generated/` directory is git-ignored and contains resolved (secret-bearing) copies of env files and `netbox-configuration/`.

## Health Checks

- **netbox-netbox**: `curl -f http://localhost:8080/login/`
- **netbox-worker**: Process check for `rqworker`
- **netbox-postgres**: `pg_isready`
- **netbox-redis/cache**: `valkey-cli ping`
