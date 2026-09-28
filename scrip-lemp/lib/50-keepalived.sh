#!/bin/bash
# /opt/lemp-deploy/lib/50-keepalived.sh

setup_keepalived() {
    local role="$1"
    log_info "=== [50-keepalived] Setup keepalived, role: $role ==="

    install_package "keepalived"

    cat > /etc/keepalived/check_nginx.sh <<'EOF'
#!/bin/bash
if systemctl is-active --quiet nginx; then exit 0; fi
exit 1
EOF
    chmod +x /etc/keepalived/check_nginx.sh

    local state priority
    case "$role" in
        proxy-master) state="MASTER"; priority=101 ;;
        proxy-backup) state="BACKUP"; priority=90 ;;
        *) die "Role không hợp lệ: $role" 50 ;;
    esac

    cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script check_nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight -20
}

vrrp_instance VI_LEMP {
    state ${state}
    interface ${KEEPALIVED_INTERFACE}
    virtual_router_id ${KEEPALIVED_VRID}
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}
    }
    track_script {
        check_nginx
    }
}
EOF

    ensure_service "keepalived"
    systemctl restart keepalived
    sleep 3
    log_info "=== [50-keepalived] Hoàn thành ==="
}