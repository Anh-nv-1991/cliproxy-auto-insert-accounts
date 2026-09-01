# add-accounts.ps1 - Them TAI KHOAN MOI vao pool CLIProxyAPI
#
# Khac voi auto-refresh-dead.ps1 (re-login acc da co file auth): script nay
# danh cho tai khoan MOI mua - tao file auth moi + upload.
#
# Cach dung:
#   .\scripts\add-accounts.ps1 -LinesFile "gpt-tool\free-acc-01-09-2026.txt"          -> DryRun
#   .\scripts\add-accounts.ps1 -LinesFile "..." -Execute                              -> chay that
#   .\scripts\add-accounts.ps1 -LinesFile "..." -Execute -MaxAccounts 5              -> chay thu nho
#   .\scripts\add-accounts.ps1                                                        -> hoi file tuong tac
#
# Tham so chinh:
#   -LinesFile <path>       file txt dang email|pass[|totp] (bat buoc tru -Execute)
#   -Execute                chay that (login + upload). Khong co = DryRun
#   -SkipExisting           bo qua email da ton tai trong pool (mac dinh BAT)
#   -MaxAccounts N          gioi han so acc / lan
#   -Workers N              acc / chunk cho gpt-tool (mac dinh 2)
#   -LoginDelaySeconds N    delay giua 2 chunk (mac dinh 20)
#   -TimeoutMinutes N       timeout tong (mac dinh 120 - du cho ~100 acc)
#   -Proxy <url>            proxy cho gpt-tool neu OpenAI chan IP
#   -VerifyWaitSeconds N    cho watcher nap truoc khi verify (mac dinh 45)
#   -Notify -WebhookUrl     canh bao Discord/Telegram khi co loi
#
# Exit code: 0 = thanh cong / khong co acc moi | 1 = con loi (retry lan sau) | 2 = loi API/cau hinh

param(
    [string]$LinesFile = "",
    [switch]$Execute,
    [switch]$SkipExisting = $true,
    [int]$MaxAccounts = 0,
    [int]$Workers = 2,
    [int]$LoginDelaySeconds = 20,
    [int]$TimeoutMinutes = 120,
    [int]$VerifyWaitSeconds = 45,
    [string]$Proxy = "",
    [string]$ApiBase = "http://localhost:8317",
    [switch]$Notify,
    [string]$WebhookUrl = ""
)

$ErrorActionPreference = "Stop"

# Yeu cau PowerShell 7: cú pháp $var text trong subexpression khong parse duoi 5.1
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output "Can PowerShell 7 (pwsh). Chay bang: pwsh -File scripts\add-accounts.ps1 ..."
    exit 2
}

$root   = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
$gptRoot = Join-Path $root "gpt-tool"
$gptOut  = Join-Path $gptRoot "out"
$gptPy   = Join-Path $gptRoot ".venv\Scripts\python.exe"
$logsDir = Join-Path $root "logs"

$env:PYTHONIOENCODING = "utf-8"   # gpt-tool in "→" - tranh crash cp1252 khi stdout redirect

# ---------- helpers ----------
function Redact([string]$s) {
    if (-not $s) { return "" }
    $s = ($s -replace "`r|`n", " ")
    if ($s.Length -gt 140) { $s = $s.Substring(0, 140) + "..." }
    return $s
}

function Target-FileName([string]$email) {
    # Convention cua auths/: email -> email_at_domain.json (giu '+', '.' va '_at_')
    $san = ($email.Trim().ToLower()) -replace "[^a-z0-9._+-]", "_"
    $san = $san -replace "@", "_at_"
    return "$san.json"
}

$MgmtKey = (Get-Content $envFile | Where-Object { $_ -match "^MANAGEMENT_KEY=" }) -replace "^MANAGEMENT_KEY=", ""
if (-not $MgmtKey) { Write-Output "Khong tim thay MANAGEMENT_KEY trong $envFile"; exit 2 }
$authHdr = @{ Authorization = "Bearer $MgmtKey" }

$script:runMutex = New-Object System.Threading.Mutex($false, "Global\cliproxy-add-accounts")
try {
if (-not $script:runMutex.WaitOne(0)) {
    Write-Output "Script add-accounts DANG CHAY trong tien trinh khac -> thoat."
    exit 2
}

$report = [System.Collections.Generic.List[object]]::new()
function Add-Report([string]$phase, [string]$email, [string]$file, [string]$detail) {
    $report.Add([pscustomobject]@{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); phase = $phase
        email = $email; auth_file = $file; detail = (Redact $detail)
    })
}

$stamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force $logsDir | Out-Null
$mode = if ($Execute) { "EXECUTE" } else { "DRYRUN" }
Write-Output "[$stamp] add-accounts | mode=$mode | linesFile=$(if ($LinesFile) { $LinesFile } else { '(chua chon)' })"

# ---------- [1/6] DOC + LOC FILE LINES ----------
if (-not $LinesFile) {
    Write-Output "Thieu -LinesFile. Vi du: -LinesFile `"gpt-tool\free-acc-01-09-2026.txt`""
    exit 2
}
$linesPath = Join-Path $root $LinesFile
if (-not (Test-Path $linesPath)) { $linesPath = $LinesFile }   # cho phep path tuyet doi
if (-not (Test-Path $linesPath)) { Write-Output "Khong tim thay file: $LinesFile"; exit 2 }

$allLines = @(Get-Content $linesPath | Where-Object {
    $t = $_.Trim()
    if (-not $t -or $t.StartsWith("#")) { return $false }
    $p = $t -split '\|'
    if ($p.Count -lt 2) { return $false }
    return ($p[0] -match '^[^@\s]+@[^@\s]+\.[^@\s]+$')
} | ForEach-Object { $_.Trim() })
Write-Output ("[1/6] Doc file: {0} dong hop le (email|pass[|totp])" -f $allLines.Count)
if ($allLines.Count -eq 0) { Write-Output "Khong co account nao."; exit 0 }

# ---------- [2/6] DEDUPE voi pool hien tai ----------
Write-Output ""
Write-Output "=== [2/6] Kiem tra trung lap voi pool hien tai ==="
try {
    $entries = Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Headers $authHdr -TimeoutSec 30
    $existing = @{}
    foreach ($e in @($entries.files)) {
        $emv = $e.email
        if (-not $emv) { $emv = "" }
        $em = $emv.Trim().ToLower()
        if ($em) { $existing[$em] = $true }
    }
} catch {
    Write-Output "Khong goi duoc management API: $($_.Exception.Message)"
    exit 2
}
Write-Output ("Pool hien tai: {0} auth files" -f $existing.Count)

$queued = @()
$dupCount = 0
foreach ($ln in $allLines) {
    $em = ($ln -split '\|')[0].Trim().ToLower()
    if ($SkipExisting -and $existing.ContainsKey($em)) { $dupCount++; continue }
    $queued += $ln
}
Write-Output ("Moi: {0} | Trung (bo qua): {1}" -f $queued.Count, $dupCount)

if ($MaxAccounts -gt 0 -and $queued.Count -gt $MaxAccounts) {
    Write-Output ("Gioi han -MaxAccounts {0}" -f $MaxAccounts)
    $queued = $queued | Select-Object -First $MaxAccounts
}
if ($queued.Count -eq 0) {
    Write-Output "Khong co account moi nao can them."
    $csvPath = Join-Path $logsDir ("add-accounts-{0}.csv" -f $runStamp)
    $report | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
    exit 0
}

if (-not $Execute) {
    Write-Output ""
    Write-Output "=== DRYRUN — ke hoach ==="
    Write-Output ("Se login + upload {0} acc moi | chunk {1} | delay {2}s | timeout {3} phut" -f $queued.Count, $Workers, $LoginDelaySeconds, $TimeoutMinutes)
    $queued | Select-Object -First 20 | ForEach-Object { Write-Output ("  * " + (($_ -split '\|')[0])) }
    if ($queued.Count -gt 20) { Write-Output ("  ... va {0} acc khac" -f ($queued.Count - 20)) }
    Write-Output "Them -Execute de chay that."
    exit 0
}

# ---------- [3/6] CHAY gpt-tool (chunked, co timeout) ----------
Write-Output ""
Write-Output ("=== [3/6] Login + export {0} acc qua gpt-tool ===" -f $queued.Count)
if (-not (Test-Path $gptPy)) { Write-Output "Khong thay python venv: $gptPy"; exit 2 }

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$tmpDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("gpt-add-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmpDir | Out-Null
$okBy = @{}; $failBy = @{}; $skipped = @()

try {
$chunks = @()
for ($i = 0; $i -lt $queued.Count; $i += $Workers) {
    $end = [Math]::Min($i + $Workers - 1, $queued.Count - 1)
    $chunks += ,@($queued[$i..$end])
}

$chunkNo = 0
foreach ($chunk in $chunks) {
    $chunkNo++
    if ((Get-Date) -gt $deadline) {
        Write-Output "Het thoi gian ($($TimeoutMinutes) phut) - phan con lai retry lan sau."
        foreach ($m in $chunk) { if ($skipped -notcontains (($m -split '\|')[0].ToLower())) { $skipped += (($m -split '\|')[0].ToLower()) } }
        break
    }
    $emails = (($chunk | ForEach-Object { ($_ -split '\|')[0] }) -join ", ")
    Write-Output ("-- chunk {0}/{1}: {2}" -f $chunkNo, $chunks.Count, $emails)

    $tmpLines = Join-Path $tmpDir "lines.txt"
    Set-Content -Path $tmpLines -Value $chunk -Encoding UTF8
    $argList = @('-X','utf8','-m','gpt_tool.cli','export','--format','cpa','--lines', ('"{0}"' -f $tmpLines), '--out','out','--workers', ("{0}" -f $Workers))
    if ($Proxy) { $argList += @('--proxy', $Proxy) }

    $soLog = Join-Path $tmpDir "stdout.log"; $seLog = Join-Path $tmpDir "stderr.log"
    $proc = Start-Process -FilePath $gptPy -ArgumentList $argList -WorkingDirectory $gptRoot -NoNewWindow -PassThru -RedirectStandardOutput $soLog -RedirectStandardError $seLog
    $remainMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
    if ($remainMs -le 0 -or -not $proc.WaitForExit($remainMs)) {
        try { $proc.Kill($true) } catch {}
        Write-Output "Chunk treo qua timeout -> kill. Retry lan sau."
        foreach ($m in $chunk) { $em = (($m -split '\|')[0].ToLower()); if ($skipped -notcontains $em) { $skipped += $em }; Add-Report "login" $em "" "TIMEOUT chunk" }
        break
    }

    $soText = (Get-Content $soLog -Raw -ErrorAction SilentlyContinue | Out-String).Trim()
    foreach ($ln in ($soText -split "`n")) {
        if ($ln -match '^\s*OK\s+(\S+)\s+(.+)$')      { $okBy[$Matches[1].ToLower()] = $true }
        elseif ($ln -match '^\s*FAIL\s+(\S+)\s+(.+)$') { $failBy[$Matches[1].ToLower()] = $Matches[2] }
    }
    Get-ChildItem $gptOut -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json; if ($j.email) { $okBy[$j.email.ToLower()] = $true } } catch {}
    }
    $gptLog = Join-Path $logsDir ("add-accounts-gpt-{0}.log" -f $runStamp)
    Add-Content $gptLog ("--- chunk {0} stdout ---`n{1}`n--- stderr ---`n{2}" -f $chunkNo, $soText, ((Get-Content $seLog -Raw -ErrorAction SilentlyContinue | Out-String).Trim()))
    foreach ($m in $chunk) {
        $em = (($m -split '\|')[0]).ToLower()
        if     ($okBy.ContainsKey($em))   { Add-Report "login" $em "" "OK" }
        elseif ($failBy.ContainsKey($em)) { Add-Report "login" $em "" "FAIL: $($failBy[$em])" }
        else                              { if ($skipped -notcontains $em) { $skipped += $em }; Add-Report "login" $em "" "KHONG CO ket qua" }
    }
    if ($chunkNo -lt $chunks.Count) { Start-Sleep -Seconds $LoginDelaySeconds }
}
Write-Output ("Login OK: {0} | FAIL: {1} | Bo qua: {2}" -f $okBy.Count, $failBy.Count, $skipped.Count)

# ---------- [4/6] UPLOAD file auth MOI ----------
Write-Output ""
Write-Output "=== [4/6] Upload file auth moi ==="
$uploaded = @{}
Get-ChildItem $gptOut -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
        if (-not $j.email) { return }
        $em = $j.email.ToLower()
        if (-not $okBy.ContainsKey($em)) { return }
        if ($SkipExisting -and $existing.ContainsKey($em)) { return }   # da ton tai - khong ghi de
        $targetName = Target-FileName $em
        $tmpName = Join-Path $tmpDir $targetName
        Copy-Item $_.FullName $tmpName -Force
        $form = @{ file = Get-Item $tmpName }
        Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Method Post -Headers $authHdr -Form $form -TimeoutSec 60 | Out-Null
        $uploaded[$em] = $targetName
        Add-Report "upload" $em $targetName "OK (file moi)"
        Write-Output ("  + {0}  ->  {1}" -f $em, $targetName)
    } catch {
        Add-Report "upload" "" $_.Name "UPLOAD LOI: $($_.Exception.Message)"
        Write-Output ("  ! upload loi: " + $_.Exception.Message)
    }
}
Write-Output ("Uploaded: {0}/{1}" -f $uploaded.Count, $okBy.Count)

# ---------- [5/6] VERIFY ----------
Write-Output ""
Write-Output ("=== [5/6] Verify sau {0}s ===" -f $VerifyWaitSeconds)
$verifyOk = @{}
if ($uploaded.Count -gt 0) {
    Start-Sleep -Seconds $VerifyWaitSeconds
    $fresh = Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Headers $authHdr -TimeoutSec 30
    $byId = @{}
    foreach ($e in @($fresh.files)) { $byId[$e.id] = $e }
    foreach ($em in $uploaded.Keys) {
        $e = $byId[$uploaded[$em]]
        if ($null -ne $e -and $e.status -eq "active" -and -not $e.disabled) {
            $verifyOk[$em] = $true
            Add-Report "verify" $em $uploaded[$em] "ACTIVE"
            Write-Output ("  OK {0}: active" -f $em)
        } else {
            $st = if ($null -ne $e) { $e.status } else { "MISSING" }
            Add-Report "verify" $em $uploaded[$em] "van $st"
            Write-Output ("  ! {0}: status={1}" -f $em, $st)
        }
    }
}

} finally {
    # Don tmpDir chua password + out/ de lan sau sach
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $gptOut) { Remove-Item (Join-Path $gptOut "*") -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------- [6/6] BAO CAO + NOTIFY ----------
Write-Output ""
$csvPath = Join-Path $logsDir ("add-accounts-{0}.csv" -f $runStamp)
$report | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
$failedCount = $failBy.Count + $skipped.Count
Write-Output ("Tong ket: moi={0} | loginOK={1} | uploaded={2} | verifyActive={3} | dup={4} | fail/skip={5}" -f `
    $queued.Count, $okBy.Count, $uploaded.Count, $verifyOk.Count, $dupCount, $failedCount)
Write-Output ("CSV: {0}" -f $csvPath)

if ($Notify -and $WebhookUrl -and $failedCount -gt 0) {
    $failList = @()
    foreach ($em in $failBy.Keys) { $failList += ("- {0}" -f $em) }
    foreach ($em in $skipped)     { $failList += ("- {0} [SKIPPED/TIMEOUT]" -f $em) }
    $text = "[CLIProxyAPI] add-accounts: uploaded=$($uploaded.Count) fail=$failedCount`n" + ($failList -join "`n")
    try {
        if ($WebhookUrl -match "discord") {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body (@{ username = "cliproxy-monitor"; content = $text } | ConvertTo-Json) -ContentType "application/json" | Out-Null
        } else {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body (@{ chat_id = $env:TELEGRAM_CHAT_ID; text = $text } | ConvertTo-Json) -ContentType "application/json" | Out-Null
        }
        Write-Output "Notify: da gui."
    } catch { Write-Output "Notify loi: $($_.Exception.Message)" }
}

if ($failedCount -gt 0) { exit 1 } else { exit 0 }
} finally {
    if ($script:runMutex) {
        try { $script:runMutex.ReleaseMutex() | Out-Null } catch {}
        $script:runMutex.Dispose()
    }
}
