B1: Trỏ domain i-com-ung.vn vào ip public của firewall(103.35.64.198)

B2: Truy cập vào setup-2F(192.168.200.195) -> ssh vào Proxy 1F(192.169.200.21) 

B3: Tạo folder /etc/nginx/conf.d/autoreport cho dự án mới
```
mkdir /etc/nginx/conf.d/autoreport
```
B4: Quét thêm folder vừa tạo vào file /etc/nginx/nginx.conf vào ngay dưới các include khác
```
include /etc/nginx/conf.d/autoreport/*.conf;
```
B5 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload nginx
```
B6: Tạo file config cho domain cần public vi /etc/nginx/conf.d/autoreport/i-com-ung.vn.conf

```
server {
    listen 80;
    server_name i-com-ung.vn;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name i-com-ung.vn;

    access_log /var/log/nginx/i-com-ung.access.log;
    error_log  /var/log/nginx/i-com-ung.error.log;

    ssl_certificate /etc/letsencrypt/live/i-com-ung.vn/fullchain.pem; 
    ssl_certificate_key /etc/letsencrypt/live/i-com-ung.vn/privkey.pem; 
    include /etc/letsencrypt/options-ssl-nginx.conf; 
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; 

    location / {
        proxy_pass http://192.168.200.120:8502;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
B7 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload nginx
```
