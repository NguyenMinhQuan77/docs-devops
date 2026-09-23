B1: Trỏ domain ungdatambf.paytech.vn vào ip public của firewall(103.35.64.198)

B2: Truy cập vào setup-2F(192.168.200.195) -> ssh vào Proxy 1F(192.169.200.21) 

B3: Tạo folder /etc/nginx/conf.d/ungdatambf cho dự án mới và phân quyền
```
mkdir /etc/nginx/conf.d/ungdatambf
chown root:root /etc/nginx/conf.d/ungdatambf
chmod 755 /etc/nginx/conf.d/ungdatambf
```
B4: Quét thêm folder vừa tạo vào file /etc/nginx/nginx.conf vào ngay dưới các include khác
```
include /etc/nginx/conf.d/ungdatambf/*.conf;
```
B5 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload nginx
```
B6: tạo certificate cho domain mới
```
certbot certonly --webroot -w /var/www/html -d ungdatambf.paytech.vn
```
- note: tìm xem có domain nào dùng kiểu wildcard certificate không
```
certbot certificates | grep -F "*.paytech.vn" -B 2 -A 2
```
note: phải đưa config về dạng
```
server {
    listen 80;
    server_name ungdatambf.paytech.vn;

    # Hướng xác thực của Let's Encrypt vào thư mục tĩnh nội bộ
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```
B6: Tạo file config cho domain cần public vi /etc/nginx/conf.d/ungdatambf/ungdatambf.paytech.vn.conf

```
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# Block 1: Ép HTTPS và hỗ trợ Auto-renew SSL
server {
    listen 80;
    server_name ungdatambf.paytech.vn;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# Block 2: Xử lý HTTPS và Proxy cho Streamlit
server {
    listen 443 ssl;
    server_name ungdatambf.paytech.vn;

    access_log /var/log/nginx/ungdatambf.access.log;
    error_log  /var/log/nginx/ungdatambf.error.log;

    # Đường dẫn SSL chuẩn của tên miền
    ssl_certificate /etc/letsencrypt/live/ungdatambf.paytech.vn/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ungdatambf.paytech.vn/privkey.pem;
    
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass http://192.168.200.120:8502;

        # WebSocket cho Streamlit
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Giữ kết nối WebSocket lâu, không buffer
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }
}
```
B7 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload nginx
```
B8 Đứng ở backend, accept iptable cho phép proxy đổ traffic vào
```
iptables -I INPUT -p tcp -s 192.168.200.21 --dport 8502 -j ACCEPT

```
B9 Đứng ở proxy, accept iptable cho phép proxy đổ traffic vào
```
iptables -I OUTPUT -p tcp -d 192.168.200.120 --dport 8502 -j ACCEPT
```