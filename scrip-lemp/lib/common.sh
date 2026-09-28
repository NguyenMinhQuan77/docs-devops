#!/bin/bash
# /opt/lemp-deploy/lib/common.sh

# ─── Logging ───────────────────────────────────────────────────
log_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $1" | tee -a "$LOG_FILE"; }
log_warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $1" | tee -a "$LOG_FILE" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE" >&2; }

die() {
    log_error "$1"
    exit "${2:-1}"
}

# ─── Validation ────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Script phải chạy với quyền root (sudo)" 1
    fi
}

check_os() {
    if ! grep -iq "ubuntu" /etc/os-release; then
        die "Script chỉ hỗ trợ Ubuntu" 2
    fi
    log_info "OS check OK: Ubuntu"
}

check_internet() {
    if ! curl -sf --max-time 5 https://www.google.com > /dev/null; then
        die "Không có kết nối internet" 3
    fi
    log_info "Internet OK"
}

# ─── Idempotent helpers ────────────────────────────────────────
install_package() {
    local pkg="$1"
    export DEBIAN_FRONTEND=noninteractive
    if dpkg -l | grep -qw "^ii  $pkg"; then
        log_info "Package '$pkg' đã cài, skip"
    else
        log_info "Cài package: $pkg"
        apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 \
            || die "Cài package $pkg thất bại" 10
    fi
}

ensure_service() {
    local svc="$1"
    log_info "Ensure service: $svc"
    systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl start "$svc" >> "$LOG_FILE" 2>&1 \
        || die "Start service $svc thất bại" 11
}

open_firewall_port() {
    local port="$1"
    log_info "Mở firewall port: $port"
    ufw allow "$port" >> "$LOG_FILE" 2>&1 \
        || die "Mở firewall $port thất bại" 12
}

ensure_line_in_file() {
    local line="$1"
    local file="$2"
    if grep -qF "$line" "$file" 2>/dev/null; then
        log_info "Line đã có trong $file, skip"
    else
        log_info "Add line vào $file: $line"
        echo "$line" >> "$file"
    fi
}

cleanup_on_exit() {
    local code=$?
    if [[ $code -eq 0 ]]; then
        log_info "=== Script hoàn thành thành công ==="
    else
        log_error "=== Script fail với exit code $code ==="
        log_error "Xem log đầy đủ tại: $LOG_FILE"
    fi
}