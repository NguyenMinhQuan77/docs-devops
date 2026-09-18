# Lab 2: Triển khai Nginx Load Balancer & Cụm Web Server LEMP (Ubuntu)

## 1. Mô hình hệ thống (Topology)
Hệ thống gồm 3 Node chạy hệ điều hành Ubuntu:
*   **Proxy Server (Load Balancer):** Đứng ngoài cùng, nhận request từ người dùng và chia tải.
*   **Backend 1 (BE1) - `192.168.10.200`:** Chạy Web Server (Nginx + PHP-FPM) và chứa Database chính (MariaDB).
*   **Backend 2 (BE2) - `192.168.10.205`:** Chỉ chạy Web Server (Nginx + PHP-FPM), kết nối chung vào Database của BE1.
*   **Domain Name:** `test.com`

---

## 2. Cấu hình Backend 1 (BE1 - 192.168.10.200)

### 2.1 Cài đặt các gói phần mềm cần thiết
```bash
sudo apt update
sudo apt install -y nginx mariadb-server php8.2-fpm php8.2-mysql curl
```

### 2.2 Tạo chứng chỉ SSL tự ký (Self-signed)
```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -days 365 \
  -subj "/CN=test.com"
```

### 2.3 Cấu hình Database MariaDB
Mở cấu hình MariaDB để cho phép kết nối từ xa:
```bash
sudo vi /etc/mysql/mariadb.conf.d/50-server.cnf
```
Đổi dòng `bind-address` thành:
```ini
bind-address = 0.0.0.0
```
Khởi động lại MariaDB:
```bash
sudo systemctl restart mariadb
```
Tạo Database và cấp quyền cho cả BE1 (localhost) và BE2 (.205):
```bash
sudo mysql

CREATE DATABASE wordpress;
CREATE USER 'test'@'localhost' IDENTIFIED BY 'test123';
CREATE USER 'test'@'192.168.10.205' IDENTIFIED BY 'test123';
GRANT ALL PRIVILEGES ON wordpress.* TO 'test'@'localhost';
GRANT ALL PRIVILEGES ON wordpress.* TO 'test'@'192.168.10.205';
FLUSH PRIVILEGES;
EXIT;
```

### 2.4 Cấu hình Nginx & Tải mã nguồn WordPress
```bash
sudo mkdir -p /home/www/test.com
cd /home/www/test.com
sudo curl -O [https://wordpress.org/latest.tar.gz](https://wordpress.org/latest.tar.gz)
sudo tar -xvf latest.tar.gz
sudo mv wordpress/* .
sudo rm -rf wordpress latest.tar.gz

# Cấu hình wp-config.php
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/wordpress/" wp-config.php
sudo sed -i "s/username_here/test/" wp-config.php
sudo sed -i "s/password_here/test123/" wp-config.php
# Trên BE1, DB_HOST vẫn là localhost (mặc định)

# Cấp quyền cho thư mục web
sudo chown -R www-data:www-data /home/www/test.com
sudo chmod -R 755 /home/www/test.com
```

Tạo file vhost cho Nginx trên BE1:
```bash
sudo vi /etc/nginx/sites-available/test.com
```
Nội dung file:
```nginx
server {
    listen 443 ssl;
    server_name test.com [www.test.com](https://www.test.com);

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /home/www/test.com;
    index index.php index.html;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }
}
```
Kích hoạt vhost:
```bash
sudo ln -s /etc/nginx/sites-available/test.com /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

---

## 3. Cấu hình Backend 2 (BE2 - 192.168.10.205)

### 3.1 Cài đặt phần mềm (Không cài MariaDB)
```bash
sudo apt update
sudo apt install -y nginx php8.2-fpm php8.2-mysql curl
```

### 3.2 Tạo chứng chỉ SSL tự ký
Làm tương tự bước 2.2 của BE1:
```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -days 365 \
  -subj "/CN=test.com"
```

### 3.3 Tải mã nguồn & Cấu hình WordPress kết nối DB từ xa
Làm tương tự bước 2.4, nhưng trong file `wp-config.php` phải sửa lại **DB_HOST**:
```bash
sudo mkdir -p /home/www/test.com
cd /home/www/test.com
sudo curl -O [https://wordpress.org/latest.tar.gz](https://wordpress.org/latest.tar.gz)
sudo tar -xvf latest.tar.gz
sudo mv wordpress/* .
sudo rm -rf wordpress latest.tar.gz

sudo cp wp-config-sample.php wp-config.php
sudo vi wp-config.php
```
Sửa các thông số sau:
```php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'test' );
define( 'DB_PASSWORD', 'test123' );
define( 'DB_HOST', '192.168.10.200' ); /* Trỏ về IP của BE1 */
```
Phân quyền thư mục:
```bash
sudo chown -R www-data:www-data /home/www/test.com
sudo chmod -R 755 /home/www/test.com
```

### 3.4 Cấu hình Nginx
Tạo file vhost (`/etc/nginx/sites-available/test.com`) có nội dung **giống hệt BE1** ở bước 2.4. Sau đó kích hoạt:
```bash
sudo ln -s /etc/nginx/sites-available/test.com /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

---

## 4. Cấu hình Proxy Server (Load Balancer)

Truy cập vào máy Proxy, cài đặt Nginx:
```bash
sudo apt update
sudo apt install -y nginx
```

Tạo SSL tự ký (giống bước 2.2). Sau đó, tạo file vhost điều hướng traffic:
```bash
sudo vi /etc/nginx/sites-available/test.com
```
Nội dung file:
```nginx
upstream backend_servers {
    # Cấu hình IP và Port của 2 máy Backend
    server 192.168.10.200:443 max_fails=3 fail_timeout=30s;
    server 192.168.10.205:443 max_fails=3 fail_timeout=30s;
}

server {
    listen 80;
    server_name test.com [www.test.com](https://www.test.com);
    # Chuyển hướng toàn bộ HTTP sang HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name test.com [www.test.com](https://www.test.com);

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location / {
        # Yêu cầu proxy giao tiếp bằng HTTPS do Backend chặn cổng 80
        proxy_pass https://backend_servers;
        
        # Đẩy IP thật của Client về Backend
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Kích hoạt cấu hình Proxy:
```bash
sudo ln -s /etc/nginx/sites-available/test.com /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

---

## 5. Kiểm thử hệ thống (Testing Failover)

1. **Trỏ file Hosts trên máy trạm (Client):**
   Thêm IP của máy **Proxy Server** đi kèm domain `test.com` vào file `hosts`.
   
2. **Cài đặt WordPress:**
   Mở trình duyệt truy cập `https://test.com`, màn hình cài đặt của WordPress sẽ hiện ra. Thực hiện các bước Setup Wizard.

3. **Kiểm tra tính năng cân bằng tải và High Availability (HA):**
   * Vào máy **BE1**, tắt dịch vụ Nginx: `sudo systemctl stop nginx`
   * Ra trình duyệt tải lại trang (F5).
   * **Kết quả mong đợi:** Trang web vẫn hoạt động bình thường, toàn bộ request đã được máy Proxy tự động đẩy sang **BE2 (192.168.10.205)** để xử lý, không gây gián đoạn (Downtime) cho người dùng.