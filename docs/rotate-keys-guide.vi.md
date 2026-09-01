# Tài liệu Rotate Key — CLIProxyAPI (proxy.hatujsc.org)

> Hướng dẫn xoay vòng (rotate) 2 loại token: **Proxy API Key** và **Cloudflare Tunnel Token**.
> Áp dụng cho hệ thống CLIProxyAPI chạy Docker trên máy local, expose qua Cloudflare Tunnel.

---

## 1. Tổng quan hệ thống & 3 loại "chìa khoá"

```
Client (máy khác / VS Code / CLI)
   │  https://proxy.hatujsc.org/v1   +  Bearer <PROXY_API_KEY>
   ▼
Cloudflare Edge (HTTPS tự động)
   │  Tunnel: 5dcb5039-eb35-465d-803b-628b3e173580  (<TUNNEL_TOKEN>)
   ▼
Container: cliproxy-cloudflared  (--network host)
   ▼
localhost:8317 → Container: cliproxyapi-standalone (CLIProxyAPI)
   ▼
166 tài khoản Codex OAuth (auths/)
```

| # | Token | Dùng để làm gì | Nằm ở đâu | Ai đọc |
|---|-------|----------------|-----------|--------|
| 1 | **PROXY_API_KEY**<br>(`sk-proxy-...`) | Client xác thực khi gọi API | `E:\cliproxyapi-standalone\.env` → biến `PROXY_API_KEY` | Server (qua `${PROXY_API_KEY}` trong `config.yaml`) |
| 2 | **TUNNEL_TOKEN**<br>(`eyJhIjoi...`) | Kết nối Cloudflare Tunnel | `.env` → biến `CLOUDFLARED_TUNNEL_TOKEN` (chỉ để tham chiếu) + command line container connector | Container `cliproxy-cloudflared` |
| 3 | **Management secret-key** | Quản trị web UI / API quản lý | `config.yaml` → `remote-management.secret-key` (bcrypt) | Server |

**Từng bị trùng:** trước đây PROXY_API_KEY = TUNNEL_TOKEN (đã tách ngày 31/08/2026).
**Nguyên tắc:** 2 token này phải luôn KHÁC NHAU.

### Các máy client hiện tại

| Máy | Địa chỉ | User | File config Codex |
|-----|---------|------|-------------------|
| Local (server) | localhost | Admin | `C:\Users\Admin\.codex\{config.toml, auth.json}` |
| Remote | `100.72.158.108` (SSH key: `~\.ssh\home_ed25519`, user `skyline`) | SkyLine | `C:\Users\SkyLine\.codex\{config.toml, auth.json}` |

Mỗi máy client có **2 nơi** chứa PROXY_API_KEY:
1. `~/.codex/auth.json` → `OPENAI_API_KEY` (VS Code extension đọc)
2. Biến môi trường `CLIPROXY_API_KEY` (Codex CLI đọc — do `env_key` trong config.toml)

---

## 2. Khi nào cần rotate?

| Tình huống | Rotate cái gì |
|------------|---------------|
| Key bị lộ (gửi nhầm chat, commit, screenshot...) | PROXY_API_KEY ngay lập tức |
| Định kỳ an toàn (3-6 tháng/lần) | Cả hai |
| Nghi ngờ tunnel token lộ | TUNNEL_TOKEN ngay lập tức |
| Cho người mới dùng / thu hồi quyền của ai đó | PROXY_API_KEY |
| Thay đổi cấu trúc tunnel / chuyển máy chủ | TUNNEL_TOKEN |

---

## 3. Rotate PROXY_API_KEY (key client)

> ⏱ Tổng thời gian: ~5 phút. Downtime: vài giây lúc tạo lại container.

### ✅ Checklist nhanh — làm GÌ, ở ĐÂU, trên MÁY NÀO

Làm **đúng thứ tự** dưới đây. Chi tiết từng bước xem các mục Bước 1 → Bước 5 bên dưới.

| # | Máy | Vị trí | Việc cần làm | Lệnh/File |
|---|-----|--------|--------------|-----------|
| 1 | **SERVER**<br>(máy chạy Docker) | `E:\cliproxyapi-standalone\.env` | Sinh key mới, thay dòng `PROXY_API_KEY=`<br>**Ghi nhớ prefix 20 ký tự của key mới** | PowerShell script (Bước 1) |
| 2 | **SERVER** | Docker | **Tạo lại** container `cliproxyapi-standalone`<br>⚠️ `docker restart` KHÔNG đủ — env-file chỉ nạp lúc tạo | `docker rm -f` + `docker run` (Bước 2) |
| 3 | **LOCAL client**<br>(máy server cũng là client) | `C:\Users\Admin\.codex\auth.json` | Cập nhật `OPENAI_API_KEY` = key mới | PowerShell (Bước 3) |
| 4 | **LOCAL client** | Biến môi trường User | Cập nhật `CLIPROXY_API_KEY` (cho Codex CLI) | `setx` / `SetEnvironmentVariable` (Bước 3) |
| 5 | **LOCAL client** | VS Code | **Restart hoàn toàn** (extension nạp key lúc khởi động) | Đóng hết cửa sổ → mở lại |
| 6 | **REMOTE client**<br>`100.72.158.108` | `C:\Users\SkyLine\.codex\auth.json` | Copy `auth.json` mới qua SCP | scp qua SSH key `home_ed25519` (Bước 4A) |
| 7 | **REMOTE client** | Biến môi trường User | Cập nhật `CLIPROXY_API_KEY` qua SSH | PowerShell full-path (Bước 4A) |
| 8 | **REMOTE client — DESKTOP** | Explorer / cửa sổ pwsh | ⚠️ **Re-broadcast env từ desktop** (SSH-set không tới được Explorer!) + mở cửa sổ mới + so prefix key | (Bước 4B) |
| 9 | **REMOTE client** | VS Code | **Restart hoàn toàn** (hoặc taskkill Code.exe remote) | (Bước 4C) |
| 10 | **BẤT KỲ** | Kiểm chứng | Server: 200/401/200 — Client remote: **so prefix 20 ký tự + gọi API thật** (không tin length!) | (Bước 5A + 5B) |
| 11 | **REMOTE client** | VS Code extension | Nếu vẫn 401 dù CLI OK → nâng env lên **Machine scope** → `taskkill /F /IM Code.exe /T` → mở lại VS Code | (Bước 5C) |

> 📌 **Không cần đụng:** tunnel token, container `cliproxy-cloudflared`, `config.yaml`, Cloudflare dashboard, auth files (`auths/`). Client bên thứ 3 khác (OpenCode, Cursor...) chỉ cần cập nhật key tại chỗ cấu hình của chúng.

### Bước 1 — Sinh key mới + cập nhật `.env`

Chạy trên **máy server** (PowerShell tại `E:\cliproxyapi-standalone`):

```powershell
$bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$newKey = "sk-proxy-" + ([Convert]::ToHexString($bytes).ToLower())
$tunnelToken = (Get-Content ".env" | Where-Object { $_ -match "^CLOUDFLARED_TUNNEL_TOKEN=" }) -replace "^CLOUDFLARED_TUNNEL_TOKEN=", ""

@"
# Local secrets - DO NOT COMMIT (already in .gitignore)

# API key clients use to authenticate with the proxy (referenced in config.yaml as `${PROXY_API_KEY}`)
PROXY_API_KEY=$newKey

# Cloudflare tunnel token - ONLY for the cliproxy-cloudflared connector container
CLOUDFLARED_TUNNEL_TOKEN=$tunnelToken
"@ | Set-Content ".env" -Encoding ASCII

Write-Output "KEY MOI (copy de cap nhat client):"
Write-Output $newKey
```

> ⚠️ **Lưu ý quan trọng:** `docker restart` **KHÔNG** đọc lại `--env-file`.
> env-file chỉ được nạp lúc **tạo** container → bắt buộc phải `rm` + `run` lại (Bước 2).

### Bước 2 — Tạo lại container server

> ⚠️ **Lưu ý PowerShell:** các lệnh nhiều dòng dưới đây dùng backtick `` ` `` (phím dưới Esc) —
> ký tự xuống dòng của PowerShell. KHÔNG dùng `^` (chỉ dùng được trong CMD).
> Hoặc paste nguyên 1 dòng lệnh ở khối "một dòng" bên dưới.

```bash
docker rm -f cliproxyapi-standalone
```

**Phiên bản 1 dòng (paste nguyên khối):**

```powershell
docker run -d --name cliproxyapi-standalone --restart unless-stopped -p 1455:1455 -p 8317:8317 -p 18085:8085 -v "E:\cliproxyapi-standalone\assets:/CLIProxyAPI/assets" -v "E:\cliproxyapi-standalone\config.yaml:/CLIProxyAPI/config.yaml" -v "E:\cliproxyapi-standalone\logs:/CLIProxyAPI/logs" -v "E:\cliproxyapi-standalone\auths:/root/.cli-proxy-api" --env-file "E:\cliproxyapi-standalone\.env" cliproxyapi-local:latest
```

**Phiên bản nhiều dòng (PowerShell, dùng backtick):**

```powershell
docker run -d --name cliproxyapi-standalone --restart unless-stopped `
  -p 1455:1455 -p 8317:8317 -p 18085:8085 `
  -v "E:\cliproxyapi-standalone\assets:/CLIProxyAPI/assets" `
  -v "E:\cliproxyapi-standalone\config.yaml:/CLIProxyAPI/config.yaml" `
  -v "E:\cliproxyapi-standalone\logs:/CLIProxyAPI/logs" `
  -v "E:\cliproxyapi-standalone\auths:/root/.cli-proxy-api" `
  --env-file "E:\cliproxyapi-standalone\.env" `
  cliproxyapi-local:latest
```

Chờ ~10 giây, kiểm tra: `docker logs --tail 5 cliproxyapi-standalone` → phải thấy "166 clients".

### Bước 3 — Cập nhật client MÁY LOCAL

```powershell
$newKey = (Get-Content "E:\cliproxyapi-standalone\.env" | Where-Object { $_ -match "^PROXY_API_KEY=" }) -replace "^PROXY_API_KEY=", ""

# 1. auth.json (cho VS Code extension)
@{ OPENAI_API_KEY = $newKey } | ConvertTo-Json | Set-Content "$env:USERPROFILE\.codex\auth.json" -Encoding UTF8

# 2. Biến môi trường (cho Codex CLI)
[Environment]::SetEnvironmentVariable("CLIPROXY_API_KEY", $newKey, "User")
$env:CLIPROXY_API_KEY = $newKey
```

**Restart VS Code hoàn toàn** (extension nạp key lúc khởi động).

### Bước 4 — Cập nhật client MÁY REMOTE (100.72.158.108)

> ⚠️⚠️ **BẪY WINDOWS QUAN TRỌNG NHẤT — đọc trước khi làm:**
>
> Script dưới đây set biến môi trường qua **phiên SSH**. Broadcast cập nhật env
> từ phiên SSH **KHÔNG TỚI được Explorer của phiên desktop** trên máy remote.
> Hậu quả: registry (User scope) đã đúng key mới, NHƯNG mọi cửa sổ pwsh/terminal
> mở từ **desktop** máy remote vẫn kế thừa key cũ từ Explorer → **401 dù mọi thứ
> có vẻ đúng** (đã từng gặp thật: key rotate 2 lần cùng dài 73 ký tự, check length
> = 73 tưởng là OK nhưng vẫn 401).
>
> **Do đó BẮT BUỘC làm thêm 4B và 4C sau khi chạy script 4A.**

#### 4A — Script tự động (chạy trên SERVER)

```powershell
# Tạo auth.json tạm với key mới
$newKey = (Get-Content "E:\cliproxyapi-standalone\.env" | Where-Object { $_ -match "^PROXY_API_KEY=" }) -replace "^PROXY_API_KEY=", ""
@{ OPENAI_API_KEY = $newKey } | ConvertTo-Json | Set-Content "$env:TEMP\auth.json" -Encoding UTF8

$ssh = "C:\Windows\System32\OpenSSH\ssh.exe"
$scp = "C:\Windows\System32\OpenSSH\scp.exe"
$sshArgs = @("-o","BatchMode=yes","-i","$env:USERPROFILE\.ssh\home_ed25519")

# 1. Copy auth.json sang máy remote
& $scp @sshArgs "$env:TEMP\auth.json" "skyline@100.72.158.108:C:/Users/SkyLine/.codex/auth.json"

# 2. Set biến môi trường trên máy remote (qua SSH — chỉ cập nhật registry)
& $ssh @sshArgs "skyline@100.72.158.108" 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -Command "$k = (Get-Content ''C:\Users\SkyLine\.codex\auth.json'' -Raw | ConvertFrom-Json).OPENAI_API_KEY; [Environment]::SetEnvironmentVariable(''CLIPROXY_API_KEY'', $k, ''User''); Write-Output (''key '' + $k.Length + '' chars'')"'

Remove-Item "$env:TEMP\auth.json"
```

#### 4B — Làm mới env phía DESKTOP máy remote (chống bẫy Windows ở trên)

Làm trực tiếp trên **desktop máy remote** (RDP/đứng tại máy), mở PowerShell:

```powershell
# 1. Re-broadcast env từ phiên desktop → Explorer cập nhật
[Environment]::SetEnvironmentVariable("CLIPROXY_API_KEY", (Get-Content "$env:USERPROFILE\.codex\auth.json" | ConvertFrom-Json).OPENAI_API_KEY, "User")

# 2. Đóng TẤT CẢ cửa sổ pwsh/Windows Terminal/VS Code đang mở, rồi mở cửa sổ pwsh MỚI

# 3. Xác nhận cửa sổ mới cầm đúng key (so prefix với .env server!)
$env:CLIPROXY_API_KEY.Substring(0, 20)
# Phải ra prefix giống key mới trong .env (VD: sk-proxy-4fd3455dfda)
```

> 💡 Cách đơn giản nhất thay cho 4B: **restart máy remote** (log off/on cũng được)
> — Explorer nạp lại env từ registry, không cần re-broadcast.

#### 4C — Restart VS Code trên máy remote

Đóng hết cửa sổ Code.exe rồi mở lại. Extension nạp `auth.json` lúc khởi động.

### Bước 5 — Kiểm chứng

> 🔑 **Nguyên tắc vàng:** kiểm chứng bằng **so prefix key + gọi API thật**,
> KHÔNG dùng độ dài key — nếu rotate nhiều lần, các key có thể cùng độ dài
> (VD 2 key liên tiếp đều 73 ký tự) và length sẽ đánh lừa bạn.

#### 5A — Kiểm chứng SERVER (chạy trên server)

```powershell
$newKey = (Get-Content ".env" | Where-Object { $_ -match "^PROXY_API_KEY=" }) -replace "^PROXY_API_KEY=", ""
$oldKey = "KEY-CU-CAN-THU-HOI"
Write-Output "Prefix key moi: $($newKey.Substring(0,20))..."   # GHI NHỚ con số này

# 1. Key mới - local:  phải 200
Invoke-WebRequest "http://localhost:8317/v1/models" -Headers @{Authorization="Bearer $newKey"}

# 2. Key cũ:          phải 401
Invoke-WebRequest "http://localhost:8317/v1/models" -Headers @{Authorization="Bearer $oldKey"}

# 3. Key mới - tunnel: phải 200
Invoke-WebRequest "https://proxy.hatujsc.org/v1/models" -Headers @{Authorization="Bearer $newKey"}
```

Kết quả đúng: **200 / 401 / 200**.

#### 5B — Kiểm chứng CLIENT máy remote (chạy trong cửa sổ pwsh MỚI trên desktop remote)

```powershell
# 1. Prefix key trong phiên này — phải KHỚP prefix key mới từ 5A
$env:CLIPROXY_API_KEY.Substring(0, 20)

# 2. Gọi API thật bằng chính env var của phiên — phải 200
Invoke-WebRequest "https://proxy.hatujsc.org/v1/models" -Headers @{Authorization="Bearer $env:CLIPROXY_API_KEY"} -UseBasicParsing | Select-Object StatusCode

# 3. Codex CLI chạy thật — phải có phản hồi
codex exec --skip-git-repo-check "hi"
```

**Chẩn đoán nhanh nếu 5B ra 401:**

| Kết quả 5B-1 (prefix) | Kết quả 5B-2 (API) | Chẩn đoán | Fix |
|---|---|---|---|
| = key mới | 200 | ✅ Hoàn tất | — |
| = key cũ khác | 401 | Cửa sổ/Desktop còn env cũ | Làm lại 4B (hoặc restart máy) |
| lỗi null | — | Phiên chưa có biến | Mở cửa sổ mới sau 4B |

#### 5C — Nếu VS Code extension vẫn 401 sau khi CLI chạy được (BUG ĐÃ XÁC NHẬN)

**Root cause:** Extension `openai.chatgpt` **không dùng codex từ PATH** mà chạy bản bundle riêng:
`~\.vscode\extensions\openai.chatgpt-<ver>\bin\windows-x86_64\`
Tiến trình này **kế thừa env từ tiến trình chính của VS Code**. Nếu VS Code mở **trước khi**
biến env được đặt (hoặc biến chỉ ở User scope mà process cha không kế thừa), codex của
extension sẽ không thấy key → 401. Với custom provider, `auth.json` **bị bỏ qua** —
key luôn đến từ biến môi trường (`env_key` trong config.toml).

**Fix chuẩn (3 bước):**

1. Nâng biến env lên **Machine scope** (pwsh **quyền Admin**; mọi tiến trình GUI đều kế thừa):
   ```powershell
   [Environment]::SetEnvironmentVariable('CLIPROXY_API_KEY',
     [Environment]::GetEnvironmentVariable('CLIPROXY_API_KEY','User'), 'Machine')
   ```
2. Đóng **toàn bộ** VS Code (reload window KHÔNG đủ — extension host kế thừa env từ tiến trình chính):
   ```powershell
   taskkill /F /IM Code.exe /T
   ```
3. Mở lại VS Code → extension tự đọc key từ env, **không cần sign in/out**.

**Dự phòng (nếu vẫn kẹt login):**
- Đổi tên `~/.codex/auth.json` (VD thành `auth.json.bak-cliproxy`) để extension reset auth state — custom provider không cần auth.json.
- Hoặc mở VS Code từ terminal đang có sẵn biến env (`code` từ pwsh).

**Thông tin bug (đã xác nhận 2026-08-31):**

| Mục | Giá trị |
|-----|---------|
| Môi trường | Windows · Codex CLI + extension `openai.chatgpt` v26.5825.51511 · custom provider `cliproxy` |
| File liên quan | `~/.codex/config.toml` (định nghĩa provider) · `~/.codex/auth.json` (chỉ dùng cho provider OpenAI mặc định / ChatGPT login — **không ảnh hưởng cliproxy**) · `~/.vscode/extensions/openai.chatgpt-*/bin/windows-x86_64/` (codex bundle của extension) |

**Bài học / Phòng tránh:**
- Custom provider khai báo `env_key` trong config.toml → **key luôn đến từ biến môi trường**; `auth.json` chỉ dùng cho provider OpenAI mặc định / đăng nhập ChatGPT.
- Đặt biến API key ở **Machine scope** để mọi tiến trình GUI kế thừa, tránh phụ thuộc thứ tự khởi động.
- Khi đổi auth/config của codex: phải restart **toàn bộ** VS Code (kill `Code.exe`), không chỉ reload window.
- Set env qua SSH/PowerShell remote chỉ cập nhật registry — **desktop Explorer không tự nhận** (xem bẫy ở Bước 4B).

---

## 4. Rotate TUNNEL_TOKEN (Cloudflare)

> ⏱ Tổng thời gian: ~10 phút (chủ yếu thao tác trên dashboard). Downtime: ~1 phút.

### ✅ Checklist nhanh — làm GÌ, ở ĐÂU, trên MÁY NÀO

> 📌 Rotate tunnel token **KHÔNG ảnh hưởng client** — PROXY_API_KEY không đổi,
> không cần đụng `auth.json`, biến môi trường, hay VS Code trên bất kỳ máy nào.

| # | Vị trí | Việc cần làm |
|---|--------|--------------|
| 1 | **Cloudflare Dashboard**<br>(trình duyệt, máy nào cũng được) | Zero Trust → Networks → Tunnels → `cliproxy` → Configure → **Refresh token** → copy token mới |
| 2 | **SERVER** | Cập nhật `CLOUDFLARED_TUNNEL_TOKEN` trong `E:\cliproxyapi-standalone\.env` |
| 3 | **SERVER** (Docker) | Tạo lại container: `docker rm -f cliproxy-cloudflared` → `docker run ... --network host --token <TOKEN-MỚI>` |
| 4 | **SERVER** | Kiểm chứng: log có 4x "Registered tunnel connection" + gọi API qua `https://proxy.hatujsc.org` ra 200 |

### Bước 1 — Refresh token trong Cloudflare Dashboard

1. Đăng nhập [dash.cloudflare.com](https://dash.cloudflare.com)
2. **Zero Trust → Networks → Tunnels** → chọn tunnel `cliproxy` (tunnel ID `5dcb5039-...`)
3. **Configure** → tìm nút **Refresh token** (hoặc xoá tunnel cũ tạo tunnel mới — xem phần 4.3)
4. Copy **token mới** (chuỗi `eyJ...` — khác token cũ)

### Bước 2 — Cập nhật `.env` và tạo lại connector

```powershell
# Cập nhật CLOUDFLARED_TUNNEL_TOKEN trong .env (giữ nguyên PROXY_API_KEY)
# ... sửa tay hoặc dùng script tương tự phần 3 ...

# Tạo lại connector (token cũ nằm trong command line container cũ → phải tạo lại)
docker rm -f cliproxy-cloudflared

# Phiên bản 1 dòng:
docker run -d --name cliproxy-cloudflared --restart unless-stopped --network host cloudflare/cloudflared:latest tunnel --no-autoupdate run --token <TOKEN-MỚI>

# Hoặc nhiều dòng (PowerShell dùng backtick `):
docker run -d --name cliproxy-cloudflared --restart unless-stopped --network host `
  cloudflare/cloudflared:latest tunnel --no-autoupdate run --token <TOKEN-MỚI>
```

> ⚠️ **Bắt buộc `--network host`:** dashboard trỏ Service URL = `localhost:8317`,
> mà trong container `localhost` ≠ máy chủ. Host network giúp `localhost:8317` hoạt động.
> (Phương án thay thế: sửa Service URL trong dashboard thành `host.docker.internal:8317`
> rồi dùng network bridge thường — nhưng hiện tại đang dùng host network, giữ nguyên.)

### Bước 3 — Kiểm chứng

```bash
# 1. Tunnel connected: phải thấy 4x "Registered tunnel connection"
docker logs cliproxy-cloudflared | findstr "Registered tunnel"

# 2. API qua tunnel: phải 200
curl https://proxy.hatujsc.org/v1/models -H "Authorization: Bearer <PROXY_API_KEY>"
```

**Không cần** cập nhật gì trên client — PROXY_API_KEY không đổi.

### 4.3. Trường hợp nặng: xoá tunnel cũ, tạo tunnel mới

Dùng khi token refresh không khả dụng / nghi lộ nặng:

1. Dashboard → Tunnels → **Delete** tunnel cũ (DNS record `proxy.hatujsc.org` bị gỡ)
2. **Create a tunnel** → tên `cliproxy` → copy token mới
3. Chạy connector mới (lệnh ở Bước 2)
4. Tab **Public Hostname** → **Add**:
   - Subdomain: `proxy` | Domain: `hatujsc.org`
   - Service: `HTTP` | URL: `localhost:8317`
5. Cập nhật `CLOUDFLARED_TUNNEL_TOKEN` trong `.env`
6. Kiểm chứng như Bước 3

---

## 5. Rotate CẢ HAI cùng lúc (quy trình đầy đủ)

1. Sinh PROXY_API_KEY mới → cập nhật `.env` (phần 3, Bước 1)
2. Lấy TUNNEL_TOKEN mới từ dashboard → cập nhật `.env` (phần 4, Bước 1)
3. Tạo lại connector: `docker rm -f cliproxy-cloudflared` → run với token mới
4. Tạo lại server container: `docker rm -f cliproxyapi-standalone` → run lại
5. Cập nhật client local (phần 3, Bước 3) → restart VS Code
6. Cập nhật client remote (phần 3, Bước 4) → restart VS Code
7. Chạy toàn bộ kiểm chứng (phần 3, Bước 5 + phần 4, Bước 3)

**Thứ tự an toàn:** connector trước → server sau → client cuối cùng.

---

## 6. Sự cố thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|-------------|-------------|------------|
| `530 / error 1033` khi gọi tunnel | Connector chưa chạy / token sai | `docker logs cliproxy-cloudflared`, chạy lại connector |
| `502 Bad Gateway` qua tunnel | Connector dùng bridge network, `localhost` không tới server | Phải chạy connector với `--network host` |
| `401 Invalid API key` (Codex CLI) | Thiếu/ sai biến `CLIPROXY_API_KEY` trong phiên | `$env:CLIPROXY_API_KEY = (Get-Content "$env:USERPROFILE\.codex\auth.json" \| ConvertFrom-Json).OPENAI_API_KEY` |
| `401 Invalid API key` (VS Code extension) | Extension cache key cũ trong RAM | Restart VS Code hoàn toàn; nếu vẫn lỗi → Sign out → Sign in with API key |
| Đổi `.env` nhưng key cũ vẫn chạy | Chỉ `docker restart` (env-file không được đọc lại) | Phải `docker rm -f` + `docker run` lại |
| `-p: The term '-p' is not recognized...` khi paste lệnh docker | Lệnh nhiều dòng dùng `^` (CMD) nhưng đang chạy trong **PowerShell** | Dùng backtick `` ` `` thay `^`, hoặc paste bản "1 dòng" trong tài liệu |
| Remote: set env qua SSH xong nhưng desktop vẫn dùng key cũ → 401 | Broadcast env từ phiên SSH **không tới Explorer của desktop**; cửa sổ desktop kế thừa env cũ của Explorer | Trên desktop remote chạy lại `SetEnvironmentVariable(...,'User')` → đóng hết cửa sổ → mở mới; hoặc restart máy remote |
| Check `$env:CLIPROXY_API_KEY.Length` = 73 nhưng vẫn 401 | Rotate nhiều lần → các key **cùng độ dài**; length không phân biệt được key nào | So **prefix 20 ký tự** với key trong `.env` server + gọi API thật bằng env var (mục Bước 5B) |
| VS Code extension 401 dù auth.json + CLI đã đúng key mới | Extension chạy **codex bundle riêng** kế thừa env từ tiến trình VS Code; env chỉ ở User scope + VS Code mở trước khi đặt biến → bundle không thấy key | Nâng env lên **Machine scope** (Admin) → `taskkill /F /IM Code.exe /T` → mở lại VS Code (chi tiết: Bước 5C) |
| 503 `auth_unavailable` | Tài khoản OAuth chết (refresh_token_invalidated) | Login lại tài khoản đó; log: `docker logs cliproxyapi-standalone \| findstr "refresh failed"` |
| SSH remote bị từ chối | Key `home_ed25519` chưa có trên máy đích | Cài public key vào `authorized_keys` (đã làm, xem phần 7) |

---

## 8. Theo dõi sức khoẻ tài khoản (check-auths.ps1)

Script `scripts/check-auths.ps1` kiểm tra nhanh toàn bộ auth files qua management API
(key đọc từ `.env` → `MANAGEMENT_KEY`, không hard-code).

```powershell
# Xem tổng quan + danh sách lỗi (chạy tại E:\cliproxyapi-standalone)
.\scripts\check-auths.ps1

# Chế độ cảnh báo: chỉ đẩy thông báo khi CÓ lỗi (dùng cho Task Scheduler)
.\scripts\check-auths.ps1 -Notify
.\scripts\check-auths.ps1 -Notify -WebhookUrl "https://discord.com/api/webhooks/xxx"
# Telegram: WebhookUrl = https://api.telegram.org/bot<TOKEN>/sendMessage + biến env TELEGRAM_CHAT_ID
```

**Phân loại lỗi tự động:**

| Nhóm | Ý nghĩa | Hành động |
|------|---------|-----------|
| `DEAD` | Token bị OpenAI thu hồi (invalidated) | **Login lại OAuth** account đó |
| `QUOTA` | Hết usage limit (usage_limit_reached) | **Không cần làm gì** — tự hồi theo `retry_after` |
| `TRANSIENT` | Lỗi tạm thời (overloaded/rate) | Không cần làm gì — tự hồi |
| `OTHER` | Lỗi lạ | Xem `msg` trong output |

- Exit code: `0` = khoẻ, `1` = có lỗi DEAD/QUOTA/TRANSIENT, `2` = không gọi được API.
- **Lên lịch tự động** (chạy mỗi 15 phút, gửi cảnh báo khi có lỗi):
  ```powershell
  $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File E:\cliproxyapi-standalone\scripts\check-auths.ps1 -Notify -WebhookUrl `<WEBHOOK>`"
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
  Register-ScheduledTask -TaskName "CLIProxy-AuthHealth" -Action $action -Trigger $trigger
  ```
- Kiểm tra nhanh bằng docker logs (không cần script): `docker logs --since 1h cliproxyapi-standalone | findstr "refresh failed"`

---

## 7. Phụ lục — thông tin tham chiếu

### SSH vào máy remote
```
Host:  skyline@100.72.158.108
Key:   C:\Users\Admin\.ssh\home_ed25519
Lệnh:  C:\Windows\System32\OpenSSH\ssh.exe -o BatchMode=yes -i C:\Users\Admin\.ssh\home_ed25519 skyline@100.72.158.108 "<lệnh>"
```
Public key đã cài trên máy remote:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFuedA5q1QId63+f2a1kON062O19t6Plgnw8lOlqcmC4 home-ssh-access-2026
```

### Container đang chạy
| Container | Vai trò | Ghi chú |
|-----------|---------|---------|
| `cliproxyapi-standalone` | API server (CLIProxyAPI) | ports 1455, 8317, 18085→8085; env-file; image `cliproxyapi-local:latest` (build local) |
| `cliproxy-cloudflared` | Tunnel connector | `--network host`, token inline |

### Lệnh chẩn đoán nhanh
```bash
docker ps --filter "name=cliproxy"                          # container sống chưa
docker logs --tail 30 cliproxyapi-standalone                # log server
docker logs --tail 30 cliproxy-cloudflared                  # log tunnel
docker inspect cliproxy-cloudflared --format "{{.HostConfig.NetworkMode}}"   # phải là "host"
```

### Rotate lần gần nhất
- **31/08/2026 (sáng):** Tách key trùng — PROXY_API_KEY mới `sk-proxy-4fd...`, tunnel token giữ nguyên (chuyển vào biến `CLOUDFLARED_TUNNEL_TOKEN`).
- **31/08/2026 (chiều):** Fix bug extension VS Code không nhận key (root cause: codex bundle riêng của extension kế thừa env từ tiến trình VS Code) → nâng `CLIPROXY_API_KEY` lên **Machine scope** máy remote + `taskkill /F /IM Code.exe /T`. Chi tiết kỹ thuật: Bước 5C.
- **Lưu ý máy LOCAL:** nâng lên Machine scope cần pwsh **quyền Admin**:
  ```powershell
  # Mở pwsh Run as Administrator trên máy local, chạy:
  [Environment]::SetEnvironmentVariable('CLIPROXY_API_KEY',
    [Environment]::GetEnvironmentVariable('CLIPROXY_API_KEY','User'), 'Machine')
  ```

---

*Tài liệu vận hành nội bộ — lưu trên fork riêng, KHÔNG PR lên upstream.*
