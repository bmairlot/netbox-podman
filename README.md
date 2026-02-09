# NetBox Podman Quadlet

A rootless [Podman](https://podman.io/) deployment of [NetBox](https://github.com/netbox-community/netbox) using **Quadlet** (systemd-native container management). One command spins up a fully working NetBox instance with random credentials -- ideal for local development, integration testing, and CI pipelines.

This project is designed to work as a **test fixture** for the [`ancalagon/netbox`](https://packagist.org/packages/ancalagon/netbox) PHP library, but is equally useful as a standalone NetBox deployment on any Linux system with Podman.

## Prerequisites

- **Podman** (rootless mode) with Quadlet support (Podman 4.4+)
- **systemd** user session (`systemctl --user` must work)
- **openssl** (for secret generation)

## Quick Start

```bash
# Spin up a fresh NetBox instance:
./bootstrap.sh

# Machine-readable output for test harnesses:
CONFIG=$(./bootstrap.sh --json)

# Restrict to localhost only:
./bootstrap.sh --bind=127.0.0.1

# Tear down everything when done:
./teardown.sh

# Tear down but keep data (DB, Valkey, media) for faster re-bootstrap:
./teardown.sh --keep-data

# Re-bootstrap reusing existing data volumes:
./bootstrap.sh --keep-data
```

The first run will pull container images and run Django migrations, which may take a few minutes. Subsequent runs are faster -- especially with `--keep-data`, which preserves volumes so migrations are skipped entirely.

### bootstrap.sh

| Option | Description |
|---|---|
| `--json` | Output connection details as JSON to stdout (progress goes to stderr) |
| `--bind=ADDRESS` | Bind address for published ports (default: `0.0.0.0`) |
| `--keep-data` | Preserve existing volumes (DB, Valkey, media) for faster startup |
| `-h`, `--help` | Show usage help |

The script will:
1. Tear down any existing NetBox stack (calls `teardown.sh`)
2. Generate random secrets (DB, Valkey, Django secret key, API token pepper, admin password)
3. Resolve `{{PLACEHOLDER}}` tokens in template files into a `generated/` directory
4. Install Quadlet units to `~/.config/containers/systemd/`
5. Start the pod and wait for all health checks to pass
6. Create an `admin` superuser and print login credentials

### teardown.sh

| Option | Description |
|---|---|
| `--keep-data` | Keep volumes intact (DB, Valkey, media) for faster re-bootstrap |
| `-h`, `--help` | Show usage help |

By default, stops all services and removes containers, pods, volumes, the Podman network, installed Quadlet units, and the `generated/` directory. With `--keep-data`, volumes are preserved so the next `./bootstrap.sh` skips migrations and starts much faster.

### JSON Output

When using `--json`, the output contains everything a test harness needs:

```json
{
  "url": "http://0.0.0.0:8000",
  "username": "admin",
  "password": "...",
  "api_url": "http://0.0.0.0:8000/api",
  "db_host": "netbox-postgres",
  "db_port": 5432,
  "db_name": "netbox",
  "db_user": "netbox",
  "db_password": "...",
  "valkey_host": "netbox-valkey",
  "valkey_port": 6380,
  "valkey_password": "...",
  "valkey_cache_host": "netbox-valkey-cache",
  "valkey_cache_port": 6379,
  "valkey_cache_password": "...",
  "secret_key": "...",
  "api_token_pepper": "..."
}
```

## Usage with Composer (PHP Integration Testing)

This repository can be added as a Composer dev dependency to provide a disposable NetBox instance for PHPUnit tests:

```bash
composer require --dev ancalagon/netbox-podman
```

Composer will symlink `bootstrap.sh` and `teardown.sh` into `vendor/bin/`, so they are available on your `$PATH` when using Composer scripts.

### Example: PHPUnit bootstrap file

Create a `tests/bootstrap.php` that starts NetBox before the test suite runs:

```php
<?php
// tests/bootstrap.php

$config = shell_exec('vendor/bin/bootstrap.sh --json --bind=127.0.0.1');
$netbox = json_decode($config, true);

// Expose connection details as environment variables for your tests
putenv("NETBOX_URL={$netbox['url']}");
putenv("NETBOX_API_URL={$netbox['api_url']}");
putenv("NETBOX_USERNAME={$netbox['username']}");
putenv("NETBOX_PASSWORD={$netbox['password']}");

// Optional: register a shutdown function to tear down when tests finish
register_shutdown_function(function () {
    shell_exec('vendor/bin/teardown.sh');
});
```

Then point your `phpunit.xml` at it:

```xml
<phpunit bootstrap="tests/bootstrap.php">
    <!-- ... -->
</phpunit>
```

### Example: CI script

If you prefer to manage the lifecycle outside of PHP (e.g. in a Makefile or CI job):

```bash
# Start NetBox and capture connection details
CONFIG=$(vendor/bin/bootstrap.sh --json --bind=127.0.0.1)
export NETBOX_URL=$(echo "$CONFIG" | jq -r .url)
export NETBOX_API_URL=$(echo "$CONFIG" | jq -r .api_url)
export NETBOX_USERNAME=$(echo "$CONFIG" | jq -r .username)
export NETBOX_PASSWORD=$(echo "$CONFIG" | jq -r .password)

# Run your test suite
vendor/bin/phpunit

# Tear down
vendor/bin/teardown.sh
```

For faster iteration during development, use `--keep-data` so that subsequent runs skip database migrations:

```bash
vendor/bin/bootstrap.sh --json --keep-data
```

## Architecture

All services run inside a single Podman pod on a dedicated bridge network (`172.16.0.0/24`).

```
                    +----- netbox (pod) -----+
                    |                        |
  :8000 -----> netbox-netbox (Django app)    |
                    |    |                   |
                    |    +-> netbox-worker   |
                    |        (rqworker)      |
                    |                        |
               netbox-postgres (PostgreSQL)  |
               netbox-valkey (Valkey, :6380)  |
               netbox-valkey-cache (Valkey)   |
                    +------------------------+
```

### Services

| Unit File | Image | Role |
|---|---|---|
| `netbox-netbox.container` | `netboxcommunity/netbox:latest-4.0.0` | Web app (port 8080 internal, 8000 published) |
| `netbox-worker.container` | `netboxcommunity/netbox:latest-4.0.0` | RQ background worker |
| `netbox-postgres.container` | `postgres:17-alpine` | PostgreSQL database |
| `netbox-valkey.container` | `valkey/valkey:8.1-alpine` | Task queue (port 6380) |
| `netbox-valkey-cache.container` | `valkey/valkey:8.1-alpine` | Cache (port 6379) |

### Startup Dependencies

```
netbox-postgres, netbox-valkey, netbox-valkey-cache
    +---> netbox-netbox
              +---> netbox-worker
```

### Volumes

Persistent data uses named Podman volumes: `netbox-postgres-data`, `netbox-media-files`, `netbox-report-files`, `netbox-script-files`, `netbox-valkey-data`, `netbox-valkey-cache-data`.

## Configuration

### Template Files

Environment files in `env/` and `netbox-configuration/extra.py` use `{{PLACEHOLDER}}` tokens that `bootstrap.sh` resolves with random values into the `generated/` directory (git-ignored). Templates are never modified.

| File | Placeholders |
|---|---|
| `env/netbox.env` | `{{DB_PASSWORD}}`, `{{REDIS_PASSWORD}}`, `{{REDIS_CACHE_PASSWORD}}`, `{{SECRET_KEY}}` |
| `env/postgres.env` | `{{DB_PASSWORD}}` |
| `env/valkey.env` | `{{REDIS_PASSWORD}}` |
| `env/valkey-cache.env` | `{{REDIS_CACHE_PASSWORD}}` |
| `netbox-configuration/extra.py` | `{{API_TOKEN_PEPPER}}` |
| `netbox.pod` | `{{BIND_ADDRESS}}` |

### Application Config

- `netbox-configuration/configuration.py` -- Main Django settings, driven entirely by environment variables. Do not edit directly.
- `netbox-configuration/extra.py` -- Override settings that can't be expressed as env vars (e.g. `API_TOKEN_PEPPERS`, `PLUGINS_CONFIG`).

## Security Considerations

By default, `bootstrap.sh` binds to `0.0.0.0`, which exposes NetBox on **all network interfaces**. For local-only access, use:

```bash
./bootstrap.sh --bind=127.0.0.1
```

For any deployment beyond local development, you should place a **reverse proxy** in front of NetBox to handle TLS termination. For example, with [Caddy](https://caddyserver.com/):

```
netbox.example.com {
    reverse_proxy localhost:8000
}
```

Or with [Nginx](https://nginx.org/):

```nginx
server {
    listen 443 ssl;
    server_name netbox.example.com;
    ssl_certificate     /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

When using a reverse proxy, always bind to `127.0.0.1` so NetBox is not directly reachable from the network.

## Roadmap

### Helm Chart for OpenShift / Kubernetes

The long-term goal of this project is to produce a **Helm chart** that deploys NetBox on OpenShift and Kubernetes clusters. The Podman Quadlet setup serves as the reference architecture for:

- Service dependency graph and startup ordering
- Health check definitions (mapped to `readinessProbe` / `livenessProbe`)
- Environment variable surface and secrets management (mapped to ConfigMaps / Secrets)
- Volume requirements (mapped to PersistentVolumeClaims)
- Network topology (mapped to Services and Routes/Ingress)

Planned Helm chart features:
- Separate Deployments for the web app and worker, StatefulSets for PostgreSQL and Valkey
- OpenShift Routes with TLS passthrough
- Configurable StorageClass for PVCs
- Horizontal Pod Autoscaler for the web app tier
- Optional external PostgreSQL / Valkey for production use

## License

[MIT](LICENSE)
