#!/bin/bash
# /opt/lemp-deploy/lib/30-db.sh

install_mariadb() {
    log_info "Cài MariaDB"
    install_package "mariadb-server"
    ensure_service "mariadb"
    open_firewall_port "3306/tcp"
}

secure_mariadb() {
    if mariadb -u root -p"${DB_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null; then return; fi
    mariadb -u root <<EOF >> "$LOG_FILE" 2>&1
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
EOF
}

setup_db_master() {
    log_info "Setup DB MASTER"
    local conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
    
    if ! grep -q "^server-id" "$conf"; then
        sed -i 's/^bind-address/#bind-address/' "$conf"
        cat >> "$conf" <<EOF

[mysqld]
server-id = 1
log_bin = /var/log/mysql/mysql-bin
binlog_format = ROW
bind-address = 0.0.0.0
expire_logs_days = 7
EOF
        systemctl restart mariadb
        sleep 3
    fi

    mariadb -u root -p"${DB_ROOT_PASSWORD}" <<EOF >> "$LOG_FILE" 2>&1
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'${BACKEND_1_IP}' IDENTIFIED BY '${DB_PASSWORD}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'${BACKEND_2_IP}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${BACKEND_1_IP}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'${BACKEND_2_IP}';

CREATE USER IF NOT EXISTS '${REPL_USER}'@'${DB_SLAVE_IP}' IDENTIFIED BY '${REPL_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO '${REPL_USER}'@'${DB_SLAVE_IP}';
FLUSH PRIVILEGES;
EOF
}

setup_db_slave() {
    log_info "Setup DB SLAVE"
    local conf="/etc/mysql/mariadb.conf.d/50-server.cnf"
    
    if ! grep -q "^server-id" "$conf"; then
        sed -i 's/^bind-address/#bind-address/' "$conf"
        cat >> "$conf" <<EOF

[mysqld]
server-id = 2
relay_log = /var/log/mysql/mysql-relay-bin
read_only = ON
bind-address = 0.0.0.0
EOF
        systemctl restart mariadb
        sleep 3
    fi

    log_info "Dump data từ master..."
    ssh -o StrictHostKeyChecking=no root@"${DB_MASTER_IP}" \
        "mysqldump -u root -p${DB_ROOT_PASSWORD} --all-databases --master-data=2" \
        > /tmp/master_dump.sql 2>>"$LOG_FILE" \
        || die "Dump master DB thất bại — check SSH key" 30

    local LOG_FILE_BIN=$(grep "CHANGE MASTER TO" /tmp/master_dump.sql | grep -oP "MASTER_LOG_FILE='\K[^']+")
    local LOG_POS=$(grep "CHANGE MASTER TO" /tmp/master_dump.sql | grep -oP "MASTER_LOG_POS=\K[0-9]+")

    log_info "Import dump vào slave..."
    mariadb -u root -p"${DB_ROOT_PASSWORD}" < /tmp/master_dump.sql
    rm -f /tmp/master_dump.sql

    mariadb -u root -p"${DB_ROOT_PASSWORD}" <<EOF >> "$LOG_FILE" 2>&1
STOP SLAVE;
RESET SLAVE ALL;
CHANGE MASTER TO
    MASTER_HOST='${DB_MASTER_IP}',
    MASTER_USER='${REPL_USER}',
    MASTER_PASSWORD='${REPL_PASSWORD}',
    MASTER_LOG_FILE='${LOG_FILE_BIN}',
    MASTER_LOG_POS=${LOG_POS};
START SLAVE;
EOF
}

setup_db() {
    local role="$1"
    log_info "=== [30-db] Setup database, role: $role ==="
    install_mariadb
    secure_mariadb
    case "$role" in
        db-master) setup_db_master ;;
        db-slave) setup_db_slave ;;
        *) die "Role không hợp lệ cho 30-db.sh: $role" 31 ;;
    esac
    log_info "=== [30-db] Hoàn thành ==="
}