#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
GENERATED_DIR="$REPO_DIR/generated"
QUADLET_DIR="$HOME/.config/containers/systemd"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
KEEP_DATA=false
for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=true ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--keep-data]"
            echo ""
            echo "Tear down the NetBox stack."
            echo ""
            echo "Options:"
            echo "  --keep-data  Keep volumes intact (DB, Valkey, media) for faster re-bootstrap"
            echo "  -h|--help    Show this help"
            exit 0
            ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

BOLD='\033[1m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

info()  { printf "${BOLD}==> %s${RESET}\n" "$*"; }
ok()    { printf "${GREEN}==> %s${RESET}\n" "$*"; }
die()   { printf "${RED}ERROR: %s${RESET}\n" "$*" >&2; exit 1; }

info "Tearing down NetBox stack..."

# Stop systemd units
systemctl --user stop netbox-pod.service 2>/dev/null || true
systemctl --user stop netbox-network.service 2>/dev/null || true
systemctl --user reset-failed 'netbox-*' 2>/dev/null || true

# Remove containers that may linger
for c in netbox-netbox netbox-worker netbox-postgres netbox-valkey netbox-valkey-cache; do
    podman rm -f "$c" 2>/dev/null || true
done
podman pod rm -f netbox 2>/dev/null || true

# Remove named volumes (unless --keep-data)
if [ "$KEEP_DATA" = false ]; then
    for v in netbox-postgres-data netbox-media-files netbox-report-files netbox-script-files \
             netbox-valkey-data netbox-valkey-cache-data netbox-configuration; do
        podman volume rm -f "$v" 2>/dev/null || true
    done
else
    info "Keeping volumes intact (--keep-data)."
fi

# Remove network
podman network rm -f netbox 2>/dev/null || true

# Clean Quadlet units
rm -f "$QUADLET_DIR"/netbox-*.container \
      "$QUADLET_DIR"/netbox-*.volume \
      "$QUADLET_DIR"/netbox.pod \
      "$QUADLET_DIR"/netbox.network 2>/dev/null || true

systemctl --user daemon-reload

# Remove generated files (unless --keep-data, which preserves secrets for reuse)
if [ "$KEEP_DATA" = false ]; then
    rm -rf "$GENERATED_DIR"
else
    info "Keeping generated/ intact (--keep-data)."
fi

ok "Teardown complete."
