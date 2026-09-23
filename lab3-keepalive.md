# Lab 3: Hệ thống Web High Availability (HA) với Keepalived và MariaDB Replication

## 1. Mô hình hệ thống (Topology)
Hệ thống gồm 3 Node chạy hệ điều hành Ubuntu để đảm bảo dự phòng cả ở tầng Web và tầng Database:
*   **Node 1 (BE1 / DB Master) - `192.168.10.200`:** Chạy Nginx (Web 1) và MariaDB (Master).
*   **Node 2 (BE2) - `192.168.10.205`:** Chạy Nginx (Web 2 dự phòng).
*   **Node 3 (DB Slave) - `192.168.10.206`:** Chỉ chạy MariaDB (Slave) để đồng bộ dữ liệu.
*   **VIP (Virtual IP) - `192.168.10.210`:** IP ảo dùng chung cho người dùng truy cập.

---

## 2. Cấu hình Database Replication (Đồng bộ Master - Slave)

### 2.1 Cấu hình trên DB Master (Node 1 - 192.168.10.200)
Mở file cấu hình MariaDB:
```bash
sudo vi /etc/mysql/mariadb.conf.d/50-server.cnf
```

Thêm/sửa các thông số sau trong block `[mysqld]`:
```ini
[mysqld]
bind-address = 0.0.0.0
server-id = 1
log_bin = /var/log/mysql/mysql-bin.log
```

Khởi động lại MariaDB và tạo User phân quyền:
```bash
sudo systemctl restart mariadb
sudo mysql -u root
```

Thực thi các lệnh SQL sau để cấp quyền Replication:
```sql
CREATE USER 'replica'@'%' IDENTIFIED BY 'replica123';
GRANT REPLICATION SLAVE ON *.* TO 'replica'@'%';
FLUSH PRIVILEGES;
SHOW MASTER STATUS;
EXIT;
```

Xuất dữ liệu và gửi sang Slave:
```bash
sudo mysqldump -u root --databases wordpress --master-data=2 > /tmp/wordpress_sync.sql
scp /tmp/wordpress_sync.sql root@192.168.10.206:/tmp/
```

### 2.2 Cấu hình trên DB Slave (192.168.10.206)
Mở file cấu hình MariaDB:
```bash
sudo vi /etc/mysql/mariadb.conf.d/50-server.cnf
```

Thêm/sửa các thông số sau:
```ini
[mysqld]
bind-address = 0.0.0.0
server-id = 2
```

Khởi động lại dịch vụ và nạp dữ liệu:
```bash
sudo systemctl restart mariadb
sudo mariadb -u root < /tmp/wordpress_sync.sql
sudo mariadb -u root
```

Cấu hình kết nối Master (Lưu ý: thay đổi thông số `MASTER_LOG_FILE` và `MASTER_LOG_POS` khớp với kết quả từ Master):
```sql
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='192.168.10.200', MASTER_USER='replica', MASTER_PASSWORD='replica123', MASTER_LOG_FILE='mysql-bin.000001', MASTER_LOG_POS=12345;
START SLAVE;
SHOW SLAVE STATUS\G
```

---

## 3. Cấu hình Keepalived (Virtual IP)

### 3.1 Trên Node 1 (Master 192.168.10.200)
Cài đặt Keepalived và tạo file cấu hình:
```bash
sudo apt install keepalived -y
sudo vi /etc/keepalived/keepalived.conf
```

Nội dung cấu hình:
```text
vrrp_script check_nginx {
    script "killall -0 nginx"
    interval 2
    weight -20
}

vrrp_instance VI_LEMP {
    state MASTER
    interface ens160
    virtual_router_id 151
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass LempHA2026
    }
    virtual_ipaddress {
        192.168.10.210
    }
    track_script {
        check_nginx
    }
}
```

Khởi động lại dịch vụ:
```bash
sudo systemctl restart keepalived
```

### 3.2 Trên Node 2 (Backup 192.168.10.205)
Cài đặt Keepalived và tạo file cấu hình:
```bash
sudo apt install keepalived -y
sudo vi /etc/keepalived/keepalived.conf
```

Nội dung cấu hình (Lưu ý `state BACKUP` và `priority 90`):
```text
vrrp_script check_nginx {
    script "killall -0 nginx"
    interval 2
    weight -20
}

vrrp_instance VI_LEMP {
    state BACKUP
    interface ens160
    virtual_router_id 151
    priority 90
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass LempHA2026
    }
    virtual_ipaddress {
        192.168.10.210
    }
    track_script {
        check_nginx
    }
}
```

Khởi động lại dịch vụ:
```bash
sudo systemctl restart keepalived
```