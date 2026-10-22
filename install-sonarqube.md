# Hướng dẫn setup SonarQube + Jenkins (Code Quality trước khi deploy)

Tài liệu mô tả hệ thống kiểm tra chất lượng code đang chạy thực tế: SonarQube trên máy riêng, tích hợp vào pipeline Jenkins để **kiểm tra Lint + SonarQube + Quality Gate trước khi sync code sang các VM chạy app**.

---

## Mục lục

1. [Kiến trúc](#1-kiến-trúc)
2. [Cài SonarQube (máy 192.168.200.195)](#2-cài-sonarqube-máy-192168200195)
3. [Cấu hình SonarQube](#3-cấu-hình-sonarqube)
4. [Cấu hình Jenkins](#4-cấu-hình-jenkins)
5. [Jenkinsfile](#5-jenkinsfile)
6. [Chạy pipeline](#6-chạy-pipeline)
7. [Xem kết quả phân tích](#7-xem-kết-quả-phân-tích)
8. [Xử lý lỗi](#8-xử-lý-lỗi)
9. [Vận hành](#9-vận-hành)
10. [Áp dụng cho job khác](#10-áp-dụng-cho-job-khác)

---

## 1. Kiến trúc

### 1.1. Các thành phần

| Thành phần | Địa chỉ | Ghi chú |
|---|---|---|
| Jenkins controller | `http://192.168.200.190:8080` | Jenkins 2.504.1 |
| SonarQube | `http://192.168.200.195:9000` | SonarQube Community Build, chạy bằng Docker Compose cùng PostgreSQL |
| Jenkins agent `my-slave` | `jenkins-slave` | Ubuntu 20.04, Java mặc định **Java 8**, CPU ảo **không hỗ trợ x86-64-v2** |
| GitLab chứa Jenkinsfile | `http://192.168.200.191/devsecops/devops_portal/...` | Job dùng *Pipeline script from SCM* |
| GitLab chứa source code | `git.i-com.vn` | VD: `emoney/frontend/backoffice` |
| VM ứng dụng | VD: `192.168.200.154` | Nơi code được sync tới |

### 1.2. Luồng pipeline

```
Clone → Lint (PHP syntax) → SonarQube Analysis → Quality Gate → Backup → Deploy
           │                      │                    │
           └──── fail ────────────┴────── fail ────────┴──→ DỪNG, không sync sang VM
```

### 1.3. Luồng dữ liệu giữa các máy

```
 Agent my-slave                      SonarQube (195)                  Jenkins (190)
 ──────────────                      ───────────────                  ─────────────
 sonar-scanner ──── gửi báo cáo ───► :9000
                                     xử lý báo cáo
                                     webhook ─────── POST kết quả ──► :8080/sonarqube-webhook/
                                                                      waitForQualityGate nhận
                                                                      → pass: tiếp tục deploy
                                                                      → fail: dừng pipeline
```

Hai chiều kết nối bắt buộc phải thông:

| Chiều | Mục đích |
|---|---|
| Agent `my-slave` → `192.168.200.195:9000` | Scanner gửi code lên phân tích |
| `192.168.200.195` → `192.168.200.190:8080` | Webhook báo kết quả Quality Gate về Jenkins |

### 1.4. Vì sao setup theo cách này

| Quyết định | Lý do |
|---|---|
| Scanner chạy **trực tiếp trên agent**, không dùng Docker image `sonarsource/sonar-scanner-cli` | Image bản mới (base Amazon Linux) cần CPU hỗ trợ x86-64-v2 → lỗi `Fatal glibc error`. Image bản 5 (Alpine) chỉ có Java 17, server yêu cầu Java 21. |
| Java 21 do **Jenkins tự cài** (Tools → JDK) | Java mặc định của agent là Java 8, đang được Kafka, Debezium… dùng. Không nâng cấp Java hệ thống để tránh ảnh hưởng. Java 21 nằm riêng trong thư mục tools của Jenkins, chỉ dùng cho stage Sonar. |
| Lint PHP chạy bằng Docker image `php:x.x-cli` | Không phải cài PHP lên agent. Image PHP chính thức (Debian) chạy được trên CPU của agent. |

---

## 2. Cài SonarQube (máy 192.168.200.195)

### 2.1. Yêu cầu

- Docker và Docker Compose v2 (`docker compose version`)
- RAM trống tối thiểu **3–4 GB** (SonarQube có chạy Elasticsearch bên trong)

### 2.2. Cấu hình kernel

Elasticsearch yêu cầu tăng giới hạn kernel. Thiếu bước này thì container SonarQube tự tắt ngay sau khi khởi động.

```bash
sudo tee /etc/sysctl.d/99-sonarqube.conf <<EOF
vm.max_map_count=524288
fs.file-max=131072
EOF

sudo sysctl --system
sysctl vm.max_map_count fs.file-max   # Kiểm tra
```

### 2.3. Docker Compose

```bash
sudo mkdir -p /opt/sonarqube
cd /opt/sonarqube
```

File `/opt/sonarqube/docker-compose.yml`:

```yaml
services:
  sonarqube:
    image: sonarqube:community
    container_name: sonarqube
    depends_on:
      - db
    environment:
      SONAR_JDBC_URL: jdbc:postgresql://db:5432/sonar
      SONAR_JDBC_USERNAME: sonar
      SONAR_JDBC_PASSWORD: ${SONAR_DB_PASSWORD}
    ports:
      - "9000:9000"
    volumes:
      - sonarqube_data:/opt/sonarqube/data
      - sonarqube_extensions:/opt/sonarqube/extensions
      - sonarqube_logs:/opt/sonarqube/logs
    ulimits:
      nofile:
        soft: 131072
        hard: 131072
      nproc:
        soft: 8192
        hard: 8192
    restart: unless-stopped

  db:
    image: postgres:16
    container_name: sonarqube-db
    environment:
      POSTGRES_USER: sonar
      POSTGRES_PASSWORD: ${SONAR_DB_PASSWORD}
      POSTGRES_DB: sonar
    volumes:
      - sonarqube_db:/var/lib/postgresql/data
    restart: unless-stopped

volumes:
  sonarqube_data:
  sonarqube_extensions:
  sonarqube_logs:
  sonarqube_db:
```

File mật khẩu database (không commit lên Git):

```bash
echo "SONAR_DB_PASSWORD=<mật_khẩu_mạnh>" > /opt/sonarqube/.env
chmod 600 /opt/sonarqube/.env
```

### 2.4. Khởi động

```bash
cd /opt/sonarqube
docker compose up -d
docker logs -f sonarqube
```

Lần đầu mất khoảng **2–5 phút**. Các dòng `Create index`, `Register rules`, `Register metrics` là bình thường. Chờ tới khi có dòng:

```
SonarQube is operational
```

### 2.5. Đăng nhập lần đầu

1. Mở `http://192.168.200.195:9000`
2. Đăng nhập `admin` / `admin`
3. Đổi mật khẩu theo yêu cầu, lưu vào nơi quản lý mật khẩu của team

---

## 3. Cấu hình SonarQube

### 3.1. Tạo token cho Jenkins

1. Avatar góc phải → **My Account** → tab **Security**
2. *Generate Tokens*:
   - **Name:** `jenkins`
   - **Type:** `Global Analysis Token`
   - **Expires in:** `No expiration` (hoặc theo chính sách của team)
3. **Generate**, sau đó **copy ngay**, vì token chỉ hiển thị một lần.

### 3.2. Tạo webhook về Jenkins

1. **Administration** → **Configuration** → **Webhooks** → **Create**
2. Điền:
   - **Name:** `webhook-sonarqube`
   - **URL:** `http://192.168.200.190:8080/sonarqube-webhook/`
3. **Create**

> ⚠️ URL phải trỏ về **máy Jenkins (190)**, không phải máy SonarQube (195), và phải có dấu `/` ở cuối.
> Kiểm tra: sau mỗi lần build, cột **Last delivery** phải có dấu ✓ xanh. Biểu tượng ◆ đỏ nghĩa là gửi thất bại.

---

## 4. Cấu hình Jenkins

Tất cả thao tác trên giao diện web `http://192.168.200.190:8080`.

### 4.1. Cài plugin

**Manage Jenkins** → **Plugins** → **Available plugins**, cài:

| Plugin | Dùng để |
|---|---|
| **SonarQube Scanner** | `withSonarQubeEnv`, `waitForQualityGate`, tự cài SonarScanner |
| **Eclipse Temurin installer** | Tự cài Java 21 cho scanner |

> Thiếu plugin SonarQube Scanner thì pipeline lỗi ngay từ đầu (`No such DSL method 'withSonarQubeEnv'`), kể cả khi không tick RUN_SONAR.

### 4.2. Lưu token vào Credentials

**Manage Jenkins** → **Credentials** → bảng *Stores scoped to Jenkins* → bấm **(global)** → **+ Add Credentials**:

| Trường | Giá trị |
|---|---|
| Kind | **Secret text** |
| Scope | Global |
| Secret | *(token ở bước 3.1)* |
| ID | `sonarqube-token` |
| Description | `SonarQube token` |

### 4.3. Khai báo SonarQube server

**Manage Jenkins** → **System** → mục **SonarQube servers**:

1. Tick **Environment variables**
2. **Add SonarQube**:

| Trường | Giá trị |
|---|---|
| Name | `sonarqube` |
| Server URL | `http://192.168.200.195:9000` |
| Server authentication token | `SonarQube token` |

3. **Save**

### 4.4. Khai báo SonarScanner

**Manage Jenkins** → **Tools** → mục **SonarQube Scanner installations** → **Add SonarQube Scanner**:

| Trường | Giá trị |
|---|---|
| Name | `sonar-scanner` |
| Install automatically | ✅ |
| Installer | **Install from Maven Central**, bản mới nhất (đang dùng **8.2.0.6438**) |

### 4.5. Khai báo Java 21

Cùng trang **Tools** → mục **JDK installations** → **Add JDK**:

| Trường | Giá trị |
|---|---|
| Name | `jdk21` |
| Install automatically | ✅ |
| Installer | **Add Installer** → **Install from adoptium.net** → bản `jdk-21.x` mới nhất |

**Save**.

> Nếu menu *Add Installer* không có mục "Install from adoptium.net" → chưa cài plugin **Eclipse Temurin installer** (bước 4.1).

Lần build đầu, Jenkins tự tải về agent:
- Scanner → `/home/jenkins/agent/tools/hudson.plugins.sonar.SonarRunnerInstallation/sonar-scanner`
- Java 21 → `/home/jenkins/agent/tools/hudson.model.JDK/jdk21`

Java mặc định của máy (`java -version` → 1.8) **không thay đổi**.

### 4.6. Tóm tắt các tên phải khớp

| Khai báo trên Jenkins | Tên | Dùng trong Jenkinsfile |
|---|---|---|
| System → SonarQube servers | `sonarqube` | `withSonarQubeEnv('sonarqube')` |
| Tools → SonarQube Scanner | `sonar-scanner` | `tool 'sonar-scanner'` |
| Tools → JDK | `jdk21` | `tool 'jdk21'` |
| Credentials | `sonarqube-token` | Gắn vào server `sonarqube`, không gọi trực tiếp |

---

## 5. Jenkinsfile

Áp dụng cho job `vitapay_ecollection_cms_backoffice` (PHP, CodeIgniter, repo `emoney/frontend/backoffice`). Jenkinsfile nằm ở repo `devsecops/devops_portal/vitapay_ecollection_cms_backoffice`, nhánh `main`.

### 5.1. Tham số

```groovy
booleanParam(name: 'RUN_LINT',  defaultValue: false, description: 'Check lint (lỗi cú pháp PHP)')
booleanParam(name: 'RUN_SONAR', defaultValue: false, description: 'Phân tích SonarQube + chờ Quality Gate')
```

`RUN_FULL` chạy tất cả: Clone → Lint → SonarQube → Quality Gate → Backup → Deploy.

### 5.2. Biến môi trường

```groovy
environment {
    DEST_PATH_SOURCE  = '/home/jenkins/agent/workspace/vitapay_ecollection_cms_backoffice/backoffice'
    PHP_IMAGE         = 'php:7.4-cli'   // Đổi cho đúng phiên bản PHP trên VM (php -v)
    SONAR_PROJECT_KEY = 'vitapay_ecollection_cms_backoffice'
    SONAR_EXCLUSIONS  = 'vendor/**,vendors/**,system/**,phpExcel/**,application/libraries/PHPExcel/**,**/logs/**,**/*.min.js,**/*.min.css,.sonar/**,.scannerwork/**'
}
```

**`SONAR_EXCLUSIONS`** loại các thư mục không phải code của team, để báo cáo không bị lẫn lỗi của thư viện và stage Sonar chạy nhanh hơn:

| Pattern | Lý do loại |
|---|---|
| `vendor/**`, `vendors/**` | Thư viện bên thứ ba (Composer, jquery, bootstrap, pdfmake…) |
| `system/**` | Core của CodeIgniter |
| `phpExcel/**`, `application/libraries/PHPExcel/**` | Thư viện PHPExcel |
| `**/*.min.js`, `**/*.min.css` | File đã nén |
| `.sonar/**`, `.scannerwork/**` | Thư mục tạm của scanner |

### 5.3. Stage Lint: kiểm tra cú pháp PHP

```groovy
stage('Lint (PHP syntax)') {
    when { expression { !params.ROLLBACK && (params.RUN_FULL || params.RUN_LINT) } }
    steps {
        sh '''
            docker run --rm -v "$DEST_PATH_SOURCE:/app:ro" -w /app "$PHP_IMAGE" sh -c '
                find . -type f -name "*.php" -not -path "./vendor/*" -not -path "./system/*" -print0 \
                  | xargs -0 -n1 -P4 php -l > /tmp/lint.log 2>&1
                rc=$?
                grep -v "^No syntax errors" /tmp/lint.log || true
                if [ "$rc" -ne 0 ]; then
                    echo "❌ Có lỗi cú pháp PHP → dừng pipeline, KHÔNG deploy."
                    exit 1
                fi
                echo "✅ Không có lỗi cú pháp PHP."
            '
        '''
    }
}
```

- Chạy `php -l` cho từng file `.php` (4 tiến trình song song), mount code chỉ đọc (`:ro`)
- Có ít nhất 1 file lỗi cú pháp → `xargs` trả mã khác 0 → stage fail
- Log chỉ in các file có lỗi

### 5.4. Stage SonarQube Analysis

```groovy
stage('SonarQube Analysis') {
    when { expression { !params.ROLLBACK && (params.RUN_FULL || params.RUN_SONAR) } }
    steps {
        script {
            env.SCANNER_HOME    = tool 'sonar-scanner'
            env.SONAR_JAVA_HOME = tool 'jdk21'
        }
        dir('backoffice') {
            withSonarQubeEnv('sonarqube') {
                sh '''
                    export JAVA_HOME="$SONAR_JAVA_HOME"
                    export PATH="$JAVA_HOME/bin:$PATH"
                    java -version

                    "$SCANNER_HOME/bin/sonar-scanner" \
                      -Dsonar.scanner.skipJreProvisioning=true \
                      -Dsonar.projectKey="$SONAR_PROJECT_KEY" \
                      -Dsonar.projectName="$SONAR_PROJECT_KEY" \
                      -Dsonar.projectVersion="$BRANCH-$BUILD_NUMBER" \
                      -Dsonar.sources=. \
                      -Dsonar.exclusions="$SONAR_EXCLUSIONS" \
                      -Dsonar.sourceEncoding=UTF-8
                '''
            }
        }
    }
}
```

| Dòng | Ý nghĩa |
|---|---|
| `tool 'sonar-scanner'` / `tool 'jdk21'` | Lấy đường dẫn scanner và Java 21 do Jenkins tự cài (lần đầu sẽ tải về) |
| `dir('backoffice')` | Chạy scanner trong thư mục code vừa clone |
| `withSonarQubeEnv('sonarqube')` | Nạp URL server + token. Scanner tự đọc, không cần truyền `-Dsonar.host.url` / `-Dsonar.token` |
| `export JAVA_HOME=...` | Scanner dùng Java 21; chỉ có hiệu lực trong lệnh `sh` này |
| `skipJreProvisioning=true` | Đã có Java 21, không để scanner tự tải Java từ server |
| `java -version` | In ra log để dễ kiểm tra (phải là **21**) |

Project trên SonarQube **tự được tạo** ở lần phân tích đầu tiên, không cần tạo tay.

### 5.5. Stage Quality Gate

```groovy
stage('Quality Gate') {
    when { expression { !params.ROLLBACK && (params.RUN_FULL || params.RUN_SONAR) } }
    steps {
        timeout(time: 10, unit: 'MINUTES') {
            waitForQualityGate abortPipeline: true
        }
    }
}
```

- Jenkins chờ SonarQube báo kết quả qua webhook (bước 3.2)
- `abortPipeline: true`: Quality Gate **FAILED** thì dừng pipeline, **không** Backup/Deploy
- Quality Gate mặc định **Sonar way** chỉ xét **code mới**, nên code cũ nhiều lỗi vẫn pass

### 5.6. Không deploy file thừa lên VM

```bash
rsync -az -e "ssh -o StrictHostKeyChecking=no" \
  --exclude='constants.php' \
  --exclude='.git' \
  --exclude='.sonar' \
  --exclude='.scannerwork' \
  "$DEST_PATH_SOURCE/" "root@$REMOTE_SERVER:$DEST_PATH_DEST"
```

> Không deploy `.git` vào web root, vì có nguy cơ lộ toàn bộ source code qua trình duyệt.

---

## 6. Chạy pipeline

### 6.1. Lần đầu sau khi đổi Jenkinsfile

1. Commit và push Jenkinsfile lên nhánh `main`
2. Bấm **Build** 1 lần để Jenkins nạp tham số mới (sẽ có ô `RUN_LINT`, `RUN_SONAR`)
3. **Build with Parameters** → tick **RUN_CLONE + RUN_LINT + RUN_SONAR** (chưa deploy)

### 6.2. Dấu hiệu chạy đúng trong Console Output

| Stage | Dòng cần thấy |
|---|---|
| Lint | `✅ Không có lỗi cú pháp PHP.` |
| SonarQube | `java -version` in ra **21**, sau đó `ANALYSIS SUCCESSFUL` và `EXECUTION SUCCESS` |
| Quality Gate | `SonarQube task '...' status is 'SUCCESS'` và `Quality gate status: OK` |

Lần build đầu lâu hơn vì Jenkins phải tải scanner và Java 21 về agent.

### 6.3. Deploy

Ổn định rồi thì dùng **RUN_FULL** cho các lần deploy bình thường.

---

## 7. Xem kết quả phân tích

### 7.1. Xem lỗi pipeline: Jenkins

- Job → số build → **Console Output**: log đầy đủ. Kéo xuống dòng `ERROR:` cuối cùng rồi **dò ngược lên** tìm lỗi đầu tiên.
- Job → **Stages**: xem stage nào xanh, stage nào đỏ, bấm vào stage đỏ để xem log riêng.
- Trang build có link **SonarQube** để chuyển thẳng sang dashboard của project.

### 7.2. Xem lỗi code: SonarQube

`http://192.168.200.195:9000` → **Projects** → `vitapay_ecollection_cms_backoffice`

**Tab Overview**
- **New Code:** lỗi trong code mới so với lần phân tích trước (lần đầu trống)
- **Overall Code:** toàn bộ lỗi của dự án

| Nhóm | Ý nghĩa |
|---|---|
| Security | Lỗ hổng bảo mật (SQL injection, XSS…) |
| Reliability | Bug, code có thể chạy sai |
| Maintainability | Code smell: khó đọc, khó bảo trì |
| Security Hotspots | Code nhạy cảm bảo mật, cần người kiểm tra |
| Duplications | Tỷ lệ code lặp |

**Tab Issues:** danh sách lỗi chi tiết, lọc theo *Software Quality*, *Severity*, *Directory*. Bấm vào một lỗi để xem dòng code bị lỗi và tab **"Why is this an issue?"** (giải thích và cách sửa).

**Tab Security Hotspots:** các đoạn cần dev xem lại (SQL ghép chuỗi, mật khẩu viết cứng, cookie thiếu cờ bảo mật…).

**Tab Activity:** lịch sử các lần phân tích, so sánh qua các build.

### 7.3. Thứ tự ưu tiên xử lý

1. **Security Hotspots** mức High, rồi **Issues** lọc *Security*
2. **Issues** lọc *Reliability* + *Blocker/High*
3. Maintainability xử lý dần

---

## 8. Xử lý lỗi

Các lỗi đã gặp thực tế khi setup và cách xử lý:

| Hiện tượng | Nguyên nhân | Cách xử lý |
|---|---|---|
| Container `sonarqube` tự tắt, log có `vm.max_map_count [65530] is too low` | Chưa cấu hình kernel | Làm bước 2.2, rồi `docker compose up -d` |
| Không mở được trang `:9000` | SonarQube chưa khởi động xong | `docker logs -f sonarqube`, chờ `SonarQube is operational` |
| Trang Projects trống, chỉ có các nút "Import from…" / "Create a local project" | Chưa có lần scan nào thành công | Không cần tạo tay, project tự xuất hiện sau lần scan đầu |
| `No such DSL method 'withSonarQubeEnv'` | Chưa cài plugin SonarQube Scanner | Bước 4.1 |
| `Fatal glibc error: CPU does not support x86-64-v2`, exit code 127 | Dùng Docker image scanner bản mới; CPU ảo của agent thiếu x86-64-v2 | Không dùng Docker image, chạy scanner trên agent (bước 4.4). Lâu dài: nâng EVC mode / kiểu CPU của VM trên vSphere |
| `Java 17 is not supported. Please upgrade to Java 21` | Dùng image scanner bản 5 (Java 17) | Chạy scanner bản mới trên agent với Java 21 (bước 4.4, 4.5) |
| `UnsupportedClassVersionError ... class file version 55.0 ... up to 52.0` | Scanner chạy bằng Java 8 mặc định của agent | Khai báo `jdk21` (bước 4.5), stage Sonar phải có `tool 'jdk21'` và `export JAVA_HOME` |
| Tools → JDK không có "Install from adoptium.net" | Chưa cài plugin Eclipse Temurin installer | Bước 4.1 |
| `... does not have an installation named "sonar-scanner"` hoặc `"jdk21"` | Chưa khai báo ở Tools hoặc sai tên | Bước 4.4 / 4.5, kiểm tra tên ở bảng 4.6 |
| Log có `SONAR_HOST_URL=http://<sai IP>:9000`, scanner không kết nối được | Server URL trong Jenkins sai | Bước 4.3: `http://192.168.200.195:9000` |
| Scanner báo `401` / `Not authorized` | Token sai hoặc chưa gắn | Tạo lại token (3.1), cập nhật credential `sonarqube-token` |
| Stage Quality Gate đứng ở `IN_PROGRESS` tới khi hết timeout | Webhook sai URL hoặc không gửi được | Bước 3.2. Xem cột **Last delivery** (◆ đỏ = lỗi, bấm ⋮ xem chi tiết). URL phải là máy **190**, không phải 195 |
| Kiểm tra SonarQube đã xử lý xong báo cáo chưa | — | **Administration → Projects → Background Tasks**, hoặc mở link `api/ce/task?id=...` in trong log |
| Lint báo lỗi ở cú pháp hợp lệ | `PHP_IMAGE` cũ hơn PHP trên VM | Đổi `PHP_IMAGE` cho đúng (`php -v` trên VM) |
| Stage Sonar chạy rất lâu, báo cáo nhiều lỗi lạ | Đang quét cả thư viện bên thứ ba | Bổ sung `SONAR_EXCLUSIONS` (bước 5.2) |

### Kiểm tra kết nối nhanh

```bash
# Trên agent my-slave: phải ra "status":"UP"
curl -s http://192.168.200.195:9000/api/system/status

# Trên máy SonarQube (195): có phản hồi HTTP là thông (không bị treo / refused)
curl -i -X POST http://192.168.200.190:8080/sonarqube-webhook/ -H "Content-Type: application/json" -d '{}'
```

---

## 9. Vận hành

### 9.1. Lệnh thường dùng (trên máy 195)

```bash
cd /opt/sonarqube

docker compose ps            # Trạng thái
docker compose logs -f       # Xem log
docker compose restart       # Khởi động lại
docker compose down          # Dừng (GIỮ dữ liệu)
```

> ⚠️ **Không** dùng `docker compose down -v`, `docker volume prune`, `docker system prune --volumes`, vì các lệnh này **xoá toàn bộ dữ liệu SonarQube** (database, lịch sử phân tích).

### 9.2. Backup database

```bash
docker exec sonarqube-db pg_dump -U sonar sonar | gzip > /opt/sonarqube/backup_$(date +%Y%m%d).sql.gz
```

### 9.3. Nâng cấp SonarQube

1. Backup database (9.2)
2. `docker compose pull && docker compose up -d`
3. Mở `http://192.168.200.195:9000/setup` nếu SonarQube yêu cầu migrate database
4. Nếu server mới yêu cầu Java cao hơn cho scanner: thêm JDK mới ở **Tools → JDK installations** và đổi tên trong `tool '...'`

### 9.4. Nâng cấp scanner / Java

**Manage Jenkins → Tools** → đổi Version của `sonar-scanner` hoặc `jdk21` → **Save**. Lần build sau Jenkins tự tải bản mới.

---

## 10. Áp dụng cho job khác

Với job PHP khác, copy 3 stage **Lint**, **SonarQube Analysis**, **Quality Gate** cùng 2 tham số `RUN_LINT`, `RUN_SONAR`, rồi đổi:

| Biến | Đổi thành |
|---|---|
| `SONAR_PROJECT_KEY` | Tên project mới (duy nhất trên SonarQube) |
| `DEST_PATH_SOURCE` | Đường dẫn code trong workspace của job mới |
| `dir('...')` trong stage Sonar | Tên thư mục clone của job mới |
| `SONAR_EXCLUSIONS` | Thư mục thư viện / framework của dự án đó |
| `PHP_IMAGE` | Phiên bản PHP của dự án |

Phần cấu hình Jenkins (plugin, credential, server, Tools) và SonarQube (token, webhook) **dùng chung**, không phải làm lại.

### Gợi ý tiếp theo

- Tạo **Quality Gate riêng** cho team (*Quality Gates → Create*), ví dụ: không cho phép lỗi Security/Reliability mức Blocker/High trên code mới
- Thêm `-Dsonar.python.version=3` nếu dự án có file Python, để bỏ cảnh báo trong log
- Nâng EVC mode / kiểu CPU của VM agent trên vSphere lên mức hỗ trợ x86-64-v2, để sau này dùng được các Docker image mới