B1: trỏ domain i-com-dashboard-ung.paytech.vn vào ip public của firewall(103.35.64.198)

B2: Truy cập vào setup-2F(192.168.200.195) -> ssh vào Proxy 1F(192.169.200.21) 

B3: cd vào /etc/nginx/sites-available/ và kiểm tra xem domain đã được dùng chưa
```
cd  /etc/nginx/sites-available/
ls | grep i-com-dashboard-ung.paytech.vn.conf
```

B4: Tạo file config cho domain cần public vi /etc/nginx/sites-available/i-com-dashboard-ung.paytech.vn.conf

```
server {
    listen 80;
    server_name i-com-dashboard-ung.paytech.vn;

    access_log /var/log/nginx/i-com-dashboard-ung.access.log;
    error_log /var/log/nginx/i-com-dashboard-ung.error.log;

    location / {
        proxy_pass http://192.168.200.120:8502;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
B5 Kiểm tra và reload lại cấu hình
```
nginx -t
systemctl reload config
```
