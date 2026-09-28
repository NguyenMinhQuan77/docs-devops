#!/bin/bash
# /opt/lemp-deploy/deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f "${SCRIPT_DIR}/config.conf" ]]; then echo "ERROR: config.conf missing" >&2; exit 1; fi
source "${SCRIP"
touch "$LOG_FILE"
source "${SCRIPT_DIR}/lib/common.sh"
trap cleanup_on_exit EXIT

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <role> (backend-1, db-master, proxy-master, etc.)"
    exit 1
fiT_DIR}/config.conf"

mkdir -p "$LOG_DIR

ROLE="$1"
check_root
check_os
check_internet

log_info "================================================"
log_info "Deploy LEMP HA Stack (Ubuntu)"
log_info "Role: $ROLE"
log_info "================================================"

source "${SCRIPT_DIR}/lib/10-base.sh"
source "${SCRIPT_DIR}/lib/20-backend.sh"
source "${SCRIPT_DIR}/lib/30-db.sh"
source "${SCRIPT_DIR}/lib/40-proxy.sh"
source "${SCRIPT_DIR}/lib/50-keepalived.sh"
source "${SCRIPT_DIR}/lib/90-verify.sh"

case "$ROLE" in
    backend-1|backend-2)
        HOSTNAME_SET="${ROLE}.local"
        setup_base
        setup_backend
        verify_stack "$ROLE"
        ;;
    db-master|db-slave)
        HOSTNAME_SET="${ROLE}.local"
        setup_base
        setup_db "$ROLE"
        verify_stack "$ROLE"
        ;;
    proxy-master|proxy-backup)
        HOSTNAME_SET="${ROLE}.local"
        setup_base
        setup_proxy
        setup_keepalived "$ROLE"
        verify_stack "$ROLE"
        ;;
    *)
        die "Role không hợp lệ: $ROLE"
        ;;
esac

log_info "✅ Deploy '$ROLE' thành công."