# Cấu hình network cho VM mới tạo từ template (Ubuntu 22.04, vSphere)

Tài liệu áp dụng cho VM Ubuntu tạo từ template trên vSphere. Thay các giá trị trong `<...>` bằng thông tin thực tế.

## 0. Chuẩn bị thông tin

| Thông tin | Ví dụ |
|---|---|
| Tên VM / hostname | `<HOSTNAME>` (vd: `jenkins-slave`) |
| IP / subnet | `<IP>/24` (vd: `192.168.200.195/24`) |
| Gateway | `192.168.200.1` |
| DNS | `192.168.200.11`, `192.168.200.12` |
| Search domain | `paytech.io` |

**Kiểm tra IP chưa bị dùng** (chạy từ một máy khác cùng dải mạng):

```bash
ping -c 3 <IP>
```

Không có phản hồi thì mới dùng. Nên kiểm tra thêm trong DNS và tài liệu quản lý IP.

---

## 1. Truy cập VM qua Web Console

1. vSphere Client → chọn VM → **Launch Web Console**.
2. Bấm **Enforce US Keyboard Layout** trước khi gõ (tránh gõ sai ký tự `:`, `|`, `"`...).
3. Web Console **không dán được**: phải gõ tay. Vì vậy chỉ làm tới bước có mạng và SSH được, phần còn lại làm qua SSH.

> **Mẹo**: Nếu cần SSH vào nhanh trước, đặt IP tạm (mất khi reboot):
>
> ```bash
> ip link set <IFACE> up
> ip addr add <IP>/24 dev <IFACE>
> ip route add default via 192.168.200.1
> ```

---

## 2. Xác định tên card mạng

```bash
ip -br link
```

Tên card thường là `ens160` hoặc `ens192` (bỏ qua `lo`). Ghi lại làm `<IFACE>`.

Đối chiếu MAC với vSphere (VM → Summary → VM Hardware → Network adapter) nếu VM có nhiều card.

---

## 3. Tắt cloud-init quản lý mạng

VM từ template thường có `/etc/netplan/50-cloud-init.yaml` do cloud-init **sinh lại mỗi lần boot**. Nếu không tắt, cấu hình tay sẽ bị ghi đè.

Xem các file cấu hình mạng của cloud-init:

```bash
ls /etc/cloud/cloud.cfg.d/
grep -rn network /etc/cloud/cloud.cfg.d/
```

Tạo file tắt cấu hình mạng:

```bash
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
```

> Nếu có file `90-installer-network.cfg` (do subiquity viết) chứa cấu hình mạng khác, sửa nội dung thành `network: {config: disabled}` hoặc đổi tên/xóa nó.

---

## 4. Viết cấu hình netplan

```bash
vim /etc/netplan/50-cloud-init.yaml
```

Trong vim: gõ `:set paste` → Enter (tránh tự thụt lề), `gg` rồi `dG` để xóa nội dung cũ, nhấn `i` và gõ:

```yaml
network:
  version: 2
  ethernets:
    <IFACE>:
      dhcp4: false
      addresses: [<IP>/24]
      routes:
        - to: default
          via: 192.168.200.1
      nameservers:
        addresses: [192.168.200.11, 192.168.200.12]
        search: [paytech.io]
```

Lưu ý:

- YAML **chỉ dùng dấu cách**, không dùng Tab. Mỗi cấp thụt 2 dấu cách.
- Dùng `routes` thay cho `gateway4` (cú pháp cũ, vẫn chạy nhưng báo WARNING).
- Nếu trong `/etc/netplan/` còn file `.yaml` khác cũng cấu hình card này, xóa hoặc đổi đuôi để tránh xung đột.

Phân quyền và áp dụng:

```bash
chmod 600 /etc/netplan/*.yaml
netplan generate
netplan apply
```

Các cảnh báo **có thể bỏ qua**:

- `Cannot call Open vSwitch: ovsdb-server.service is not running` → máy không dùng Open vSwitch.
- `gateway4 has been deprecated` → chỉ xuất hiện nếu vẫn dùng `gateway4`.

Có chữ **ERROR** thì kiểm tra lại thụt lề YAML.

---

## 5. Kiểm tra mạng

```bash
ip -br a                 # <IFACE>  UP  <IP>/24
ip r                     # default via 192.168.200.1 dev <IFACE>
ping -c 3 192.168.200.1  # gateway
ping -c 3 192.168.200.11 # DNS server
resolvectl status        # DNS đang dùng
nslookup git.i-com.vn    # phân giải tên miền
systemctl status ssh     # SSH đang chạy
```

Đạt yêu cầu → SSH vào từ máy cá nhân, làm tiếp các bước sau qua SSH:

```bash
ssh <user>@<IP>
```

---

## 6. Đổi hostname

```bash
hostnamectl set-hostname <HOSTNAME>
sed -i "s/<TÊN_CŨ>/<HOSTNAME>/g" /etc/hosts
cat /etc/hosts           # phải có: 127.0.1.1 <HOSTNAME>
```

Không cho cloud-init đổi lại tên khi reboot:

```bash
echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
```

---

## 7. Làm mới định danh máy (bắt buộc với VM clone từ template)

Các VM clone từ cùng template có chung `machine-id` và SSH host key. Hậu quả: DHCP cấp trùng IP, cảnh báo SSH "host key changed", trùng định danh trong hệ thống giám sát.

Kiểm tra có trùng với template/máy khác không:

```bash
cat /etc/machine-id
```

Nếu trùng, tạo mới:

```bash
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
ln -sf /etc/machine-id /var/lib/dbus/machine-id
```

Tạo lại SSH host key:

```bash
rm -f /etc/ssh/ssh_host_*
dpkg-reconfigure openssh-server
systemctl restart ssh
```

> Sau bước này, máy khác đã từng SSH vào IP này cần xóa key cũ: `ssh-keygen -R <IP>`.

---

## 8. Cài đặt cơ bản

Múi giờ Việt Nam:

```bash
timedatectl set-timezone Asia/Ho_Chi_Minh
```

VMware Tools (để vSphere hiện IP, tắt/khởi động lại VM gọn gàng):

```bash
apt update
apt install -y open-vm-tools
```

Cập nhật bản vá:

```bash
apt upgrade -y
```

---

## 9. Kiểm tra sau khi khởi động lại

```bash
reboot
```

Sau khi máy lên, SSH vào lại và kiểm tra:

```bash
hostnamectl              # Static hostname đúng
ip -br a                 # IP vẫn còn
ip r                     # route mặc định vẫn còn
date                     # đúng giờ +07
cat /etc/netplan/50-cloud-init.yaml   # không bị cloud-init ghi đè
```

Trên vSphere: VM → Summary → **VMware Tools: Running** và hiện đúng IP.

---

## Checklist nhanh

- [ ] Kiểm tra IP chưa bị dùng
- [ ] Xác định tên card mạng
- [ ] Tắt cloud-init quản lý mạng
- [ ] Viết netplan, `chmod 600`, `netplan apply`
- [ ] Ping gateway, DNS; SSH được
- [ ] Đổi hostname + `preserve_hostname: true`
- [ ] Làm mới machine-id và SSH host key
- [ ] Đặt múi giờ, cài `open-vm-tools`, `apt upgrade`
- [ ] Reboot và kiểm tra lại
- [ ] Nếu thay thế máy cũ: cập nhật Jenkins node / DNS / whitelist iptables trên máy đích nếu IP thay đổi