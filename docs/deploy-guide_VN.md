# Hướng dẫn Cập nhật - Build Docker - Triển khai CLIProxyAPI

> Guide này áp dụng cho hai chế độ: **Stand‑alone** (`docker-compose.yml`) và **Cluster** (`docker-compose.cluster.yml`).

## Mục lục

- [1. Yêu cầu trước](#1-yêu-cầu-trước)
- [2. Cập nhật mã nguồn (CLI Proxy)](#2-cập-nhật-mã-nguồn-cli-proxy)
- [3. Build lại Docker image](#3-build-lại-docker-image)
- [4. Triển khai](#4-triển-khai)
- [5. Kiểm tra sau triển khai](#5-kiểm-tra-sau-triển-khai)
- [6. Phương án thay thế: pull image từ registry](#6-phương-án-thay-thế-pull-image-từ-registry)
- [7. Phục hồi (Rollback)](#7-phục-hồi-rollback)
- [8. Khắc phục sự thường gặp](#8-khắc-phục-sự-thường-gặp)

---

## 1. Yêu cầu trước

| Công cụ | Phiên bản tối thiểu | Kiểm tra |
|---------|---------------------|----------|
| Git     |任意                  | `git --version` |
| Docker Engine | 24.0          | `docker --version` |
| Docker Compose | v2.20        | `docker compose version` |

> Repo: `https://github.com/router-for-me/CLIProxyAPI.git`, branch mặc định: `main`.

---

## 2. Cập nhật mã nguồn (CLI Proxy)

```bash
# Chuyển về thư mục repo
cd /path/to/CLIProxyAPI

# Đảm bảo đang ở branch main
git checkout main

# Kéo code mới nhất
git pull origin main
```

### Kiểm tra version và tag

```bash
# Tag gần nhất (Ví dụ: v7.2.115)
git describe --tags --abbrev=0

# Commit hiện tại
git rev-parse --short HEAD
```

> Nếu muốn checkout một tag cụ thể:

```bash
# Ví dụ: checkout tag v7.2.115
git checkout v7.2.115
```

---

## 3. Build lại Docker image

### 3.1. Xoá image cũ (tuỳ chọn, đảm bảo build sạch)

```bash
# Stand-alone
docker rmi eceasy/cli-proxy-api:latest -f

# Nếu đã build image nội bộ (build local) trước đó
docker images | grep cli-proxy-api
# docker rmi <image-id> -f
```

### 3.2. Build image mới

> Các biến `VERSION`, `COMMIT`, `BUILD_DATE` được truyền qua `ldflags` vào binary Go (xem `Dockerfile:17`).

```bash
# Stand-alone (docker-compose.yml)
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev) \
COMMIT=$(git rev-parse --short HEAD) \
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
docker compose build
```

```bash
# Cluster (docker-compose.cluster.yml) — chỉ cổng 8317
VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo dev) \
COMMIT=$(git rev-parse --short HEAD) \
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
docker compose -f docker-compose.cluster.yml build
```

### 3.3. Kiểm tra image đã build

```bash
docker images | grep cli-proxy-api
docker image inspect eceasy/cli-proxy-api:latest --format '{{.Created}}'
```

---

## 4. Triển khai

### 4.1. Stand-alone

```bash
# Dừng container cũ (volume được giữ nguyên)
docker compose down

# Khởi động với image mới
docker compose up -d
```

Các volume được mount (xem `docker-compose.yml:24-28`):

| Volume host                     | Container path                | Mục đích |
|---------------------------------|-------------------------------|----------|
| `./config.yaml` (hoặc `CLI_PROXY_CONFIG_PATH`) | `/CLIProxyAPI/config.yaml` | File cấu hình |
| `./auths` (hoặc `CLI_PROXY_AUTH_PATH`)         | `/root/.cli-proxy-api`     | Token auth |
| `./logs` (hoặc `CLI_PROXY_LOG_PATH`)           | `/CLIProxyAPI/logs`        | Log runtime |
| `./plugins` (hoặc `CLI_PROXY_PLUGIN_PATH`)     | `/CLIProxyAPI/plugins`     | Plugin |

Cổng expose (`docker-compose.yml:17-23`): `8317`, `8085`, `1455`, `54545`, `51121`, `11451`.

### 4.2. Cluster

> Yêu cầu biến môi trường `HOME_JWT` (xem `docker-compose.cluster.yml:13`).

```bash
# Dừng container cũ
docker compose -f docker-compose.cluster.yml down

# Khởi động, truyền HOME_JWT
HOME_JWT="<your-jwt-token>" \
docker compose -f docker-compose.cluster.yml up -d
```

> Cluster mode chỉ expose cổng `8317` và không mount `config.yaml`. Cấu hình qua cờ `-home-jwt`.

### 4.3. Override image bằng biến môi trường 

Nếu muốn dùng image tag khác (ví dụ `v7.2.115`) thay vì `latest`:

```bash
CLI_PROXY_IMAGE=eceasy/cli-proxy-api:v7.2.115 docker compose up -d
```

---

## 5. Kiểm tra sau triển khai

```bash
# Trạng thái container
docker compose ps

# Log realtime (50 dòng cuối)
docker compose logs -f --tail=50 cli-proxy-api

# Kiểm tra port lắng nghe
docker compose exec cli-proxy-api netstat -tlnp 2>/dev/null || docker compose exec cli-proxy-api ss -tlnp

# Test API endpoint
curl http://localhost:8317/v1/models
```

---

## 6. Phương án thay thế: pull image từ registry

Nếu không cần build local mà muốn dùng image đã publish lên registry:

```bash
# Stand-alone
docker compose pull
docker compose up -d

# Cluster
docker compose -f docker-compose.cluster.yml pull
HOME_JWT="<your-jwt-token>" docker compose -f docker-compose.cluster.yml up -d
```

> `pull_policy: always` trong compose file đảm bảo luôn kéo image mới nhất mỗi khi `up`.

---

## 7. Phục hồi (Rollback)

### 7.1. Rollback code

```bash
# Xem lịch sử commit
git log --oneline -20

# Checkout commit/tag cũ
git checkout <commit-hash-or-tag>

# Build lại và deploy
docker compose down
VERSION=$(git describe --tags --always --dirty 2>/dev/null) \
COMMIT=$(git rev-parse --short HEAD) \
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
docker compose build
docker compose up -d
```

### 7.2. Rollback image tag

```bash
CLI_PROXY_IMAGE=eceasy/cli-proxy-api:v7.2.114 docker compose up -d
```

---

## 8. Khắc phục sự thường gặp

| Triệu chứng | Nguyên nhân | Khắc phục |
|-------------|-------------|-----------|
| `port is already allocated` | Cổng bị chiếm bởi process khác | `docker compose down` rồi kiểm tra `netstat -tlnp \| grep 8317` |
| `permission denied` khi mount volume | Quyền thư mục `./auths` / `./logs` | `chmod -R 755 ./auths ./logs ./plugins` (Linux) |
| `config.yaml not found` | Thiếu file config | Tạo từ template: `cp config.example.yaml config.yaml` |
| Container exit ngay sau khi start | Config sai hoặc thiếu token | `docker compose logs cli-proxy-api` để xem lỗi chi tiết |
| Build chậm / fail | Cache Docker đầy | `docker builder prune -f` rồi build lại |
| `HOME_JWT is required` (cluster) | Thiếu biến `HOME_JWT` | Truyền `HOME_JWT=...` khi `docker compose up` |

---

> **Lưu ý**: Sau khi cập nhật, nếu schema config có thay đổi, so sánh `config.example.yaml` (mới kéo về) với `config.yaml` hiện tại để cập nhật các trường mới.