#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="$REPO_DIR/generated"
QUADLET_DIR="$HOME/.config/containers/systemd"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
JSON_OUTPUT=false
BIND_ADDRESS="0.0.0.0"
KEEP_DATA=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_OUTPUT=true ;;
        --bind=*) BIND_ADDRESS="${arg#--bind=}" ;;
        --keep-data) KEEP_DATA=true ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--json] [--bind=ADDRESS] [--keep-data]"
            echo ""
            echo "Bootstrap a fresh NetBox instance for testing."
            echo ""
            echo "Options:"
            echo "  --json           Output connection details as JSON to stdout"
            echo "                   (progress is sent to stderr)"
            echo "  --bind=ADDRESS   Bind address for published ports (default: 0.0.0.0)"
            echo "                   Use 127.0.0.1 to restrict to localhost only"
            echo "  --keep-data      Preserve volumes (DB, Redis, media) from a previous run"
            echo "                   for faster startup (skips migrations)"
            echo "  -h|--help        Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Output helpers — in JSON mode, progress goes to stderr
# ---------------------------------------------------------------------------
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

if [ "$JSON_OUTPUT" = true ]; then
    info()  { printf "${BOLD}==> %s${RESET}\n" "$*" >&2; }
    ok()    { printf "${GREEN}==> %s${RESET}\n" "$*" >&2; }
    warn()  { printf "${YELLOW}==> %s${RESET}\n" "$*" >&2; }
else
    info()  { printf "${BOLD}==> %s${RESET}\n" "$*"; }
    ok()    { printf "${GREEN}==> %s${RESET}\n" "$*"; }
    warn()  { printf "${YELLOW}==> %s${RESET}\n" "$*"; }
fi
die()   { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Teardown
# ---------------------------------------------------------------------------
teardown_args=()
if [ "$KEEP_DATA" = true ]; then
    teardown_args+=(--keep-data)
fi
if [ "$JSON_OUTPUT" = true ]; then
    "$REPO_DIR/teardown.sh" "${teardown_args[@]+"${teardown_args[@]}"}" >&2
else
    "$REPO_DIR/teardown.sh" "${teardown_args[@]+"${teardown_args[@]}"}"
fi

# ---------------------------------------------------------------------------
# 2. Generate random secrets
# ---------------------------------------------------------------------------
info "Generating random secrets..."

DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
REDIS_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
REDIS_CACHE_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
SECRET_KEY="$(openssl rand -base64 72 | tr -d '/+=' | head -c 60)"
API_TOKEN_PEPPER="$(openssl rand -base64 48 | tr -d '/+=' | head -c 50)"
ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)"

ok "Secrets generated."

# ---------------------------------------------------------------------------
# 3. Resolve env files (templates → generated/)
# ---------------------------------------------------------------------------
info "Resolving template files into generated/..."

rm -rf "$GENERATED_DIR"
mkdir -p "$GENERATED_DIR/env" "$GENERATED_DIR/netbox-configuration"

resolve() {
    sed \
        -e "s|{{DB_PASSWORD}}|${DB_PASSWORD}|g" \
        -e "s|{{REDIS_PASSWORD}}|${REDIS_PASSWORD}|g" \
        -e "s|{{REDIS_CACHE_PASSWORD}}|${REDIS_CACHE_PASSWORD}|g" \
        -e "s|{{SECRET_KEY}}|${SECRET_KEY}|g" \
        -e "s|{{API_TOKEN_PEPPER}}|${API_TOKEN_PEPPER}|g" \
        "$1" > "$2"
}

resolve "$REPO_DIR/env/netbox.env"       "$GENERATED_DIR/env/netbox.env"
resolve "$REPO_DIR/env/postgres.env"     "$GENERATED_DIR/env/postgres.env"
resolve "$REPO_DIR/env/redis.env"        "$GENERATED_DIR/env/redis.env"
resolve "$REPO_DIR/env/redis-cache.env"  "$GENERATED_DIR/env/redis-cache.env"

# Copy the full netbox-configuration directory, then resolve extra.py
cp -a "$REPO_DIR/netbox-configuration/." "$GENERATED_DIR/netbox-configuration/"
resolve "$REPO_DIR/netbox-configuration/extra.py" "$GENERATED_DIR/netbox-configuration/extra.py"

ok "Resolved files written to $GENERATED_DIR"

# ---------------------------------------------------------------------------
# 4. Install Quadlet units
# ---------------------------------------------------------------------------
info "Installing Quadlet units to $QUADLET_DIR..."

mkdir -p "$QUADLET_DIR"

# Copy volume and network files as-is
for f in "$REPO_DIR"/*.volume "$REPO_DIR"/netbox.network; do
    cp "$f" "$QUADLET_DIR/"
done

# Resolve bind address in the pod file
sed -e "s|{{BIND_ADDRESS}}|${BIND_ADDRESS}|g" \
    "$REPO_DIR/netbox.pod" > "$QUADLET_DIR/netbox.pod"

# Copy container files, patching EnvironmentFile and bind-mount paths to point
# at the generated directory with absolute paths
for f in "$REPO_DIR"/*.container; do
    basename="$(basename "$f")"
    sed \
        -e "s|EnvironmentFile=env/|EnvironmentFile=${GENERATED_DIR}/env/|g" \
        -e "s|Volume=./netbox-configuration:|Volume=${GENERATED_DIR}/netbox-configuration:|g" \
        "$f" > "$QUADLET_DIR/$basename"
done

ok "Quadlet units installed."

# ---------------------------------------------------------------------------
# 5. Reload & start
# ---------------------------------------------------------------------------
info "Starting NetBox stack..."

systemctl --user daemon-reload

# The network must exist before the pod can reference it.
# Quadlet generates netbox-network.service but the pod doesn't auto-depend on it.
systemctl --user start netbox-network.service
systemctl --user start netbox-pod.service

ok "Pod start requested."

# ---------------------------------------------------------------------------
# 6. Wait for health
# ---------------------------------------------------------------------------
info "Waiting for services to become healthy (this may take a few minutes on first run)..."

wait_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    local elapsed=0
    local interval=5

    while [ "$elapsed" -lt "$timeout" ]; do
        status="$(podman healthcheck run "$container" 2>&1 && echo healthy || true)"
        if echo "$status" | grep -q healthy; then
            ok "$container is healthy."
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    die "$container did not become healthy within ${timeout}s"
}

# Infrastructure services first (shorter timeout)
wait_healthy netbox-postgres 120
wait_healthy netbox-redis 60
wait_healthy netbox-redis-cache 60

# NetBox app — first run includes migrations, so allow up to 5 minutes
wait_healthy netbox-netbox 300

ok "All services healthy."

# ---------------------------------------------------------------------------
# 7. Create admin superuser
# ---------------------------------------------------------------------------
info "Creating admin superuser (waiting for migrations to finish)..."

admin_timeout=180
admin_elapsed=0
admin_created=false

create_admin() {
    podman exec netbox-netbox /opt/netbox/venv/bin/python /opt/netbox/netbox/manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()
if not User.objects.filter(username='admin').exists():
    User.objects.create_superuser('admin', 'admin@example.com', '${ADMIN_PASSWORD}')
    print('Superuser created.')
else:
    u = User.objects.get(username='admin')
    u.set_password('${ADMIN_PASSWORD}')
    u.save()
    print('Superuser password reset.')
" 2>/dev/null
}

while [ "$admin_elapsed" -lt "$admin_timeout" ]; do
    if create_admin >&2; then
        admin_created=true
        break
    fi
    sleep 5
    admin_elapsed=$((admin_elapsed + 5))
done

if [ "$admin_created" = false ]; then
    die "Could not create admin user within ${admin_timeout}s — migrations may not have completed."
fi

ok "Admin user ready."

# ---------------------------------------------------------------------------
# 8. Output
# ---------------------------------------------------------------------------
if [ "$JSON_OUTPUT" = true ]; then
    cat <<EOF
{
  "url": "http://${BIND_ADDRESS}:8000",
  "username": "admin",
  "password": "${ADMIN_PASSWORD}",
  "api_url": "http://${BIND_ADDRESS}:8000/api",
  "db_host": "netbox-postgres",
  "db_port": 5432,
  "db_name": "netbox",
  "db_user": "netbox",
  "db_password": "${DB_PASSWORD}",
  "redis_host": "netbox-redis",
  "redis_port": 6380,
  "redis_password": "${REDIS_PASSWORD}",
  "redis_cache_host": "netbox-redis-cache",
  "redis_cache_port": 6379,
  "redis_cache_password": "${REDIS_CACHE_PASSWORD}",
  "secret_key": "${SECRET_KEY}",
  "api_token_pepper": "${API_TOKEN_PEPPER}"
}
EOF
else
    printf "\n"
    printf "${GREEN}${BOLD}========================================${RESET}\n"
    printf "${GREEN}${BOLD}  NetBox is ready!${RESET}\n"
    printf "${GREEN}${BOLD}========================================${RESET}\n"
    printf "\n"
    printf "  URL:      ${BOLD}http://${BIND_ADDRESS}:8000${RESET}\n"
    printf "  Username: ${BOLD}admin${RESET}\n"
    printf "  Password: ${BOLD}%s${RESET}\n" "$ADMIN_PASSWORD"
    printf "\n"
fi
