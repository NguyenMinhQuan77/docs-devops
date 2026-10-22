# Lab 01: Triển khai LEMP Stack & WordPress trên Ubuntu (High Availability - Chặng 4)

## 1. Chuẩn bị hệ thống và cài đặt Nginx
- Cập nhật hệ thống và cài đặt Nginx
```bash
sudo apt update
sudo apt install -y nginx
sudo systemctl enable nginx --now
```

- Mở port Firewall (UFW) cho Web
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw reload
```

- Tạo chứng chỉ SSL tự ký (Self-signed) cho domain `test.com`
```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/nginx/ssl/nginx.key \
  -out /etc/nginx/ssl/nginx.crt \
  -days 365 -subj "/CN=test.com"
```

- Tạo thư mục chứa Web và cấu hình Virtual Host
```bash
sudo mkdir -p /home/www/test.com
sudo tee /etc/nginx/sites-available/test.com <<'EOF'
server {
    listen 443 ssl;
    server_name test.com [www.test.com](https://www.test.com);

    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers 'HIGH:!aNULL:!MD5';
    ssl_prefer_server_ciphers on;

    root /home/www/test.com;
    index index.php index.html index.htm;

    access_log /var/log/nginx/test.com.access.log;
    error_log /var/log/nginx/test.com.error.log warn;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
    }
}

server {
    listen 80;
    server_name test.com [www.test.com](https://www.test.com);
    return 301 https://$host$request_uri;
}
EOF
```

- Bật cấu hình Nginx vừa tạo và khởi động lại dịch vụ
```bash
sudo ln -s /etc/nginx/sites-available/test.com /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx
```

## 2. Cài đặt MariaDB & Tạo Database
- Cài đặt MariaDB Server
```bash
sudo apt install -y mariadb-server
sudo systemctl enable mariadb --now
```

- Truy cập vào MariaDB CLI để tạo Database và User cho WordPress
```bash
sudo mariadb -u root
```
```sql
CREATE DATABASE wordpress;
CREATE USER 'wordpress'@'localhost' IDENTIFIED BY 'MyStrongPass123!';
GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpress'@'localhost';
FLUSH PRIVILEGES;
EXIT;
```

## 3. Cài đặt PHP-FPM (Phiên bản 8.2)
- Cài đặt các gói PHP 8.2 cần thiết cho WordPress
```bash
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
sudo apt install -y php8.2-fpm php8.2-cli php8.2-mysql php8.2-gd php8.2-mbstring php8.2-xml php8.2-zip
```

- Kiểm tra dịch vụ PHP-FPM
```bash
sudo systemctl enable php8.2-fpm --now
sudo systemctl status php8.2-fpm
```

## 4. Tải và cấu hình WordPress
- Tải mã nguồn WordPress về thư mục Web root
```bash
cd /home/www/test.com
sudo curl -O [https://wordpress.org/latest.tar.gz](https://wordpress.org/latest.tar.gz)
sudo tar -xvf latest.tar.gz
sudo mv wordpress/* .
sudo rm -rf wordpress latest.tar.gz
```

- Cấu hình file `wp-config.php` kết nối Database
```bash
sudo cp wp-config-sample.php wp-config.php
sudo sed -i "s/database_name_here/wordpress/" wp-config.php
sudo sed -i "s/username_here/wordpress/" wp-config.php
sudo sed -i "s/password_here/MyStrongPass123!/" wp-config.php
```

- Phân quyền thư mục Web cho Nginx/PHP-FPM (`www-data` trên Ubuntu)
```bash
sudo chown -R www-data:www-data /home/www/test.com
sudo chmod -R 755 /home/www/test.com
```

## 5. Cấu hình Client truy cập Web (Dành cho máy Windows qua SSH Tunnel)
*Lưu ý: Do mạng Lab trỏ IP Public qua NAT Port và chặn Port Web 443 từ ngoài vào, cần dùng kỹ thuật SSH Tunneling để vượt Firewall.*

- Bước 1: Sửa file `hosts` trên Windows (`C:\Windows\System32\drivers\etc\hosts`) bằng Notepad (Quyền Admin), thêm dòng sau:
```text
127.0.0.1   test.com [www.test.com](https://www.test.com)
```

- Bước 2: Mở CMD trên Windows, chạy lệnh tạo đường hầm SSH (Thay IP và Port thực tế của Server Lab):
```cmd
ssh -L 443:127.0.0.1:443 root@1.53.x.x -p 22120
```
*(Giữ nguyên cửa sổ CMD này để duy trì kết nối)*

- Bước 3: Mở trình duyệt Chrome/Edge truy cập `https://test.com`, bỏ qua cảnh báo bảo mật SSL tự ký và hoàn tất Setup Wizard của WordPress.