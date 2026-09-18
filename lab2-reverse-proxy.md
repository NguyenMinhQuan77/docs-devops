# Lab 2: Triển khai Nginx Load Balancer & Cụm Web Server (HA)

## 1. Mô hình hệ thống (Topology)
Hệ thống gồm 3 Node chạy hệ điều hành Ubuntu:
*   **Backend 1 (BE1) - `192.168.10.200`:** Đã cấu hình LEMP Stack và chạy WordPress hoàn chỉnh từ **Lab 1**.
*   **Backend 2 (BE2) - `192.168.10.205`:** Node Web Server mới, chỉ chạy Nginx + PHP-FPM, kết nối chung vào Database của BE1.
*   **Proxy Server (Load Balancer):** Đứng ngoài cùng, nhận request từ người dùng và chia tải cho BE1 & BE2.
*   **Domain Name:** `test.com`

---

## 2. Tùy chỉnh Backend 1 (Cấp quyền Database cho BE2)
*(Lưu ý: Bỏ qua các bước cài đặt Nginx, PHP, tải Web vì đã làm ở Lab 1. Chỉ thực hiện cấu hình DB).*

### 2.1 Cấu hình MariaDB lắng nghe IP bên ngoài
Mở file cấu hình MariaDB:
```bash
sudo vi /etc/mysql/mariadb.conf.d/50-server.cnf
```
Tìm và đổi dòng `bind-address` thành:
```ini
bind-address = 0.0.0.0
```
Khởi động lại dịch vụ MariaDB:
```bash
sudo systemctl restart mariadb
```

### 2.2 Cấp quyền truy cập cho IP của BE2
Truy cập vào giao diện quản trị database:
```bash
sudo mysql
```
Cấp quyền cho user `test` truy cập từ IP của BE2 (`.205`):
```sql
CREATE USER 'test'@'192.168.10.205' IDENTIFIED BY 'test123';
GRANT ALL PRIVILEGES ON wordpress.* TO 'test'@'192.168.10.205';
FLUSH PRIVILEGES;
EXIT;
```

---

## 3. Triển khai Backend 2 (BE2 - 192.168.10.205)

### 3.1 Cài đặt phần mềm (Không cài MariaDB)
```bash
sudo apt update
sudo apt install -y nginx php8.2-fpm php8.2-mysql curl
```

### 3.2 Tạo chứng chỉ SSL tự ký
```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -days 365 \
  -subj "/CN=test.com"
```

### 3.3 Tải mã nguồn & Trỏ Database về BE1
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
Sửa các thông số Database (lưu ý **DB_HOST** trỏ về IP của BE1):
```php
define( 'DB_NAME', 'wordpress' );
define( 'DB_USER', 'test' );
define( 'DB_PASSWORD', 'test123' );
define( 'DB_HOST', '192.168.10.200' ); /* Trỏ về DB của BE1 */
```
Phân quyền thư mục web:
```bash
sudo chown -R www-data:www-data /home/www/test.com
sudo chmod -R 755 /home/www/test.com
```

### 3.4 Cấu hình Nginx
Tạo file vhost:
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

## 4. Triển khai Proxy Server (Load Balancer)

Truy cập vào máy Proxy, cài đặt Nginx:
```bash
sudo apt update
sudo apt install -y nginx
```

Tạo SSL tự ký (giống bước 3.2). Sau đó, tạo file vhost điều hướng traffic:
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
    # Chuyển hướng HTTP sang HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name test.com [www.test.com](https://www.test.com);

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    location / {
        # Proxy giao tiếp bằng HTTPS do Backend chỉ mở cổng 443
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
   Thêm IP của máy **Proxy Server** đi kèm domain `test.com` vào file `hosts` của máy tính đang lab.
   
2. **Kiểm tra hoạt động bình thường:**
   Mở trình duyệt truy cập `https://test.com`, hệ thống sẽ tải bình thường.

3. **Kiểm tra tính năng cân bằng tải và HA:**
   * Truy cập vào máy **BE1**, tắt dịch vụ Nginx: `sudo systemctl stop nginx`
   * Ra trình duyệt tải lại trang (F5).
   * **Kết quả:** Trang web vẫn hoạt động trơn tru. Nginx Load Balancer trên Proxy đã phát hiện BE1 bị down và tự động đẩy 100% traffic sang **BE2** để xử lý. Người dùng không hề biết hệ thống có 1 máy bị lỗi.