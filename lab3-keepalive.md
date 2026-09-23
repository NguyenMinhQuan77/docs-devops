# Lab 3: Cấu hình High Availability (Keepalived + MariaDB Replication) trên Ubuntu

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

## 2. Phần A — Cấu hình Keepalived & Nginx HA

### 2.1. Cấu hình trên Proxy MASTER (`192.168.10.204`)
Cài đặt Keepalived (Nginx đã có từ Lab 2):
```bash
sudo apt update
sudo apt install -y keepalived
```

Tạo file cấu hình Keepalived:
```bash
sudo nano /etc/keepalived/keepalived.conf
```
Nội dung cấu hình:
```conf
vrrp_instance VI_LEMP {
    state MASTER
    interface ens160              # Tên card mạng (kiểm tra bằng lệnh ip a)
    virtual_router_id 151
    priority 101                  # Mức độ ưu tiên cao hơn Backup
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass LempHA2026
    }
    virtual_ipaddress {
        192.168.10.210            # IP ảo (VIP)
    }
    track_script {
        check_nginx
    }
}

vrrp_script check_nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight -20                    # Giảm 20 priority nếu Nginx chết
}
```

Tạo script kiểm tra trạng thái Nginx:
```bash
sudo nano /etc/keepalived/check_nginx.sh
```
Nội dung script:
```bash
#!/bin/bash
if systemctl is-active --quiet nginx; then
    exit 0
else
    exit 1
fi
```
Phân quyền và khởi động Keepalived:
```bash
sudo chmod +x /etc/keepalived/check_nginx.sh
sudo systemctl enable --now keepalived
```

### 2.2. Cấu hình trên Proxy BACKUP (`192.168.10.208`)
Cài đặt Nginx và Keepalived:
```bash
sudo apt update
sudo apt install -y nginx keepalived
```

**Đồng bộ cấu hình Nginx từ Proxy Master:**
Bạn cần chép file cấu hình Load Balancer (VD: `test.vn.conf`) và chứng chỉ SSL (nếu có) từ Master sang Backup. Đứng tại Proxy Backup, chạy các lệnh sau:
```bash
# Copy cấu hình Nginx từ Master sang Backup
scp root@192.168.10.204:/etc/nginx/sites-available/test.vn.conf /etc/nginx/sites-available/

# Kích hoạt cấu hình vừa copy
sudo ln -s /etc/nginx/sites-available/test.vn.conf /etc/nginx/sites-enabled/
sudo systemctl restart nginx
```
*(Lưu ý: Nếu bạn dùng thư mục `conf.d`, hãy copy file `/etc/nginx/conf.d/test.vn.conf`. Nếu có SSL, copy thêm thư mục chứa Cert).*

Tạo file cấu hình Keepalived:
```bash
sudo nano /etc/keepalived/keepalived.conf
```
Nội dung (Lưu ý `state BACKUP` và `priority 90`):
```conf
vrrp_instance VI_LEMP {
    state BACKUP
    interface ens160
    virtual_router_id 151
    priority 90                   # Thấp hơn MASTER
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass LempHA2026
    }
    virtual_ipaddress {
        192.168.10.210
    }
}
```
Khởi động Keepalived:
```bash
sudo systemctl enable --now keepalived
```

---

## 3. Phần B — Thiết lập MariaDB Replication

### 3.1. Cấu hình trên DB MASTER (`192.168.10.207`)
Cài đặt MariaDB:
```bash
sudo apt update
sudo apt install -y mariadb-server
```

Cấu hình DB Master:
```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```
Thêm/sửa block `[mysqld]`:
```ini
[mysqld]
server-id = 1
log_bin = /var/log/mysql/mysql-bin
binlog_format = ROW
bind-address = 0.0.0.0
expire_logs_days = 7
```
Khởi động lại dịch vụ:
```bash
sudo ufw allow 3306/tcp
sudo systemctl restart mariadb
```

Tạo User đồng bộ và khóa bảng:
```bash
sudo mariadb -u root -p
```
```sql
CREATE USER 'replica'@'192.168.10.206' IDENTIFIED BY 'Replica123!';
GRANT REPLICATION SLAVE ON *.* TO 'replica'@'192.168.10.206';
FLUSH PRIVILEGES;

FLUSH TABLES WITH READ LOCK;
SHOW MASTER STATUS; 
```
*(Ghi chú: LƯU LẠI thông số cột `File` và `Position`)*

Dump dữ liệu (Giữ nguyên cửa sổ SQL trên, mở Terminal mới):
```bash
sudo mysqldump -u root -p --all-databases --master-data=2 > /tmp/master.sql
scp /tmp/master.sql root@192.168.10.206:/tmp/
```
Quay lại cửa sổ SQL cũ, mở khóa bảng:
```sql
UNLOCK TABLES;
EXIT;
```

### 3.2. Cấu hình trên DB SLAVE (`192.168.10.206`)
Cài đặt MariaDB:
```bash
sudo apt update
sudo apt install -y mariadb-server
```

Cấu hình DB Slave:
```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```
Thêm/sửa block `[mysqld]`:
```ini
[mysqld]
server-id = 2
relay_log = /var/log/mysql/mysql-relay-bin
read_only = ON
bind-address = 0.0.0.0
```
Khởi động lại và nạp dữ liệu:
```bash
sudo systemctl restart mariadb
sudo mariadb -u root -p < /tmp/master.sql
```

Kích hoạt Replication:
```bash
sudo mariadb -u root -p
```
```sql
CHANGE MASTER TO
    MASTER_HOST='192.168.10.207',
    MASTER_USER='replica',
    MASTER_PASSWORD='Replica123!',
    MASTER_LOG_FILE='mysql-bin.000001',   -- Sửa theo File đã lấy ở Master
    MASTER_LOG_POS=12345;                 -- Sửa theo Position đã lấy ở Master

START SLAVE;
SHOW SLAVE STATUS\G
```
*(Yêu cầu: `Slave_IO_Running` và `Slave_SQL_Running` phải hiển thị `Yes`)*

---

## 4. Kiểm tra hệ thống

**1. Kiểm tra Web & Load Balancer HA:**
*   Truy cập web thông qua VIP: `http://192.168.10.210` (Web tải bình thường).
*   Tắt Nginx trên Proxy Master: `sudo systemctl stop nginx`.
*   Truy cập lại Web. Dữ liệu vẫn tải bình thường nhờ VIP đã được Keepalived bắn sang Proxy Backup (192.168.10.208).

**2. Kiểm tra Database HA:**
*   Trên DB MASTER (`192.168.10.207`):
    ```sql
    CREATE DATABASE test_ha;
    ```
*   Sang DB SLAVE (`192.168.10.206`), chạy lệnh `SHOW DATABASES;`. Nếu thấy DB `test_ha` xuất hiện, đồng bộ đã thành công.