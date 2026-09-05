# check-auths.ps1 — Kiểm tra nhanh sức khoẻ các tài khoản CLIProxyAPI
# Cách dùng:
#   .\scripts\check-auths.ps1              -> in tổng quan + danh sách account lỗi
#   .\scripts\check-auths.ps1 -Notify      -> chỉ cảnh báo khi CÓ lỗi (cho Task Scheduler)
#   .\scripts\check-auths.ps1 -Notify -WebhookUrl "https://discord.com/api/webhooks/xxx"
# Exit code: 0 = mọi account khoẻ, 1 = có account lỗi (tiện cho scheduler/monitoring)

param(
    [switch]$Quota,
    [switch]$Notify,
    [string]$WebhookUrl = ""
)

# Che do -Quota: bang quota tong hop TAT CA acc tu trong luot memory cua proxy
# (thu duoc THU DOI tu headers cua request thuong - KHONG goi upstream them lan nao -> khong ban risk)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"

# Đọc key từ .env (không hard-code key trong script)
$mgmtKey = (Get-Content $envFile | Where-Object { $_ -match "^MANAGEMENT_KEY=" }) -replace "^MANAGEMENT_KEY=", ""
if (-not $mgmtKey) { Write-Error "Khong tim thay MANAGEMENT_KEY trong .env"; exit 2 }

# Truy van management API
try {
    $resp = Invoke-WebRequest -Uri "http://localhost:8317/v0/management/auth-files" `
        -Headers @{ Authorization = "Bearer $mgmtKey" } -TimeoutSec 30 -UseBasicParsing
    $entries = ($resp.Content | ConvertFrom-Json).files
} catch {
    Write-Error "Khong goi duoc management API: $($_.Exception.Message)"
    exit 2
}

$total    = $entries.Count

# Che do Quota: bang tong hop tu quan sat thu doi (khong goi upstream)
if ($Quota) {
    $rows = foreach ($e in $entries) {
        $q = $e.quota.signals
        $pPct = $q."X-Codex-Primary-Used-Percent"
        $sPct = $q."X-Codex-Secondary-Used-Percent"
        [pscustomobject]@{
            email          = $e.email
            status         = $e.status
            plan           = if ($q."X-Codex-Plan-Type") { $q."X-Codex-Plan-Type" } else { "-" }
            limit          = if ($q."X-Codex-Active-Limit") { $q."X-Codex-Active-Limit" } else { "-" }
            primary_pct    = if ($null -ne $pPct -and $pPct -ne "") { [double]$pPct } else { -1 }
            primary_reset  = if ($q."X-Codex-Primary-Reset-After-Seconds") { [math]::Round([double]$q."X-Codex-Primary-Reset-After-Seconds"/3600, 1) } else { $null }
            weekly_pct     = if ($null -ne $sPct -and $sPct -ne "") { [double]$sPct } else { -1 }
            weekly_reset_d = if ($q."X-Codex-Secondary-Reset-After-Seconds") { [math]::Round([double]$q."X-Codex-Secondary-Reset-After-Seconds"/86400, 1) } else { $null }
        }
    }
    $observed = @($rows | Where-Object { $_.primary_pct -ge 0 })
    Write-Output "=== QUOTA DASHBOARD (thu doi tu request thuong) ==="
    Write-Output ("Co du lieu: {0}/{1} acc (acc chua duoc dung se trong) - thoi diem: {2}" -f $observed.Count, $rows.Count, ((Get-Date).ToString("HH:mm:ss")))
    Write-Output ""
    Write-Output "--- Sap theo % dung cua so 5h GIAM DAN (top 25) ---"
    $observed | Sort-Object primary_pct -Descending | Select-Object -First 25 |
        Format-Table email, plan, limit, primary_pct, primary_reset, weekly_pct, weekly_reset_d -AutoSize
    $hot = @($observed | Where-Object { $_.primary_pct -ge 80 })
    $warm = @($observed | Where-Object { $_.primary_pct -ge 50 -and $_.primary_pct -lt 80 })
    $cool = @($observed | Where-Object { $_.primary_pct -lt 50 })
    Write-Output ("Tong hop: HOT (>=80%): {0} | WARM (50-79%): {1} | COOL (<50%): {2} | Chua du lieu: {3}" -f $hot.Count, $warm.Count, $cool.Count, ($rows.Count - $observed.Count))
    if ($hot.Count -gt 0) {
        Write-Output ""
        Write-Output "=== ACC GAN HET QUOTA (>=80%) — uu trinh dung acc khac ==="
        $hot | ForEach-Object { Write-Output ("  - {0} ({1}% - reset sau {2}h)" -f $_.email, $_.primary_pct, $_.primary_reset) }
    }
    exit 0
}

$errors   = @($entries | Where-Object { $_.status -eq "error" -or $_.unavailable })
$disabled = @($entries | Where-Object { $_.disabled })

# Phan loai loi: DEAD (token het/chet) | QUOTA (het luong dung, tu hoi) | TRANSIENT (loi tam thoi)
function Classify-Err($msg) {
    if ($msg -match "invalidated|authentication token|refresh_token") { return "DEAD" }
    if ($msg -match "usage_limit|quota") { return "QUOTA" }
    if ($msg -match "overloaded|unavailable|timeout|rate") { return "TRANSIENT" }
    return "OTHER"
}
$dead      = @($errors | Where-Object { (Classify-Err $_.status_message) -eq "DEAD" })
$quota     = @($errors | Where-Object { (Classify-Err $_.status_message) -eq "QUOTA" })
$transient = @($errors | Where-Object { (Classify-Err $_.status_message) -eq "TRANSIENT" })
$other     = @($errors | Where-Object { (Classify-Err $_.status_message) -eq "OTHER" })

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$summary = "[$stamp] Total=$total | OK=$($total - $errors.Count - $disabled.Count) | DEAD=$($dead.Count) | QUOTA=$($quota.Count) | TRANSIENT=$($transient.Count) | OTHER=$($other.Count) | Disabled=$($disabled.Count)"

# Luon in tong quan ra console
Write-Output $summary

function Print-Group($title, $list) {
    if ($list.Count -eq 0) { return }
    Write-Output ""
    Write-Output "=== $title ($($list.Count)) ==="
    $list | ForEach-Object {
        $msg = if ($_.status_message) { ($_.status_message -replace '\s+', ' ').Substring(0, [Math]::Min(80, $_.status_message.Length)) } else { "" }
        Write-Output ("  - {0}  retry_after={1}" -f $_.email, $_.next_retry_after)
        Write-Output ("      msg: {0}" -f $msg)
    }
}

Print-Group "CAN LOGIN LAI - token bi OpenAI thu hoi" $dead
Print-Group "HET QUOTA - tu hoi theo retry_after (khong can lam gi)" $quota
Print-Group "LOI TAM THOI - tu hoi som" $transient
Print-Group "LOI KHAC - xem msg" $other

# Che do Notify: chi day canh bao khi CO loi
if ($Notify) {
    if ($errors.Count -eq 0) {
        Write-Output "Notify: khong co loi, khong gui."
        exit 0
    }
    $lines = @($errors | ForEach-Object { "- $($_.email) [$($_.status)]" })
    $text = "[CLIProxyAPI] $($errors.Count)/$total tai khoan LOI:" + [Environment]::NewLine + ($lines -join [Environment]::NewLine)

    if ($WebhookUrl -match "discord") {
        $body = @{ username = "cliproxy-monitor"; content = $text } | ConvertTo-Json
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" | Out-Null
    } elseif ($WebhookUrl) {
        # Telegram bot: WebhookUrl = https://api.telegram.org/bot<TOKEN>/sendMessage
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $text } | ConvertTo-Json
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" | Out-Null
    }
    Write-Output "Notify: da gui canh bao ($($errors.Count) loi)."
}

if ($errors.Count -gt 0) { exit 1 } else { exit 0 }
