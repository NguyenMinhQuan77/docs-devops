# Hướng dẫn deploy `vitapay_provider_gw_pvcb`

## Tổng quan

| Máy | Vai trò |
|---|---|
| `192.168.200.12` (sys-setup2f) | Máy build — có mạng, có JDK 8 + Maven |
| `192.168.200.151` (vitapay-api1f) | Máy app 1 — không có mạng |
| `192.168.200.152` | Máy app 2 — không có mạng |

Luồng: **lấy code + config → build trên .12 → sync sang máy app → backup → deploy → restart → kiểm tra**.
Luôn deploy xong **.151**, kiểm tra ổn định rồi mới làm **.152**.

**Đường dẫn quan trọng**

| Mục | Đường dẫn |
|---|---|
| Source build trên .12 | `/tmp/build/providergw_evn` |
| Kho thư viện Maven trên .12 | `/tmp/m2repo` |
| Maven trên .12 | `/home/hunghv/apache-maven-3.9.9/bin/mvn` |
| App đang chạy (máy app) | `/opt/vitapay/vitapay_provider_gw_pvcb` |
| Source build (máy app) | `/opt/vitapay/build/providergw_evn` |
| Backup (máy app) | `/opt/vitapay/backup/vitapay_provider_gw_pvcb/<YYYYMMDD_HHMM>` |
| Script deploy (máy app) | `~/deploy_pvcb.sh` |
| Tên service supervisor | `vitapay_provider_gw_pvcb` |

> ⚠️ Trên .12 **luôn làm bằng user `hunghv`**, không dùng root. Nếu lỡ dùng root thì `~` sẽ trỏ sang `/root` (không thấy Maven) và file build bị đổi chủ sở hữu.

---

## A. Chuẩn bị (chỉ làm 1 lần — ĐÃ XONG)

- [x] Tải Maven 3.9.9 trên .12, giải nén vào `/home/hunghv/apache-maven-3.9.9`
- [x] Source đã có tại `/tmp/build/providergw_evn` trên .12
- [x] Kho thư viện `/tmp/m2repo` trên .12, đã sync sang `/root/.m2/repository` trên máy app
- [x] Script `deploy_pvcb.sh` đã có trên .151 / .152

Đổi backup sang dạng có giờ phút để deploy nhiều lần trong ngày không ghi đè bản cũ
(chạy trên **.151 và .152**, chỉ cần 1 lần):

```bash
sed -i 's/TODAY=$(date +%Y%m%d)/TODAY=$(date +%Y%m%d_%H%M)/' deploy_pvcb.sh
grep TODAY= deploy_pvcb.sh      # kiểm tra: phải thấy %Y%m%d_%H%M
```

---

## B. Các bước mỗi lần deploy

### Bước 1 — Trên .12: lấy code mới

```bash
cd /tmp/build/providergw_evn

git checkout -- .                 # bỏ config cục bộ để pull không xung đột
git fetch origin
git checkout <ten_branch>
git pull origin <ten_branch>
```

### Bước 2 — Trên .12: lấy config thật từ .151

```bash
rsync -av hunghv@192.168.200.151:/opt/vitapay/vitapay_provider_gw_pvcb/src/main/resources/ \
      /tmp/build/providergw_evn/src/main/resources/
```

> Nếu báo `Permission denied`: vào .151 chạy
> `sudo chmod -R o+r /opt/vitapay/vitapay_provider_gw_pvcb/src/main/resources`

### Bước 3 — Trên .12: build

```bash
cd /tmp/build/providergw_evn
~/apache-maven-3.9.9/bin/mvn -Dmaven.repo.local=/tmp/m2repo clean install -Dmaven.test.skip
```

Chỉ đi tiếp khi thấy `BUILD SUCCESS`. Kiểm tra file JAR:

```bash
ls -lh /tmp/build/providergw_evn/target/*.jar
# provider-gateway-0.0.1-SNAPSHOT.jar  (~86M)
```

### Bước 4 — Trên .12: sync sang máy app

```bash
for host in 192.168.200.151 192.168.200.152; do
    rsync -az --delete /tmp/build/providergw_evn/ hunghv@$host:/tmp/providergw_evn_built/
    rsync -az /tmp/m2repo/ hunghv@$host:/tmp/m2repo/
done
```

### Bước 5 — Trên .151: đưa source đã build vào đúng chỗ

```bash
sudo rsync -a /tmp/providergw_evn_built/ /opt/vitapay/build/providergw_evn/
sudo rsync -a /tmp/m2repo/ /root/.m2/repository/
```

### Bước 6 — Trên .151: backup → deploy → restart

```bash
sudo ./deploy_pvcb.sh backup
sudo ./deploy_pvcb.sh deploy
sudo ./deploy_pvcb.sh restart
```

> Không chạy `build` trên máy app — đã build sẵn ở .12.

### Bước 7 — Trên .151: kiểm tra

```bash
sudo supervisorctl status vitapay_provider_gw_pvcb
```

- Trạng thái phải là `RUNNING`, uptime tăng dần, không restart liên tục.
- Xem log để chắc app khởi động xong, không có lỗi (đường dẫn log xem trong `/etc/supervisor/conf.d/`).

### Bước 8 — Lặp lại Bước 5 → 7 trên .152

> Nếu config .152 khác .151 (IP, port, tên node…): trên .152 chạy thêm
> `sudo ./deploy_pvcb.sh config` rồi `sudo ./deploy_pvcb.sh build` (build offline, đã có thư viện)
> **trước** bước `backup`.

---

## C. Rollback khi có lỗi

```bash
sudo ./deploy_pvcb.sh rollback                  # về bản backup mới nhất
sudo ./deploy_pvcb.sh rollback 20261022_1340    # hoặc về 1 bản cụ thể
```

Xem danh sách bản backup:

```bash
ls -1 /opt/vitapay/backup/vitapay_provider_gw_pvcb/
```

---

## D. Lỗi thường gặp

| Lỗi | Nguyên nhân | Cách xử lý |
|---|---|---|
| `mvn: command not found` / `/root/apache-maven-3.9.9/bin/mvn: No such file` | Đang ở user root trên .12 | `exit` về hunghv, hoặc dùng `/home/hunghv/apache-maven-3.9.9/bin/mvn` |
| `Non-resolvable parent POM` / `Connection timed out` | Build trên máy không có mạng | Build trên .12 (Bước 3) |
| `cd: providergw_evn: No such file or directory` | Chưa giải nén / sai thư mục | Kiểm tra `ls /tmp/build` |
| `scp: ... No such file or directory` | Sai đường dẫn đích | Home của hunghv là `/home/hunghv/` |
| `Permission denied` khi sync | File thuộc root | `sudo chown -R hunghv:hunghv /tmp/build/providergw_evn /tmp/m2repo` |
| `git pull` báo `local changes would be overwritten` | Config cục bộ bị sửa | `git checkout -- .` rồi pull lại, sau đó làm lại Bước 2 |