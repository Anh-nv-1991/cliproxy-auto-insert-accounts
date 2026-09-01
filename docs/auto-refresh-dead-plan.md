# Plan: Tự động phục hồi tài khoản chết token (Auto-Refresh Dead)

> Nội bộ vận hành — đã commit trên fork riêng (Anh-nv-1991/cliproxy-auto-insert-accounts). KHÔNG PR lên upstream.
> Ngày lập: 31/08/2026. Phiên bản kế hoạch: **v3**.

---

## 1. Mục tiêu

Tự động hoá quy trình đang làm **bằng tay** hiện tại:

> Nhìn panel → tìm acc lỗi token → lấy `email|pass|totp` → chạy gpt-tool → copy JSON vào `auths/`

Thành 1 script điều phối duy nhất: **phát hiện → so khớp → re-login → upload → verify → báo cáo**.

Chỉ xử lý tài khoản **chết token** (`invalidated`), KHÔNG đụng:
- `QUOTA` / `TRANSIENT` (tự hồi)
- tài khoản bị **deactive** thật (re-login sẽ phát hiện và bỏ)

---

## 2. Bối cảnh hiện tại

| Thông số | Giá trị |
|---|---|
| Tổng auth files | 166 (toàn bộ là Codex OAuth) |
| Trạng thái (31/08 20:27) | 94 active · 38 DEAD · 30 QUOTA · 4 TRANSIENT |
| Nguồn creds | `gpt-tool/free-acc-100-28-08-2026.txt` + `free-acc-53.txt` (168 email, phủ 100% 38 acc dead) |
| Tool re-login | `gpt-tool` (Python, venv riêng) — `export --format cpa` |
| Management API | `http://localhost:8317/v0/management` — key trong `.env` → `MANAGEMENT_KEY` |

---

## 3. Luồng xử lý (v3)

```
 1. PHÁT HIỆN   GET /v0/management/auth-files
                → lọc status=error + status_message khớp
                  (invalidated|expired|refresh.?failed)
                → loại trừ QUOTA / TRANSIENT / disabled
                → ra: danh sách email + tên file auth chết

 2. SO KHỚP     email ∩ file .txt (bỏ header, chỉ giữ dòng có "@")
                → list "email|pass|totp"
                → acc dead KHÔNG có trong nguồn → ghi báo cáo "chờ xử lý tay"

 3. DỌN out/    xoá trắng gpt-tool\out trước mỗi run (tránh đụng tên _2)

 4. GENERATE    .venv\Scripts\python.exe -m gpt_tool.cli export
                --format cpa --lines <tmp> --out out --workers 2
                → chạy dưới -TimeoutMinutes tổng (mặc định 45)

 5. UPLOAD      POST /v0/management/auth-files (multipart)
                → đặt tên file = id thật từ management API (ghi đè chuẩn)

 6. VERIFY      chờ 30-60s cho watcher nạp lại → re-query → active?

 7. DỌN NHỚT    theo bảng chính sách (mục 5)

 8. BÁO CÁO     log CSV (redact pass) + audit xoá + exit code (0/1/2)

 9. RESUME      lần chạy sau chỉ xử lý phần còn chết (idempotent)
```

---

## 4. Quyết định đã chốt

| Chủ đề | Quyết định |
|---|---|
| Xử lý file chết | **Xoá thẳng** (không backup) — trừ ngoại lệ `network` thì giữ để retry |
| Nguồn acc | 2 file `.txt` (đủ phủ, không cần xlsx/openpyxl) |
| Vận hành | **Bán tự động** — DryRun mặc định, `-Execute` để chạy thật |
| Batch size | Không giới hạn (xử lý hết acc dead/1 lần), thêm `-LoginDelaySeconds 20` giữa login |
| Workers | 2 (mặc định của gpt-tool) |
| Upload | Qua Management API (có validation + audit), không copy file tay |

---

## 5. Chính sách dọn nhợt (sau re-login)

| Kết quả re-login | Hành động với file chết |
|---|---|
| OK | Upload ghi đè (không xoá) |
| `locked` (deactive thật) | **Xoá** — không bao giờ hồi |
| `AddPhoneRequired` (bắt bind phone) | **Xoá** — không auto-fix được |
| `credential` / `mfa` (sai pass/TOTP) | **Xoá** + báo cáo để sửa nguồn |
| `network` / lỗi tạm | **Giữ lại** — lần sau thử tiếp |

---

## 6. Điểm kỹ thuật đã xác minh (đọc source)

| # | Sự thật | Nguồn |
|---|---|---|
| 1 | `POST /auth-files` multipart: tên file trong part = tên file đích | `auth_files_crud.go` |
| 2 | Upload **ghi đè** file cũ; JSON invalid bị từ chối trước khi ghi | `writeAuthFile → os.WriteFile` |
| 3 | `DELETE /auth-files?name=<file>` xoá 1/nhiều file | `DeleteAuthFile` |
| 4 | Watcher hot-reload file trong `auths/` (add/modify/delete), xử lý được burst lớn | `docs/sdk-watcher.md` |
| 5 | gpt-tool `--format cpa` ra đúng format auth file | so byte `out/` vs `auths/` |
| 6 | gpt-tool trả lỗi có cấu trúc: `step` + `kind` (locked/credential/mfa/network) + `AddPhoneRequired` | `export.py`, `login.py` |

---

## 7. Lỗ hổng đã phát hiện + cách vá

1. **Đụng tên `_2` khi re-run** → xoá trắng `out/` mỗi run (bước 3).
2. **File txt có 3 dòng header** → lọc chỉ giữ dòng khớp `email|pass[|totp]`.
3. **gpt-tool không có timeout/login** → chạy dưới `-TimeoutMinutes`.
4. **Account trùng tên có file `_2`** (vd `pods.puniest.39...`) → mapping dùng `id` từ API.
5. **Rò rỉ mật khẩu** → temp file ở temp dir + xoá; báo cáo redact, không in creds.
6. **Chính sách xoá** → theo bảng mục 5.
7. **Cửa sổ verify** → chờ 30-60s trước khi verify/xoá.

---

## 8. Script dự kiến

`scripts/auto-refresh-dead.ps1` — đọc `MANAGEMENT_KEY` từ `.env` (không hard-code).

**Cách chạy:**

| Cách | Hành vi |
|---|---|
| Double-click `scripts\auto-refresh-dead.bat` | **Tương tác**: tự kiểm tra → hiện acc dead → hỏi `y/N` trước khi chạy thật → giữ cửa sổ đến khi bấm Enter |
| Terminal không tham số: `.\scripts\auto-refresh-dead.ps1` | Như trên (tương tác) |
| Terminal có tham số: `.\scripts\auto-refresh-dead.ps1 -Execute` | **Tự động**: không hỏi, không pause (dùng cho Task Scheduler) |
| `-Pause` kèm tham số khác | Tự động nhưng vẫn giữ cửa sổ cuối cùng |

⚠️ Đừng dùng "Run with PowerShell" (context menu) — đó là PowerShell 5.1, sẽ lỗi cú pháp.
Luôn dùng `.bat` hoặc `pwsh`.

```
Tham số:
  -DryRun             (mặc định) chỉ liệt kê, không xoá/không login
  -Pause              giữ cửa sổ mở cuối cùng (kết hợp tham số khác)
  -Execute            chạy thật (xoá + login + upload)
  -LoginDelaySeconds  (mặc định 20)  delay giữa 2 chunk login
  -Workers            (mặc định 2)
  -TimeoutMinutes     (mặc định 45)  timeout tổng cho bước gpt-tool
  -MaxAccounts N      (tùy chọn) giới hạn số acc/lần
  -Proxy <url>        (tùy chọn) proxy cho gpt-tool nếu OpenAI chặn
  -Notify [-WebhookUrl <url>]  cảnh báo khi có lỗi (Discord/Telegram)

Exit code: 0 = xong sạch / không có acc dead
           1 = còn acc lỗi (retry lần sau, gồm cả acc thiếu creds)
           2 = lỗi API / cấu hình / script đang chạy trùng (mutex)
```

---

## 9. Rủi ro & giảm thiểu

| Rủi ro | Giảm thiểu |
|---|---|
| 38-100 login tự động từ 1 IP bị OpenAI/Cloudflare để ý | delay giữa login + workers=2 + `-Proxy` dự phòng + resumable |
| 1 login treo kẹt cả batch | `-TimeoutMinutes` + resumable |
| Acc deactive thật | `kind=locked` → xoá + blacklist, không đốt thời gian lần sau |
| OpenAI bắt bind phone khi OAuth | `AddPhoneRequired` → xoá + báo cáo |
| Sai pass/TOTP trong nguồn | báo cáo để sửa nguồn, không retry vô ích |

---

## 10. Tracking (checklist)

### Chuẩn bị
- [x] Viết `scripts/auto-refresh-dead.ps1` (skeleton + tham số + đọc .env)
- [x] Module 1 — detect (GET auth-files + classify)
- [x] Module 2 — match (parse txt, lọc header, map email→id)
- [x] Module 3 — dọn out/ + generate (gọi gpt-tool dưới timeout)
- [x] Module 4 — upload (multipart, đúng tên `id`)
- [x] Module 5 — verify + dọn nhợt (theo matrix)
- [x] Module 6 — báo cáo CSV + audit + exit code

### Kiểm thử
- [x] DryRun: liệt kê đúng 38 acc dead, 38/38 match, không xoá/không login
- [x] Execute thử `-MaxAccounts 2 -TimeoutMinutes 12`: login OK 2/2, upload 2/2
- [x] Verify: 2 acc mẫu chuyển `active` + request thật qua proxy OK

### Triển khai
- [x] Full run — **KHÔNG cần nữa**: 36 acc còn lại tự hồi phục (xem mục 12), hiện 0 dead
- [ ] (tùy chọn) Task Scheduler mỗi 1-2h + webhook — script đã hỗ trợ `-Notify`

---

## 11. Nhật ký quyết định

| Ngày | Thay đổi |
|---|---|
| 31/08 | Chốt nguồn = `.txt`, xoá thẳng, bán tự động, không giới hạn batch |
| 31/08 | Bỏ bước "xoá trước"; đổi sang "upload ghi đè" + dọn nhợt sau (v3) |
| 31/08 | Review source: phát hiện 7 lỗ hổng, đã đưa vào mục 7 |
| 31/08 | Implement xong + test DryRun/Execute OK. Phát hiện & vá bug gpt-tool UTF-8 (mục 12.1) |
| 31/08 | 36/38 acc dead còn lại TỰ HỒI PHỤC sau khi watcher recompute (mục 12.2) — hiện 166/166 active |
| 31/08 | Self-review: vá 3 bug (#1 exit-code, #2 tmp password cleanup, #3 regex) + mutex/source-guard/dedupe (mục 13). Validate bằng Execute 3 acc dead mới → sạch |
| 01/09 | Thêm chế độ TƯƠNG TÁC: chạy không tham số → tự DryRun + hỏi y/N trước Execute + giữ cửa sổ (finally pause). Thêm `auto-refresh-dead.bat` launcher (pwsh 7, double-click). Chạy thật 1 acc dead mới → sạch |

---

## 12. Kết quả chạy thực tế (31/08/2026)

### 12.1 Bug gpt-tool UTF-8 (đã vá trong script)

`gpt_tool/cli.py` print `done ... → out` chứa ký tự `→` (U+2192). Khi stdout bị
redirect (Start-Process), Python rơi về cp1252 → `UnicodeEncodeError` crash
**sau khi xử lý xong nhưng trước khi in kết quả OK/FAIL** → script không đọc
được kết quả.

**Fix (trong `auto-refresh-dead.ps1`):**
- `$env:PYTHONIOENCODING = "utf-8"` + chạy python với `-X utf8`
- Fallback: xác định thành công bằng **file JSON trong `out/`** (đọc trường
  `email`), không phụ thuộc stdout
- Log stdout/stderr của gpt-tool được lưu vào `logs/auto-refresh-gpt-<stamp>.log`

⚠️ Nếu cập nhật gpt-tool sau này: giữ nguyên `-X utf8` khi gọi.

### 12.2 Phát hiện quan trọng: DEAD có thể là trạng thái TẠM THỜI

Diễn biến 31/08:
- 20:27 — 38 acc DEAD (`refresh_token_invalidated` 401 từ OpenAI)
- 21:26 — log container vẫn 401 refresh fail
- 21:39-40 — script Execute test: re-login + upload 2 acc → **watcher recompute
  toàn bộ auth state**, xoá sạch error state runtime của TẤT CẢ acc
- 21:45+ — **36 acc còn lại tự chuyển `active`** mà KHÔNG cần re-login

Xác minh trung thực (không tin status hiển thị):
- Request thật qua proxy (`gpt-5.4-mini`) → OK
- docker logs sau request: **0** dòng invalidated/401
- Kiểm tra lại sau 90s: 166/166 active, ổn định

**Kết luận:** đợt invalidation 31/08 nhiều khả năng là lỗi tạm thời phía OpenAI
(trả 401 oan), hoặc token chỉ cần được retry sau khi reload. Chỉ 2 acc chết
"thật sự" cần re-login.

### 12.3 Caveat cho bước VERIFY

Watcher reload **xoá error state** → một token vẫn chết có thể hiển thị
`status=active` ngay sau reload. Vì vậy:
- KHÔNG tin status ngay sau upload — phải chờ + kiểm tra log 401
- Verify mạnh nhất = request thật qua proxy + theo dõi `docker logs`
- Script hiện verify bằng status (đủ dùng vì đã chờ `VerifyWaitSeconds` + có
  thể chạy lại script để re-check; acc lỗi thật sẽ DEAD lại và bị bắt ở lần sau)

### 12.4 File/khác

- Script: `scripts/auto-refresh-dead.ps1` (DryRun mặc định)
- CSV báo cáo: `logs/auto-refresh-<stamp>.csv`, log gpt-tool: `logs/auto-refresh-gpt-<stamp>.log`
- Nếu gpt-tool out/ chứa file cũ lạ → script tự dọn trước mỗi lần Execute

---

## 13. Review & fixes lần 1 (31/08/2026)

Self-review sau khi implement — 3 bug quan trọng + 3 minor đã vá, đã validate bằng chạy thật:

| # | Mức độ | Vấn đề | Fix | Trạng thái |
|---|---|---|---|---|
| 1 | 🔴 | `$remaining` không trừ acc đã XOÁ → exit code + summary sai khi có deactivated | `$remaining = dead - fixed - deleted` | ✅ Đã vá |
| 2 | 🔴 | `tmpDir` chứa `email\|pass\|totp` không được dọn nếu script crash/Ctrl+C giữa chừng | Outer + inner `try/finally` luôn dọn tmpDir; sweep dir leak cũ khi khởi động; đã test `finally` chạy trên `exit` | ✅ Đã vá |
| 3 | 🔴 | Regex `add.?phone\|phone` quá rộng → nguy cơ xoá nhầm | Chỉ giữ `add.?phone` (khớp message thật `"...add-phone..."` của gpt-tool) | ✅ Đã vá |
| 7 | ⚪ | Không chống chạy trùng | Mutex `Global\cliproxy-auto-refresh-dead` + release trên mọi exit path (outer finally); test 2 tiến trình song song OK | ✅ Đã vá |
| 9 | ⚪ | Detection chưa lọc `source` | Thêm guard `source -eq "file"` | ✅ Đã vá |
| 10 | ⚪ | `$skipped` có thể trùng email | Dedupe `-notcontains` | ✅ Đã vá |
| 4 | 🟡 | Verify bằng status có thể "ảo" (watcher reload xoá error state) | Đã document mục 12.3 — nâng cấp smoke-test thật khi cần | Theo dõi |
| 5 | 🟡 | Snapshot detection có thể cũ → re-login acc đã tự hồi (vô hại) | Chấp nhận | Theo dõi |
| 6 | ⚪ | Log gpt-tool ghi raw vào `logs/` (có thể chứa OAuth code) | Local + git-ignored — chấp nhận, đừng share | Theo dõi |
| 8 | ⚪ | Quote quanh path trong `$argList` | **Giữ nguyên** — bảo vệ cho path có spaces, review ban đầu gọi "redundant" là sai | Đóng |

**Bài học từ fix #7:** mutex phải release trên MỌI exit path — bản đầu chỉ release ở
phần Execute, DryRun `exit 0` để mutex bị giữ nếu chạy bằng `& script` (cùng process).
Đã bọc outer try/finally bao trọn script.

**Validation sau fix:** Execute thật 3 acc dead mới phát hiện (2 acc chết thêm +
1 acc cũ chưa hồi) → login 3/3, upload 3/3, verify active 3/3, `con lai=0`,
exit code 0, không tmpDir leak, pool 166/166 active, smoke test request thật OK.

---

## 14. Sự cố mất file (01/09/2026) + khôi phục

**Nguyên nhân:** `git reset --hard origin/main` + clean file untracked lúc 13:53
đã xoá toàn bộ `scripts/auto-refresh-dead.*` + source `gpt_tool/*.py` +
`free-acc-*.txt` + `free-acc-28-09-2026.xlsx` (tất cả đều untracked).
Các file git-ignored (`.env`, `config.yaml`, `auths/`, `docs/`) sống sót.

**Khôi phục từ `C:\Users\Admin\.local\share\opencode\opencode.db`** (session DB
của opencode chứa nội dung mọi tool-call):

| File | Cách phục hồi | Trạng thái |
|---|---|---|
| `auto-refresh-dead.ps1` | Replay write gốc (21:22) + 26/30 edit theo thứ tự; 4 edit skip = các lần thất bại trong phiên gốc | ✅ Nguyên văn |
| `auto-refresh-dead.bat` | Write event duy nhất (610 bytes) | ✅ Nguyên văn |
| `login.py`, `cli.py`, `export.py`, `parser.py`, `server.py`, `README.md` | Parse read outputs (strip `N: ` prefix + footer) | ✅ Nguyên văn |
| `requirements.txt`, `start.bat` | Bash output 08-31 20:34 | ✅ Nguyên văn |
| `oauth.py`, `convert.py`, `http_client.py`, `sentinel_pow.py`, `totp.py`, `jwtutil.py`, `redaction.py`, `ensure_deps.py`, `__init__.py` | **Tái dựng từ call-site** (imports/usages trong file đã phục hồi) — sentinel PoW theo thuật toán công khai | ⚠️ Xấp xỉ, cần debug khi chạy thật |
| `free-acc-53.txt` | Read output 08-22 (53 acc) | ✅ |
| `free-acc-100-28-08-2026.txt`, `free-acc-28-09-2026.xlsx` | Chỉ còn header/count — **mất vĩnh viễn** | ❌ |

**Đã commit + push:** branch `local-patches` trên
`https://github.com/Anh-nv-1991/cliproxy-auto-insert-accounts` (commit
`81880484` + `2d1b4911`) — không còn cách nào mất nữa.

**Bài học:**
1. File chưa commit = file chưa tồn tại. Commit sớm vào branch riêng.
2. `git clean`/Discard All xoá **vĩnh viễn** untracked files (không qua Recycle Bin).
3. opencode.db là nguồn phục hồi mạnh: write/edit/reverse events + read outputs.
