# auto-refresh-dead.ps1 - Tu dong phuc hoi tai khoan bi chet token (DEAD)
# Plan: docs/auto-refresh-dead-plan.md (v3)
#
# Cach dung:
#   .\scripts\auto-refresh-dead.ps1                 -> DryRun (chi liet ke, khong xoá/khong login)
#   .\scripts\auto-refresh-dead.ps1 -Execute        -> chay that toan bo acc dead
#   .\scripts\auto-refresh-dead.ps1 -Execute -MaxAccounts 2 -TimeoutMinutes 12   -> chay thu nho
#
# Exit code: 0 = xong sach / khong co acc dead · 1 = con acc loi (retry lan sau) · 2 = loi API/cau hinh

param(
    [switch]$Execute,
    [switch]$Pause,
    [int]$LoginDelaySeconds = 20,
    [int]$Workers = 2,
    [int]$TimeoutMinutes = 45,
    [int]$MaxAccounts = 0,
    [int]$VerifyWaitSeconds = 45,
    [int]$MinInvalidProbes = 2,
    [double]$ProbeDelaySeconds = 5,
    [switch]$SkipProbe,
    [string]$Proxy = "",
    [string]$ApiBase = "http://localhost:8317",
    [switch]$Notify,
    [string]$WebhookUrl = ""
)

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $root ".env"
$gptRoot = Join-Path $root "gpt-tool"
$gptOut  = Join-Path $gptRoot "out"
$gptPy   = Join-Path $gptRoot ".venv\Scripts\python.exe"
$logsDir = Join-Path $root "logs"
# Nguon creds: TU DONG lay tat ca file free-acc*.txt trong gpt-tool
# (bo qua test-fake.txt / file khac; tu thich ung khi them batch moi hoac doi ten file)
$sourceFiles = @(Get-ChildItem $gptRoot -Filter "free-acc*.txt" -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)

# Che do tuong tac: chay KHONG tham so (double-click .bat / tu terminal khong args)
# -> coi nhu nguoi dang ngoai console: hoi xac nhan truoc khi chay that + giua cua so mo.
# Co BAT KY tham so nao -> che do tu dong (Task Scheduler / CLI), khong pause khong hoi.
$interactive = ($PSBoundParameters.Count -eq 0) -or $Pause

# ---------- helpers ----------

function Redact([string]$s) {
    if (-not $s) { return "" }
    $s = ($s -replace "`r|`n", " ")
    if ($s.Length -gt 140) { $s = $s.Substring(0, 140) + "..." }
    return $s
}

# Read-Host an toan: non-interactive (scheduler/quen -Execute) -> tra ve rong thay vi crash
function Read-HostSafe([string]$prompt) {
    try { return (Read-Host $prompt) } catch { return "" }
}

# Phan loai status_message cua auth entry (thu tu quan trong: DEAD truoc)
function Classify-EntryStatus([string]$msg) {
    $m = if ($null -ne $msg) { $msg.ToLower() } else { "" }
    if (-not $m) { return "OTHER" }
    if ($m -match 'invalidated|token expired|refresh.?token.*(invalid|fail)') { return "DEAD" }
    if ($m -match 'usage_limit|quota')   { return "QUOTA" }
    if ($m -match 'overloaded|unavailable|rate|timeout') { return "TRANSIENT" }
    return "OTHER"
}

# Phan loai loi re-login cua gpt-tool (de quyet dinh xoá/giu)
function Classify-LoginFail([string]$err) {
    $e = if ($null -ne $err) { $err.ToLower() } else { "" }
    if ($e -match 'locked|deactivated|banned')      { return "DEACTIVATED" }
    if ($e -match 'add.?phone')                     { return "ADD_PHONE" }
    if ($e -match 'invalid email or password|password_incorrect|credential') { return "BAD_CREDENTIALS" }
    if ($e -match 'mfa')                            { return "BAD_MFA" }
    return "NETWORK"   # giu lai, retry lan sau
}

$MgmtKey = (Get-Content $envFile | Where-Object { $_ -match "^MANAGEMENT_KEY=" }) -replace "^MANAGEMENT_KEY=", ""
if (-not $MgmtKey) {
    Write-Output "Khong tim thay MANAGEMENT_KEY trong $envFile"
    if ($interactive) { Read-HostSafe "Nhan Enter de thoat" | Out-Null }
    exit 2
}
$authHdr = @{ Authorization = "Bearer $MgmtKey" }

# BUG-FIX: gpt-tool print "→" (U+2192) - khi stdout redirect ve cp1252 se crash UnicodeEncodeError
$env:PYTHONIOENCODING = "utf-8"

# FIX #7: chong chay trung lap - 2 tien trinh cung luc se dam nhau vao OpenAI
$script:runMutex = New-Object System.Threading.Mutex($false, "Global\cliproxy-auto-refresh-dead")
# Outer try/finally: bao dam release mutex tren MOI exit path (ca DryRun / early-exit)
try {
if (-not $script:runMutex.WaitOne(0)) {
    Write-Output "Script auto-refresh-dead DANG CHAY trong tien trinh khac -> thoat."
    exit 2
}

function Get-AuthEntries {
    $resp = Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Headers $authHdr -TimeoutSec 30
    return @($resp.files)
}

function Remove-AuthFileByName([string]$name) {
    $enc = [uri]::EscapeDataString($name)
    Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files?name=$enc" -Method Delete -Headers $authHdr -TimeoutSec 30 | Out-Null
}

# Doc source txt: email|pass|totp  (bo header / dong loi)
function Get-CredMap {
    $map = @{}
    foreach ($f in $sourceFiles) {
        if (-not (Test-Path $f)) { continue }
        foreach ($line in (Get-Content $f)) {
            $t = $line.Trim()
            if (-not $t -or $t.StartsWith("#")) { continue }
            $parts = $t -split '\|'
            if ($parts.Count -lt 2) { continue }
            $email = $parts[0].Trim().ToLower()
            if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { continue }
            if (-not $map.ContainsKey($email)) { $map[$email] = $t }
        }
    }
    return $map
}

$report = [System.Collections.Generic.List[object]]::new()
function Add-Report([string]$phase, [string]$email, [string]$file, [string]$detail) {
    $report.Add([pscustomobject]@{
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        phase     = $phase
        email     = $email
        auth_file = $file
        detail    = (Redact $detail)
    })
}

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Force $logsDir | Out-Null
$mode = if ($Execute) { 'EXECUTE' } elseif ($interactive) { 'INTERACTIVE' } else { 'DRYRUN' }
Write-Output "[$stamp] auto-refresh-dead | mode=$mode"

# ---------- [1/9] PHAT HIEN ----------
Write-Output ""
Write-Output "=== [1/9] PHAT HIEN acc dead ==="
try {
    $entries = Get-AuthEntries
} catch {
    Write-Output "Khong goi duoc management API: $($_.Exception.Message)"
    exit 2
}

$all      = @($entries)
# FIX #9: chi xu ly auth file (bo qua runtime-only/API-key neu co)
$dead     = @($all | Where-Object { $_.status -eq "error" -and -not $_.disabled -and $_.source -eq "file" -and (Classify-EntryStatus $_.status_message) -eq "DEAD" })
$otherErr = @($all | Where-Object { $_.status -eq "error" -and -not $_.disabled -and $_.source -eq "file" -and (Classify-EntryStatus $_.status_message) -eq "OTHER" })
Write-Output ("Total={0} | DEAD={1} | OTHER_status={2} (chi bao cao, khong xu ly)" -f $all.Count, $dead.Count, $otherErr.Count)
foreach ($e in $otherErr) { Add-Report "detect" $e.email $e.id "OTHER status: $(Redact $e.status_message)" }

if ($dead.Count -eq 0) {
    Write-Output "Khong co acc dead. Khong lam gi."
    if ($report.Count -gt 0 -and -not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }
    if ($report.Count -gt 0) { $report | Export-Csv (Join-Path $logsDir ("auto-refresh-{0}.csv" -f $runStamp)) -NoTypeInformation -Encoding UTF8 }
    exit 0
}

# ---------- [2/9] SO KHOP nguon ----------
Write-Output ""
Write-Output "=== [2/9] SO KHOP voi source txt ==="
$credMap = Get-CredMap
Write-Output ("Emails trong source: {0} (tu {1} file)" -f $credMap.Count, $sourceFiles.Count)

$matched   = @()
$unmatched = @()
foreach ($d in ($dead | Sort-Object email)) {
    $em = $d.email.ToLower()
    if ($credMap.ContainsKey($em)) { $matched += [pscustomobject]@{ Entry = $d; Line = $credMap[$em] } }
    else { $unmatched += $d; Add-Report "match" $d.email $d.id "KHONG CO trong source -> cho xu ly tay" }
}
Write-Output ("Match duoc: {0}/{1} | Thieu creds: {2}" -f $matched.Count, $dead.Count, $unmatched.Count)
if ($unmatched.Count -gt 0) {
    $unmatched | ForEach-Object { Write-Output ("  - (khong co creds) {0}" -f $_.email) }
}

if ($MaxAccounts -gt 0 -and $matched.Count -gt $MaxAccounts) {
    Write-Output ("Gioi han -MaxAccounts {0}: xu ly {1} acc dau tien (sorted theo email)" -f $MaxAccounts, $MaxAccounts)
    $matched = $matched | Select-Object -First $MaxAccounts
}

if (-not $Execute) {
    Write-Output ""
    Write-Output "=== DRYRUN — ket qua du kien ==="
    Write-Output ("Se PROBE {0} acc bang refresh_token (KHONG login) | re-login chi voi acc INVALID x{1} probe lien tiep | delay {2}s | timeout tong {3} phut" -f $matched.Count, $MinInvalidProbes, $LoginDelaySeconds, $TimeoutMinutes)
    $matched | ForEach-Object { Write-Output ("  * {0}  ->  {1}" -f $_.Entry.email, $_.Entry.id) }
    if ($interactive) {
        # Che do tuong tac: hoi nguoi dung truoc khi chay (probe + re-login co dieu kien)
        if ($matched.Count -gt 0) {
            $ok = Read-HostSafe ("Chay PROBE token + xu ly {0} acc (re-login CHI ap dung cho acc probe xac nhan chet)? (y/N)" -f $matched.Count)
            if ($ok -in @("y", "Y", "yes")) { $Execute = $true }
            else { Write-Output "Da huy - khong co hanh dong nao duoc thuc hien."; exit 0 }
        } else {
            Write-Output "Khong co acc dead can xu ly."
            exit 0
        }
    } else {
        Write-Output "DryRun khong thuc hien bat cu hanh dong nao. Them -Execute de chay that."
        exit 0
    }
}

# ---------- [3/9] DON out/ ----------
# FIX #2: mo vung try/finally bao dam LUON don tmpDir (chua password) ke ca crash/exit giua chung
try {
# Don cac tmpDir le tu nhung lan chay crash truoc (an toan: mutex da chong chay trung)
Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter "gpt-refresh-*" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ""
Write-Output "=== [3/9] Don gpt-tool\out ==="
if (Test-Path $gptOut) { Remove-Item (Join-Path $gptOut "*") -Recurse -Force }
New-Item -ItemType Directory -Force $gptOut | Out-Null
Write-Output "out/ da don sach."

# ---------- [4/9] GENERATE (re-login) - CHI voi acc probe xac nhan chet ----------
# (header in sau khi probe chay xong - xem cuoi phan [3b])

$deadline  = (Get-Date).AddMinutes($TimeoutMinutes)
$tmpDir    = Join-Path ([System.IO.Path]::GetTempPath()) ("gpt-refresh-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $tmpDir | Out-Null
$tmpLines  = Join-Path $tmpDir "lines.txt"
$soLog     = Join-Path $tmpDir "stdout.log"
$seLog     = Join-Path $tmpDir "stderr.log"

if (-not (Test-Path $gptPy)) { Write-Output "Khong thay python venv: $gptPy"; exit 2 }

$okBy    = @{}   # email -> $true (bao gom ca probe-heal va re-login thanh cong)
$failBy  = @{}   # email -> error text
$skipped = @()
$timedOut = $false

# ---------- [3b] PROBE refresh_token (KHONG login) ----------
# Kiem tra token con song bang 1 request refresh - giong nhịp bình thường, khong tao signal bi scan.
# Chi re-login acc bi INVALID x $MinInvalidProbes lien tiep (lan luot qua cac lan chay) - tranh scan song.
$probeFixed = @{}; $probeWait = @{}; $toRelogin = @{}
$reloginMatched = @()
if ($SkipProbe) {
    foreach ($m in $matched) { $toRelogin[$m.Entry.email.ToLower()] = $m }
    Write-Output ""
    Write-Output "=== [3b] PROBE bo qua (-SkipProbe) -> re-login toan bo acc matched ==="
} else {
    Write-Output ""
    Write-Output "=== [3b] PROBE refresh_token (KHONG login) ==="
    $probeDir = Join-Path $tmpDir "probe"
    New-Item -ItemType Directory -Force $probeDir | Out-Null
    $manifestLines = @()
    foreach ($m in $matched) {
        $name = $m.Entry.id
        $dest = Join-Path $probeDir $name
        try {
            $enc = [uri]::EscapeDataString($name)
            Invoke-WebRequest -Uri "$ApiBase/v0/management/auth-files/download?name=$enc" -Headers $authHdr -OutFile $dest -TimeoutSec 30
            $manifestLines += ("{0}|{1}" -f $m.Entry.email, $dest)
        } catch {
            Write-Output ("  ! {0}: download auth file loi ({1}) -> dua vao hang re-login" -f $m.Entry.email, (Redact $_.Exception.Message))
            $toRelogin[$m.Entry.email.ToLower()] = $m
        }
    }
    if ($manifestLines.Count -gt 0) {
        $manifestFile = Join-Path $tmpDir "manifest.txt"
        Set-Content -Path $manifestFile -Value $manifestLines -Encoding UTF8
        $probeOut = Join-Path $tmpDir "probe-stdout.log"
        $pArgs = @('-X','utf8','probe_refresh.py','--manifest', ('"{0}"' -f $manifestFile), '--out', ('"{0}"' -f $gptOut), '--delay', ("{0}" -f $ProbeDelaySeconds))
        if ($Proxy) { $pArgs += @('--proxy', $Proxy) }
        $pp = Start-Process -FilePath $gptPy -ArgumentList $pArgs -WorkingDirectory $gptRoot -NoNewWindow -PassThru -RedirectStandardOutput $probeOut -RedirectStandardError (Join-Path $tmpDir "probe-stderr.log")
        $remainMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
        if ($remainMs -le 0 -or -not $pp.WaitForExit($remainMs)) {
            try { $pp.Kill($true) } catch {}
            Write-Output "Probe treo qua timeout -> coi nhu TRANSIENT, xu ly lan sau."
        }
        $probeText = (Get-Content $probeOut -Raw -ErrorAction SilentlyContinue) ?? ""
        $histFile = Join-Path $logsDir "probe-history.csv"
        foreach ($ln in ($probeText -split "`n")) {
            if ($ln -match '^(OK|INVALID|TRANSIENT)\|([^|]+)\|(.*)$') {
                [pscustomobject]@{
                    timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    email     = $Matches[2].ToLower()
                    verdict   = $Matches[1]
                    detail    = (Redact $Matches[3])
                } | Export-Csv $histFile -NoTypeInformation -Encoding UTF8 -Append
                Write-Output ("  probe {0}: {1}" -f $Matches[2].ToLower(), $Matches[1])
            }
        }
        $hist = @(); if (Test-Path $histFile) { $hist = @(Import-Csv $histFile) }
        foreach ($m in $matched) {
            $em = $m.Entry.email.ToLower()
            $rowsE = @($hist | Where-Object { $_.email -eq $em } | Sort-Object timestamp)
            $lastV = if ($rowsE.Count) { $rowsE[-1].verdict } else { "TRANSIENT" }
            if ($lastV -eq "OK") {
                # refresh thanh cong: token moi da ghi vao out/ - upload lai la heal, KHONG can login
                $probeFixed[$em] = $m
                $okBy[$em] = $true
            } elseif ($lastV -eq "INVALID") {
                $n = 0
                for ($i = $rowsE.Count - 1; $i -ge 0; $i--) { if ($rowsE[$i].verdict -eq "INVALID") { $n++ } else { break } }
                if ($n -ge $MinInvalidProbes) { $toRelogin[$em] = $m }
                else { $probeWait[$em] = "INVALID x$n - cho dat nguong $MinInvalidProbes lan probe lien tiep" }
            } else {
                $probeWait[$em] = "TRANSIENT - probe lai lan sau"
            }
        }
        Write-Output ("Probe tong hop: heal={0} | cho={1} | re-login={2}" -f $probeFixed.Count, $probeWait.Count, $toRelogin.Count)
        foreach ($k in $probeFixed.Keys) { Add-Report "probe" $k "" "OK - refresh thanh cong, upload token moi (khong login)" }
        foreach ($k in $probeWait.Keys)  { Write-Output ("  WAIT {0}: {1}" -f $k, $probeWait[$k]); Add-Report "probe" $k "" "WAIT: $($probeWait[$k])" }
        foreach ($k in $toRelogin.Keys)  { Add-Report "probe" $k "" "INVALID du nguong -> re-login" }
    }
}
# Xac nhan lan cuoi trong che do tuong tac truoc khi re-login
if ($interactive -and $toRelogin.Count -gt 0) {
    $ok2 = Read-HostSafe ("Re-login THAT {0} acc (INVALID x{1} probe lien tiep)? (y/N)" -f $toRelogin.Count, $MinInvalidProbes)
    if ($ok2 -notin @("y", "Y", "yes")) {
        Write-Output "Bo qua re-login - acc van giu nguyen, lan sau probe tiep."
        foreach ($k in @($toRelogin.Keys)) { $probeWait[$k] = "tu choi re-login - probe lai lan sau"; $toRelogin.Remove($k) }
    }
}
$reloginMatched = @($matched | Where-Object { $toRelogin.ContainsKey($_.Entry.email.ToLower()) })

# ---------- [4/9] header ----------
Write-Output ""
if ($reloginMatched.Count -eq 0) {
    Write-Output "=== [4/9] Khong can re-login (probe da heal het / chua du nguong xac nhan) ==="
} else {
    Write-Output ("=== [4/9] Re-login qua gpt-tool ({0} acc xac nhan chet) ===" -f $reloginMatched.Count)
}

$chunks = @()
for ($i = 0; $i -lt $reloginMatched.Count; $i += $Workers) {
    $end = [Math]::Min($i + $Workers - 1, $reloginMatched.Count - 1)
    $chunks += ,@($reloginMatched[$i..$end])
}

$chunkNo = 0
foreach ($chunk in $chunks) {
    $chunkNo++
    if ((Get-Date) -gt $deadline) {
        Write-Output "Het thoi gian ($TimeoutMinutes phut) - bo qua phan con lai (retry lan sau)."
        $timedOut = $true
        break
    }
    $emails = ($chunk | ForEach-Object { $_.Entry.email }) -join ", "
    Write-Output ("-- chunk {0}/{1}: {2}" -f $chunkNo, $chunks.Count, $emails)

    Set-Content -Path $tmpLines -Value @($chunk | ForEach-Object { $_.Line }) -Encoding UTF8
    # -X utf8: buoc python UTF-8 mode (tranh crash U+2192 khi stdout bi redirect)
    $argList = @('-X','utf8','-m','gpt_tool.cli','export','--format','cpa','--lines', ('"{0}"' -f $tmpLines), '--out','out','--workers', ("{0}" -f $Workers))
    if ($Proxy) { $argList += @('--proxy', $Proxy) }

    $proc = Start-Process -FilePath $gptPy -ArgumentList $argList -WorkingDirectory $gptRoot -NoNewWindow -PassThru -RedirectStandardOutput $soLog -RedirectStandardError $seLog
    $remainMs = [int](($deadline - (Get-Date)).TotalMilliseconds)
    if ($remainMs -le 0 -or -not $proc.WaitForExit($remainMs)) {
        try { $proc.Kill($true) } catch {}
        Write-Output "Chunk bi treo qua timeout -> kill. Phan trong chunk nay chua ro ket qua, se xu ly lai lan sau."
        $timedOut = $true
        foreach ($m in $chunk) {
            if ($skipped -notcontains $m.Entry.email) { $skipped += $m.Entry.email }   # FIX #10: dedupe
            Add-Report "generate" $m.Entry.email $m.Entry.id "TIMEOUT chunk - chua xac dinh"
        }
        break
    }

    $soText = (Get-Content $soLog -Raw -ErrorAction SilentlyContinue) ?? ""
    foreach ($ln in ($soText -split "`n")) {
        if ($ln -match '^\s*OK\s+(\S+)\s+(.+)$')      { $okBy[$Matches[1].ToLower()] = $true }
        elseif ($ln -match '^\s*FAIL\s+(\S+)\s+(.+)$') { $failBy[$Matches[1].ToLower()] = $Matches[2] }
    }
    # Fallback: file JSON trong out/ la source of truth cho thanh cong (doc truong email)
    Get-ChildItem $gptOut -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($j.email) { $okBy[$j.email.ToLower()] = $true }
        } catch {}
    }
    # Luu log gpt-tool vao logs/ de audit
    $gptLog = Join-Path $logsDir ("auto-refresh-gpt-{0}.log" -f $runStamp)
    Add-Content $gptLog ("--- chunk {0} stdout ---`n{1}`n--- stderr ---`n{2}" -f $chunkNo, $soText, ((Get-Content $seLog -Raw -ErrorAction SilentlyContinue) ?? ""))
    foreach ($m in $chunk) {
        $em = $m.Entry.email.ToLower()
        if     ($okBy.ContainsKey($em))    { Add-Report "generate" $m.Entry.email $m.Entry.id "OK" }
        elseif ($failBy.ContainsKey($em))  { Add-Report "generate" $m.Entry.email $m.Entry.id "FAIL: $($failBy[$em])" }
        else                               { if ($skipped -notcontains $em) { $skipped += $em }; Add-Report "generate" $m.Entry.email $m.Entry.id "KHONG CO ket qua trong stdout" }
    }
    if ($chunkNo -lt $chunks.Count) { Start-Sleep -Seconds $LoginDelaySeconds }
}

Write-Output ("Login OK: {0} | FAIL: {1} | Bo qua: {2}" -f $okBy.Count, $failBy.Count, $skipped.Count)

# ---------- [5/9] UPLOAD ----------
Write-Output ""
Write-Output "=== [5/9] Upload JSON moi (ghi de dung ten id) ==="
$uploaded = @{}   # email -> targetName

if ($okBy.Count -gt 0) {
    # map email -> file vua tao (doc truong email trong json, khong tin ten file)
    $jsonByEmail = @{}
    Get-ChildItem $gptOut -Filter "*.json" -File | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($j.email) { $jsonByEmail[$j.email.ToLower()] = $_.FullName }
        } catch { Add-Report "upload" "" $_.Name "JSON khong doc duoc: $($_.Exception.Message)" }
    }

    foreach ($m in $matched) {
        $em = $m.Entry.email.ToLower()
        if (-not $okBy.ContainsKey($em)) { continue }
        if (-not $jsonByEmail.ContainsKey($em)) {
            Write-Output ("  ! {0}: gpt-tool bao OK nhung khong thay JSON trong out/ - bo qua" -f $m.Entry.email)
            Add-Report "upload" $m.Entry.email $m.Entry.id "LOI: bao OK nhung khong co JSON"
            $okBy.Remove($em)
            continue
        }
        $targetName = $m.Entry.id
        $tmpName    = Join-Path $tmpDir $targetName
        Copy-Item $jsonByEmail[$em] $tmpName -Force
        try {
            $form = @{ file = Get-Item $tmpName }
            Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Method Post -Headers $authHdr -Form $form -TimeoutSec 60 | Out-Null
            $uploaded[$em] = $targetName
            Add-Report "upload" $m.Entry.email $targetName "OK (ghi de)"
            Write-Output ("  + {0}  ->  {1}" -f $m.Entry.email, $targetName)
        } catch {
            Write-Output ("  ! {0}: upload loi: {1}" -f $m.Entry.email, $_.Exception.Message)
            Add-Report "upload" $m.Entry.email $targetName "UPLOAD LOI: $($_.Exception.Message)"
        }
    }
} else {
    Write-Output "Khong co file nao de upload."
}

# ---------- [6/9] VERIFY ----------
Write-Output ""
Write-Output ("=== [6/9] Verify sau {0}s cho watcher nap lai ===" -f $VerifyWaitSeconds)
$verifyOk = @{}   # email -> $true

if ($uploaded.Count -gt 0) {
    Start-Sleep -Seconds $VerifyWaitSeconds
    $fresh = Get-AuthEntries
    $byId  = @{}
    foreach ($e in $fresh) { $byId[$e.id] = $e }
    foreach ($em in $uploaded.Keys) {
        $name = $uploaded[$em]
        $e = $byId[$name]
        if ($null -eq $e) {
            Write-Output ("  ? {0}: khong thay entry sau upload" -f $em)
            Add-Report "verify" $em $name "KHONG THAY entry sau upload"
            continue
        }
        if ($e.status -eq "active" -and -not $e.disabled) {
            $verifyOk[$em] = $true
            Add-Report "verify" $em $name "ACTIVE"
            Write-Output ("  OK {0}: active" -f $em)
        } else {
            Add-Report "verify" $em $name ("van {0}: {1}" -f $e.status, (Redact $e.status_message))
            Write-Output ("  ! {0}: van status={1}" -f $em, $e.status)
        }
    }
} else {
    Write-Output "Khong co upload nao de verify."
}

# ---------- [7/9] DON NHOT ----------
Write-Output ""
Write-Output "=== [7/9] Don nhot file chet theo matrix ==="
$deletedFiles = @()

foreach ($m in $matched) {
    $em   = $m.Entry.email.ToLower()
    $name = $m.Entry.id

    if ($verifyOk.ContainsKey($em)) { continue }                        # da ho phuc - giu file moi
    if ($uploaded.ContainsKey($em)) { continue }                        # da upload, verify chua ro - giu
    if (-not $failBy.ContainsKey($em)) { continue }                     # skipped/timeout - giu de retry

    $kind = Classify-LoginFail $failBy[$em]
    if ($kind -eq "NETWORK") {
        Add-Report "cleanup" $m.Entry.email $name "GIU LAI (network - retry lan sau)"
        Write-Output ("  KEEP {0} ({1})" -f $m.Entry.email, $kind)
        continue
    }
    try {
        Remove-AuthFileByName $name
        $deletedFiles += $name
        Add-Report "cleanup" $m.Entry.email $name "XOA file chet ($kind)"
        Write-Output ("  DEL  {0} ({1})" -f $m.Entry.email, $kind)
        # Ghi vao ledger banned-accounts (de theo doi + dien tu tang dan)
        $ledger = Join-Path $root "docs\banned-accounts.csv"
        [pscustomobject]@{
            confirmed_date = (Get-Date -Format "yyyy-MM-dd HH:mm")
            email          = $m.Entry.email
            plan           = ($m.Entry.id_token.plan_type ?? "unknown")
            reason         = $kind
            evidence       = "login tra ve lock/deactivate tu OpenAI (403)"
            action         = "auth file da xoa boi script - can xoa line trong free-acc*.txt"
        } | Export-Csv $ledger -NoTypeInformation -Encoding UTF8 -Append
    } catch {
        Add-Report "cleanup" $m.Entry.email $name "XOA LOI: $($_.Exception.Message)"
        Write-Output ("  ! {0}: xoa loi: {1}" -f $m.Entry.email, $_.Exception.Message)
    }
}

# ---------- [8/9] BAO CAO ----------
Write-Output ""
Write-Output "=== [8/9] Bao cao ==="
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory $logsDir | Out-Null }
$csvPath = Join-Path $logsDir ("auto-refresh-{0}.csv" -f $runStamp)
$report | Export-Csv $csvPath -NoTypeInformation -Encoding UTF8
Write-Output ("CSV: {0} ({1} dong)" -f $csvPath, $report.Count)

$fixed        = $verifyOk.Count
$deletedCount = $deletedFiles.Count
# FIX #1: con lai = dead - (da heal/fix) - (da xoa vi khong the hoi phuc)
# (probeWait tinh la con lai - chua xu ly xong, lan sau probe tiep)
$remaining = $dead.Count - $fixed - $deletedCount
Write-Output ("Tong ket: dead={0} | match={1} | probe-heal={2} | probe-wait={3} | re-login={4} | loginOK={5} | uploaded={6} | verifyActive={7} | deleted={8} | con lai={9}" -f `
    $dead.Count, $matched.Count, $probeFixed.Count, $probeWait.Count, $reloginMatched.Count, $okBy.Count, $uploaded.Count, $fixed, $deletedCount, $remaining)
Write-Output ("          (con lai bao gom {0} thieu creds, {1} retry/fail)" -f $unmatched.Count, ($failBy.Count + $skipped.Count + $probeWait.Count))

# ---------- [9/9] NOTIFY (tuy chon) ----------
if ($Notify -and $WebhookUrl) {
    $failList = @()
    foreach ($em in $failBy.Keys)     { $failList += ("- {0} [{1}]" -f $em, (Classify-LoginFail $failBy[$em])) }
    foreach ($em in $skipped)         { $failList += ("- {0} [SKIPPED/TIMEOUT]" -f $em) }
    foreach ($u in $unmatched)        { $failList += ("- {0} [THIEU CREDS]" -f $u.email) }
    if ($failList.Count -gt 0) {
        $text = "[CLIProxyAPI] auto-refresh: fixed=$fixed remaining=$remaining`n" + ($failList -join "`n")
        try {
            if ($WebhookUrl -match "discord") {
                $body = @{ username = "cliproxy-monitor"; content = $text } | ConvertTo-Json
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" | Out-Null
            } else {
                $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $text } | ConvertTo-Json
                Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $body -ContentType "application/json" | Out-Null
            }
            Write-Output "Notify: da gui."
        } catch { Write-Output "Notify loi: $($_.Exception.Message)" }
    } else { Write-Output "Notify: khong co loi, khong gui." }
}

} finally {
    # FIX #2: LUON don tmpDir (chua email|pass|totp) ke ca khi crash / Ctrl+C / exit giua chung
    if ($tmpDir -and (Test-Path $tmpDir)) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($remaining -gt 0) { exit 1 } else { exit 0 }
} finally {
    # FIX #7: release mutex tren MOI exit path - ke ca DryRun/early-exit khong qua inner finally
    if ($script:runMutex) {
        try { $script:runMutex.ReleaseMutex() | Out-Null } catch {}
        $script:runMutex.Dispose()
    }
    # Che do tuong tac: giua cua so mo de nguoi dung doc ket qua
    if ($interactive) {
        Write-Output ""
        Read-HostSafe "Nhan Enter de thoat" | Out-Null
    }
}

