# check-auths.ps1 — Kiểm tra nhanh sức khoẻ các tài khoản CLIProxyAPI
# Cách dùng:
#   .\scripts\check-auths.ps1              -> in tổng quan + danh sách account lỗi
#   .\scripts\check-auths.ps1 -Quota       -> dashboard quota (quan sát thụ động)
#   .\scripts\check-auths.ps1 -Notify      -> chỉ cảnh báo khi CÓ lỗi (cho Task Scheduler)
#   .\scripts\check-auths.ps1 -Notify -WebhookUrl "https://discord.com/api/webhooks/xxx"
# Exit code: 0 = mọi account khoẻ, 1 = có account lỗi (tiện cho scheduler/monitoring)

param(
    [switch]$Quota,
    [switch]$Notify,
    [string]$WebhookUrl = ""
)

Import-Module (Join-Path $PSScriptRoot "_common.psm1") -Force

try { $MgmtKey = Get-MgmtKey } catch { Write-Error $_.Exception.Message; exit 2 }
$authHdr = @{ Authorization = "Bearer $MgmtKey" }

try {
    $entries = Get-AuthEntries -ApiKey $MgmtKey
} catch {
    Write-Error $_.Exception.Message
    exit 2
}

$total = $entries.Count

# ---- Che do Quota: dashboard quota (thu dong tu signal cua proxy, khong goi upstream) ----
if ($Quota) {
    $rows = foreach ($e in $entries) {
        $q = $e.quota.signals
        $p = $q."X-Codex-Primary-Used-Percent"
        $s = $q."X-Codex-Secondary-Used-Percent"
        [PSCustomObject]@{
            email          = $e.email
            status         = $e.status
            plan           = if ($q."X-Codex-Plan-Type") { $q."X-Codex-Plan-Type" } else { "-" }
            limit          = if ($q."X-Codex-Active-Limit") { $q."X-Codex-Active-Limit" } else { "-" }
            primary_pct    = if ($null -ne $p -and $p -ne "") { [double]$p } else { -1 }
            primary_reset  = if ($q."X-Codex-Primary-Reset-After-Seconds") { [math]::Round([double]$q."X-Codex-Primary-Reset-After-Seconds"/3600, 1) } else { $null }
            weekly_pct     = if ($null -ne $s -and $s -ne "") { [double]$s } else { -1 }
            weekly_reset_d = if ($q."X-Codex-Secondary-Reset-After-Seconds") { [math]::Round([double]$q."X-Codex-Secondary-Reset-After-Seconds"/86400, 1) } else { $null }
        }
    }
    $observed = @($rows | Where-Object { $_.primary_pct -ge 0 })
    Write-Output "=== QUOTA DASHBOARD (thu dong tu request thuong) ==="
    Write-Output ("Co du lieu: {0}/{1} acc — thoi diem: {2}" -f $observed.Count, $rows.Count, ((Get-Date).ToString("HH:mm:ss")))
    Write-Output ""
    Write-Output "--- Sap theo % dung cua so 5h GIAM DAN (top 25) ---"
    $observed | Sort-Object primary_pct -Descending | Select-Object -First 25 |
        Format-Table email, plan, limit, primary_pct, primary_reset, weekly_pct, weekly_reset_d -AutoSize
    $hot = @($observed | Where-Object { $_.primary_pct -ge 80 })
    $warm = @($observed | Where-Object { $_.primary_pct -ge 50 -and $_.primary_pct -lt 80 })
    $cool = @($observed | Where-Object { $_.primary_pct -lt 50 })
    Write-Output ("Tong hop: HOT (>=80%): {0} | WARM (50-79%): {1} | COOL (<50%): {2} | Chua du lieu: {3}" -f `
        $hot.Count, $warm.Count, $cool.Count, ($rows.Count - $observed.Count))
    if ($hot.Count -gt 0) {
        Write-Output ""
        Write-Output "=== ACC GAN HET QUOTA (>=80%) — uu tien dung acc khac ==="
        $hot | ForEach-Object { Write-Output ("  - {0} ({1}% - reset sau {2}h)" -f $_.email, $_.primary_pct, $_.primary_reset) }
    }
    exit 0
}

# ---- Che do thường / Notify ----

$disabled = @($entries | Where-Object { $_.disabled })
$errors = @($entries | Where-Object { $_.status -eq "error" -or $_.unavailable })

# Phan loai: DEAD | QUOTA | TRANSIENT | OTHER
$grouped = @{ DEAD = @(); QUOTA = @(); TRANSIENT = @(); OTHER = @() }
foreach ($e in $errs) {
    $g = Classify-EntryStatus $e.status_message
    $grouped[$g] += @($e)
}
$dead = $grouped["DEAD"]; $quotaList = $grouped["QUOTA"]; $transient = $grouped["TRANSIENT"]; $other = $grouped["OTHER"]

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$okCount = $total - $errs.Count - $disabled.Count
Write-Output "[$stamp] Total=$total | OK=$okCount | DEAD=$($dead.Count) | QUOTA=$($quotaList.Count) | TRANSIENT=$($transient.Count) | OTHER=$($other.Count) | Disabled=$($disabled.Count)"

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
Print-Group "HET QUOTA - tu hoi theo retry_after (khong can lam gi)" $quotaList
Print-Group "LOI TAM THOI - tu hoi som" $transient
Print-Group "LOI KHAC - xem msg" $other

# Che do Notify: chi day canh bao khi CO loi
if ($Notify) {
    if ($errs.Count -eq 0) {
        Write-Output "Notify: khong co loi, khong gui."
        exit 0
    }
    $lines = @($errs | ForEach-Object { "- $($_.email) [$((Classify-EntryStatus $_.status_message))]" })
    $text = "[CLIProxyAPI] $($errs.Count)/$total tai khoan LOI:" + [Environment]::NewLine + ($lines -join [Environment]::NewLine)
    Send-Notify -WebhookUrl $WebhookUrl -Text $text
}

if ($errs.Count -gt 0) { exit 1 } else { exit 0 }
