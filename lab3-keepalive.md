# Hướng dẫn thiết lập High Availability (Keepalived + MariaDB Replication) trên Ubuntu

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

## 2. Phần A — Cài đặt và cấu hình Keepalived VRRP

### 2.1. Cấu hình trên Proxy MASTER (`192.168.10.204`)
Cài đặt Nginx và Keepalived trên Ubuntu:
```bash
sudo apt update
sudo apt install -y keepalived nginx
```

Tạo file cấu hình Keepalived:
```bash
sudo nano /etc/keepalived/keepalived.conf
```
Nội dung cấu hình:
```conf
vrrp_instance VI_LEMP {
    state MASTER
    interface ens160              # Tên card mạng (kiểm tra bằng lệnh ip a, ví dụ ens160 hoặc ens33)
    virtual_router_id 151         # VRID duy nhất cho cụm này
    priority 101                  # Mức độ ưu tiên (cao hơn = Master)
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass LempHA2026      # Mật khẩu xác thực chung nhóm
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
    weight -20                    # Trừ 20 điểm priority nếu Nginx chết
}
```

Tạo script kiểm tra Nginx:
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
Phân quyền thực thi và khởi động dịch vụ:
```bash
sudo chmod +x /etc/keepalived/check_nginx.sh
sudo systemctl enable --now keepalived
```

### 2.2. Cấu hình trên Proxy BACKUP (`192.168.10.208`)
Cài đặt tương tự:
```bash
sudo apt update
sudo apt install -y keepalived nginx
```
Tạo cấu hình Keepalived (Lưu ý đổi `state` thành BACKUP và `priority` thấp hơn):
```bash
sudo nano /etc/keepalived/keepalived.conf
```
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
Khởi động dịch vụ:
```bash
sudo systemctl enable --now keepalived
```

---

## 3. Phần B — Thiết lập MariaDB Replication

### 3.1. Cấu hình trên DB MASTER (`192.168.10.207`)
Cài đặt MariaDB trên Ubuntu:
```bash
sudo apt update
sudo apt install -y mariadb-server
```

Mở file cấu hình MariaDB (Đường dẫn chuẩn của Ubuntu):
```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```
Tìm block `[mysqld]` và sửa lại cho chính xác như sau:
```ini
[mysqld]
server-id = 1                       # ID duy nhất, master = 1
log_bin = /var/log/mysql/mysql-bin  # Bật binary log (đường dẫn chuẩn Ubuntu)
binlog_format = ROW                 # Row-based (an toàn nhất)
bind-address = 0.0.0.0              # Listen mọi interface
expire_logs_days = 7                # Auto-xoá binlog cũ sau 7 ngày
```

Mở port tường lửa UFW và khởi động lại MariaDB:
```bash
sudo ufw allow 3306/tcp
sudo systemctl restart mariadb
```

Tạo user Replication và lấy vị trí Binlog:
```bash
sudo mariadb -u root -p
```
```sql
CREATE USER 'repl'@'192.168.10.206' IDENTIFIED BY 'ReplPass123!';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.10.206';
FLUSH PRIVILEGES;

-- Khóa bảng để backup (chống write mới)
FLUSH TABLES WITH READ LOCK;

-- Lấy thông tin File và Position
SHOW MASTER STATUS; 
```
*(Ghi chú: Bạn BẮT BUỘC phải lưu lại thông tin cột `File` và `Position`)*

Dump dữ liệu (Mở một Tab Terminal khác, giữ nguyên tab SQL đang lock):
```bash
sudo mysqldump -u root -p --all-databases --master-data=2 > /tmp/master.sql
scp /tmp/master.sql root@192.168.10.206:/tmp/
```
Quay lại Tab Terminal SQL và mở khóa bảng:
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

Mở file cấu hình:
```bash
sudo nano /etc/mysql/mariadb.conf.d/50-server.cnf
```
Thêm/sửa block `[mysqld]`:
```ini
[mysqld]
server-id = 2                                  # ID khác master
relay_log = /var/log/mysql/mysql-relay-bin     # Bật relay log
read_only = ON                                 # Ép Slave ở chế độ chỉ đọc
bind-address = 0.0.0.0
```

Khởi động lại MariaDB và Import dữ liệu từ Master:
```bash
sudo systemctl restart mariadb
sudo mariadb -u root -p < /tmp/master.sql
```

Kết nối Replication:
```bash
sudo mariadb -u root -p
```
```sql
CHANGE MASTER TO
    MASTER_HOST='192.168.10.207',
    MASTER_USER='repl',
    MASTER_PASSWORD='ReplPass123!',
    MASTER_LOG_FILE='mysql-bin.000001',   -- Thay bằng Tên File thực tế đã lưu ở trên
    MASTER_LOG_POS=12345;                 -- Thay bằng Số Position thực tế đã lưu ở trên

START SLAVE;
SHOW SLAVE STATUS\G
```
*(Yêu cầu: `Slave_IO_Running` và `Slave_SQL_Running` đều phải hiển thị `Yes`)*

---

## 4. Kiểm tra hệ thống (Test Failover)

**Kiểm tra Proxy HA:**
1. Truy cập Proxy MASTER (`192.168.10.204`) và tắt Nginx (`sudo systemctl stop nginx`).
2. Sang Proxy BACKUP (`192.168.10.208`) chạy lệnh `ip a | grep 192.168.10.210`. Nếu thấy VIP xuất hiện, Failover thành công.

**Kiểm tra DB Replication:**
1. Trên DB MASTER (`192.168.10.207`) tạo dữ liệu:
   ```sql
   USE wordpress;
   INSERT INTO wp_options (option_name, option_value) VALUES ('test_repl', 'hello_ubuntu');
   ```
2. Sang DB SLAVE (`192.168.10.206`) kiểm tra:
   ```sql
   USE wordpress;
   SELECT * FROM wp_options WHERE option_name = 'test_repl';
   ```
   Nếu hiển thị giá trị `hello_ubuntu` là đồng bộ thành công. Thử chạy lệnh `INSERT` trên Slave sẽ báo lỗi do cấu hình `read_only = ON`.