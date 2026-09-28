#!/bin/bash
# /opt/lemp-deploy/lib/40-proxy.sh

setup_proxy() {
    log_info "=== [40-proxy] Setup nginx proxy ==="
    install_package "nginx"
    ensure_service "nginx"
    open_firewall_port "80/tcp"
    open_firewall_port "443/tcp"

    mkdir -p "$SSL_DIR"
    if [[ ! -f "$SSL_DIR/nginx.crt" ]]; then
        openssl req -x509 -newkey rsa:4096 -nodes -keyout "$SSL_DIR/nginx.key" -out "$SSL_DIR/nginx.crt" -days "$SSL_DAYS" -subj "/CN=${DOMAIN}" >> "$LOG_FILE" 2>&1
    fi

    cat > /etc/nginx/conf.d/proxy.conf <<EOF
upstream backend_servers {
    server ${BACKEND_1_IP}:443 max_fails=3 fail_timeout=30s;
    server ${BACKEND_2_IP}:443 max_fails=3 fail_timeout=30s;
    keepalive 32;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     ${SSL_DIR}/nginx.crt;
    ssl_certificate_key ${SSL_DIR}/nginx.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location / {
        proxy_pass https://backend_servers;
        proxy_ssl_verify off;

        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

    nginx -t >> "$LOG_FILE" 2>&1 || die "Proxy config invalid" 40
    systemctl reload nginx
    log_info "=== [40-proxy] Hoàn thành ==="
}