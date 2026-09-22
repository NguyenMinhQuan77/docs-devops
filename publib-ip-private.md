B1: Trỏ domain i-com-ung.paytech.vn vào ip public của firewall(103.35.64.198)

B2: Truy cập vào setup-2F(192.168.200.195) -> ssh vào Proxy 1F(192.169.200.21) 

B3: Tạo folder /etc/nginx/conf.d/ungdatambf  cho dự án mới và phân quyền
```
mkdir /etc/nginx/conf.d/ungdatambf 
chown root:root /etc/nginx/conf.d/ungdatambf 
chmod 755 /etc/nginx/conf.d/ungdatambf 
```
B4: Quét thêm folder vừa tạo vào file /etc/nginx/nginx.conf vào ngay dưới các include khác
```
include /etc/nginx/conf.d/ungdatambf /*.conf;
```
B5 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload nginx
```
B6: tạo certificate cho domain mới
```
mkdir -p /etc/letsencrypt/live/i-com-ung.paytech.vn
cp -a /etc/letsencrypt/live/lending.paytech.vn/* /etc/letsencrypt/live/i-com-ung.paytech.vn/
```
B6: Tạo file config cho domain cần public vi /etc/nginx/conf.d/ungdatambf /i-com-ung.paytech.vn.conf

```
server {
    listen 80;
    server_name i-com-ung.paytech.vn;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name i-com-ung.paytech.vn;

    access_log /var/log/nginx/i-com-ung.access.log;
    error_log  /var/log/nginx/i-com-ung.error.log;

    ssl_certificate /etc/letsencrypt/live/i-com-ung.paytech.vn/fullchain.pem; 
    ssl_certificate_key /etc/letsencrypt/live/i-com-ung.paytech.vn/privkey.pem; 
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
