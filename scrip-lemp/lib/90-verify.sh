#!/bin/bash
# /opt/lemp-deploy/lib/90-verify.sh

verify_stack() {
    local role="$1"
    log_info "=== [90-verify] Verify role: $role ==="
    case "$role" in
        backend-*) verify_backend ;;
        db-master) verify_db_master ;;
        db-slave) verify_db_slave ;;
        proxy-*) verify_proxy "$role" ;;
    esac
}

verify_backend() {
    systemctl is-active --quiet nginx || log_error "nginx KHÔNG chạy"
    systemctl is-active --quiet "php${PHP_VERSION}-fpm" || log_error "php-fpm KHÔNG chạy"
    if [[ -S "/run/php/php${PHP_VERSION}-fpm.sock" ]]; then log_info "Socket OK"; else log_error "Socket KHÔNG tồn tại"; fi
    curl -sk "https://localhost/" -o /dev/null -w "HTTP %{http_code}\n" | tee -a "$LOG_FILE"
}

verify_db_master() {
    systemctl is-active --quiet mariadb || log_error "mariadb KHÔNG chạy"
    local log_bin=$(mariadb -u root -p"${DB_ROOT_PASSWORD}" -sN -e "SHOW VARIABLES LIKE 'log_bin';" | awk '{print $2}')
    if [[ "$log_bin" == "ON" ]]; then log_info "Binlog ON"; else log_error "Binlog OFF"; fi
}

verify_db_slave() {
    local io_running=$(mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_IO_Running:" | awk '{print $2}')
    local sql_running=$(mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep "Slave_SQL_Running:" | awk '{print $2}')
    if [[ "$io_running" == "Yes" && "$sql_running" == "Yes" ]]; then
        log_info "Replication chạy OK"
    else
        log_error "Replication LỖI"
    fi
}

verify_proxy() {
    systemctl is-active --quiet nginx || log_error "nginx KHÔNG chạy"
    systemctl is-active --quiet keepalived || log_error "keepalived KHÔNG chạy"
    if [[ "$1" == "proxy-master" ]]; then
        ip a | grep -q "$VIP" && log_info "VIP $VIP gắn OK" || log_error "VIP KHÔNG gắn"
    fi
}