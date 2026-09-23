# Lab 3: Hệ thống Web High Availability (HA) với Keepalived và MariaDB Replication

## 1. Mô hình hệ thống (Topology)
Hệ thống được thiết kế tách biệt các tầng (Proxy, Web Backend, Database) để đảm bảo độ sẵn sàng cao (High Availability) và chia tải hiệu quả:
*   **Proxy Master (đã có từ Lab 2):** `192.168.10.204` (Chạy Nginx Load Balancer và Keepalived Master)
*   **Proxy Backup (VM mới):** `192.168.10.208` (Chạy Nginx Load Balancer và Keepalived Backup)
*   **VIP (Virtual IP):** `192.168.10.210` (IP ảo gắn trên Proxy, dùng làm cổng truy cập chung)
*   **DB Master (VM mới):** `192.168.10.207` (Chạy MariaDB đóng vai trò Master)
*   **DB Slave (VM mới):** `192.168.10.206` (Chạy MariaDB đóng vai trò Slave dự phòng)
*   **Backend 1 (BE1):** `192.168.10.200` (Máy chủ Web Nginx + PHP-FPM)
*   **Backend 2 (BE2):** `192.168.10.205` (Máy chủ Web Nginx + PHP-FPM)

---

## 2. Cấu hình Database Replication (Đồng bộ Master - Slave)

### 2.1. Cấu hình trên DB Master (`192.168.10.207`)
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

Khởi động lại MariaDB và tạo User phân quyền đồng bộ:
```bash
sudo systemctl restart mariadb
sudo mysql -u root
```
```sql
CREATE USER 'replica'@'%' IDENTIFIED BY 'replica123';
GRANT REPLICATION SLAVE ON *.* TO 'replica'@'%';
FLUSH PRIVILEGES;
SHOW MASTER STATUS;
EXIT;
```
*(Ghi chú: Nhớ lưu lại thông số `File` và `Position` từ kết quả lệnh SHOW MASTER STATUS)*

Xuất dữ liệu và gửi sang máy DB Slave:
```bash
sudo mysqldump -u root --databases wordpress --master-data=2 > /tmp/wordpress_sync.sql
scp /tmp/wordpress_sync.sql root@192.168.10.206:/tmp/
```

### 2.2. Cấu hình trên DB Slave (`192.168.10.206`)
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

Khởi động lại dịch vụ, nạp dữ liệu và cấu hình kết nối tới Master:
```bash
sudo systemctl restart mariadb
sudo mariadb -u root < /tmp/wordpress_sync.sql
sudo mariadb -u root
```
```sql
STOP SLAVE;
CHANGE MASTER TO MASTER_HOST='192.168.10.207', MASTER_USER='replica', MASTER_PASSWORD='replica123', MASTER_LOG_FILE='mysql-bin.000001', MASTER_LOG_POS=12345;
START SLAVE;
SHOW SLAVE STATUS\G
```
*(Lưu ý: Thay `MASTER_LOG_FILE` và `MASTER_LOG_POS` bằng số liệu thực tế đã lưu ở bước 2.1)*

---

## 3. Cấu hình Keepalived (High Availability cho Nginx Proxy)

### 3.1. Cấu hình trên Proxy Master (`192.168.10.204`)
Cài đặt Keepalived:
```bash
sudo apt update
sudo apt install keepalived -y
```

Tạo file cấu hình:
```bash
sudo vi /etc/keepalived/keepalived.conf
```
Nội dung file:
```conf
vrrp_script check_nginx {
    script "killall -0 nginx"
    interval 2
    weight -20
}

vrrp_instance VI_PROXY {
    state MASTER
    interface ens160
    virtual_router_id 151
    priority 101
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ProxyHA2026
    }
    virtual_ipaddress {
        192.168.10.210
    }
    track_script {
        check_nginx
    }
}
```
Khởi động dịch vụ:
```bash
sudo systemctl enable keepalived
sudo systemctl restart keepalived
```

### 3.2. Cấu hình trên Proxy Backup (`192.168.10.208`)
Cài đặt Keepalived:
```bash
sudo apt update
sudo apt install keepalived -y
```

Tạo file cấu hình:
```bash
sudo vi /etc/keepalived/keepalived.conf
```
Nội dung file (Lưu ý đổi `state` thành BACKUP và `priority` thấp hơn):
```conf
vrrp_script check_nginx {
    script "killall -0 nginx"
    interval 2
    weight -20
}

vrrp_instance VI_PROXY {
    state BACKUP
    interface ens160
    virtual_router_id 151
    priority 90
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ProxyHA2026
    }
    virtual_ipaddress {
        192.168.10.210
    }
    track_script {
        check_nginx
    }
}
```
Khởi động dịch vụ:
```bash
sudo systemctl enable keepalived
sudo systemctl restart keepalived
```