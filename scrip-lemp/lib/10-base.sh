#!/bin/bash
# /opt/lemp-deploy/lib/10-base.sh

setup_base() {
    log_info "=== [10-base] Bắt đầu base setup ==="

    export DEBIAN_FRONTEND=noninteractive
    log_info "Cập nhật kho ứng dụng APT"
    apt-get update >> "$LOG_FILE" 2>&1

    # Update DNS, time sync
    install_package "chrony"
    ensure_service "chronyd"

    # Cài tool cơ bản
    install_package "vim"
    install_package "wget"
    install_package "curl"
    install_package "net-tools"
    install_package "ufw"

    log_info "Bật UFW (chừa cổng SSH)"
    ufw allow ssh >> "$LOG_FILE" 2>&1
    ufw --force enable >> "$LOG_FILE" 2>&1

    # Thiết lập hostname
    if [[ -n "${HOSTNAME_SET:-}" ]]; then
        log_info "Set hostname: $HOSTNAME_SET"
        hostnamectl set-hostname "$HOSTNAME_SET"
    fi

    # /etc/hosts cho domain
    ensure_line_in_file "${PROXY_MASTER_IP} ${DOMAIN} www.${DOMAIN}" "/etc/hosts"

    log_info "=== [10-base] Hoàn thành ==="
}