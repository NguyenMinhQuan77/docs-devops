#!/bin/bash
# /opt/lemp-deploy/lib/20-backend.sh

install_nginx_backend() {
    log_info "Cài nginx"
    install_package "nginx"
    ensure_service "nginx"
    open_firewall_port "80/tcp"
    open_firewall_port "443/tcp"
}

install_php_fpm() {
    log_info "Cài PHP-FPM ${PHP_VERSION}"

    install_package "php${PHP_VERSION}-fpm"
    install_package "php${PHP_VERSION}-cli"
    install_package "php${PHP_VERSION}-mysql"
    install_package "php${PHP_VERSION}-gd"
    install_package "php${PHP_VERSION}-mbstring"
    install_package "php${PHP_VERSION}-xml"
    install_package "php${PHP_VERSION}-curl"
    install_package "php${PHP_VERSION}-zip"

    ensure_service "php${PHP_VERSION}-fpm"
}

generate_ssl_cert() {
    log_info "Tạo SSL self-signed cert"
    mkdir -p "$SSL_DIR"

    if [[ -f "$SSL_DIR/nginx.crt" ]] && [[ -f "$SSL_DIR/nginx.key" ]]; then
        log_info "SSL cert đã tồn tại, skip"
        return
    fi

    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout "$SSL_DIR/nginx.key" \
        -out "$SSL_DIR/nginx.crt" \
        -days "$SSL_DAYS" \
        -subj "/CN=${DOMAIN}" >> "$LOG_FILE" 2>&1 \
        || die "Tạo SSL cert thất bại" 20
}

setup_vhost_backend() {
    log_info "Tạo vhost backend"
    mkdir -p "$WEB_ROOT"

    cat > /etc/nginx/conf.d/${DOMAIN}.conf <<EOF
server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate     ${SSL_DIR}/nginx.crt;
    ssl_certificate_key ${SSL_DIR}/nginx.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root  ${WEB_ROOT};
    index index.php index.html;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log warn;

    client_max_body_size 100M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }
}

server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
EOF

    nginx -t >> "$LOG_FILE" 2>&1 || die "nginx config invalid" 21
    systemctl reload nginx
}

install_wordpress() {
    log_info "Cài WordPress"

    if [[ -f "${WEB_ROOT}/wp-config.php" ]]; then
        log_info "WordPress đã cài, skip"
    else
        cd "$WEB_ROOT"
        curl -sL "$WORDPRESS_URL" -o /tmp/wp.tar.gz
        tar -xf /tmp/wp.tar.gz -C /tmp
        cp -r /tmp/wordpress/. "$WEB_ROOT/"
        rm -rf /tmp/wordpress /tmp/wp.tar.gz
        cp "${WEB_ROOT}/wp-config-sample.php" "${WEB_ROOT}/wp-config.php"
    fi

    sed -i "s/database_name_here/${DB_NAME}/" "${WEB_ROOT}/wp-config.php"
    sed -i "s/username_here/${DB_USER}/" "${WEB_ROOT}/wp-config.php"
    sed -i "s/password_here/${DB_PASSWORD}/" "${WEB_ROOT}/wp-config.php"
    sed -i "s/localhost/${DB_MASTER_IP}/" "${WEB_ROOT}/wp-config.php"

    if ! grep -q "HTTP_X_FORWARDED_PROTO" "${WEB_ROOT}/wp-config.php"; then
        cat >> "${WEB_ROOT}/wp-config.php" <<EOF
// Reverse proxy support
if (isset(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && \$_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') {
    \$_SERVER['HTTPS'] = 'on';
}
if (isset(\$_SERVER['HTTP_X_REAL_IP'])) {
    \$_SERVER['REMOTE_ADDR'] = \$_SERVER['HTTP_X_REAL_IP'];
}
define('WP_HOME',    'https://${DOMAIN}');
define('WP_SITEURL', 'https://${DOMAIN}');
EOF
    fi

    chown -R www-data:www-data "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"
}

setup_backend() {
    log_info "=== [20-backend] Bắt đầu cài backend ==="
    install_nginx_backend
    install_php_fpm
    generate_ssl_cert
    setup_vhost_backend
    install_wordpress
    log_info "=== [20-backend] Hoàn thành ==="
}