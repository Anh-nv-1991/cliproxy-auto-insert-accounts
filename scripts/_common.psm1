# _common.psm1 — module dung chung cho cac script quan tri CLIProxyAPI pool
#   check-auths.ps1 / auto-refresh-dead.ps1 / add-accounts.ps1
# Import:  Import-Module (Join-Path $PSScriptRoot "_common.psm1")
# Cac path resolve TU THU MUC scripts\ (tam dem $PSScriptRoot)

Set-StrictMode -Off

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:EnvFile = Join-Path $RepoRoot ".env"
$script:GptRoot = Join-Path $RepoRoot "gpt-tool"
$script:GptOut = Join-Path $GptRoot "out"
$script:GptPy = Join-Path $GptRoot ".venv\Scripts\python.exe"
$script:LogsDir = Join-Path $RepoRoot "logs"
$script:ApiBaseDefault = "http://localhost:8317"

# --- API helpers ---

function Get-MgmtKey {
    $k = (Get-Content $script:EnvFile | Where-Object { $_ -match "^MANAGEMENT_KEY=" }) -replace "^MANAGEMENT_KEY=", ""
    if (-not $k) { throw "Khong tim thay MANAGEMENT_KEY trong $script:EnvFile" }
    return $k
}

function Get-AuthEntries {
    param([string]$ApiKey, [string]$ApiBase = "http://localhost:8317")
    try {
        $resp = Invoke-WebRequest -Uri "$ApiBase/v0/management/auth-files" `
            -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 90 -UseBasicParsing
        return @((($resp.Content | ConvertFrom-Json)).files)
    } catch {
        throw "Khong goi duoc management API: $($_.Exception.Message)"
    }
}

# --- Text helpers ---

function Redact([string]$s, [int]$limit = 140) {
    if (-not $s) { return "" }
    $s = ($s -replace "`r|`n", " ")
    if ($s.Length -gt $limit) { $s = $s.Substring(0, $limit) + "..." }
    return $s
}

# --- Classification ---

# Trang thai cua auth entry (thu tu: DEAD truoc)
function Classify-EntryStatus([string]$msg) {
    $m = if ($null -ne $msg) { $msg.ToLower() } else { "" }
    if (-not $m) { return "OTHER" }
    if ($m -match 'invalidated|token expired|refresh.?token.*(invalid|fail)') { return "DEAD" }
    if ($m -match 'usage_limit|quota') { return "QUOTA" }
    if ($m -match 'overloaded|unavailable|rate|timeout') { return "TRANSIENT" }
    return "OTHER"
}

# Loi re-login cua gpt-tool (quyet dinh giu/xoa file)
function Classify-LoginFail([string]$err) {
    $e = if ($null -ne $err) { $err.ToLower() } else { "" }
    if ($e -match 'locked|deactivated|banned') { return "DEACTIVATED" }
    if ($e -match 'add.?phone') { return "ADD_PHONE" }
    if ($e -match 'invalid email or password|password_incorrect|credential') { return "BAD_CREDENTIALS" }
    if ($e -match 'mfa') { return "BAD_MFA" }
    return "NETWORK"
}

# --- Source creds ---

function Get-CredMap {
    param([string[]]$SourceFiles)
    $map = @{}
    foreach ($f in $SourceFiles) {
        if (-not (Test-Path $f)) { continue }
        foreach ($l in (Get-Content $f)) {
            $t = $l.Trim()
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

# --- Upload mot auth file qua management API ---
# Returns $true khi OK
function Send-AuthFile {
    param(
        [string]$ApiBase = "http://localhost:8317",
        [string]$ApiKey,
        [string]$SourcePath,      # du dan tuyet doi cua file nguon (dia: out/...)
        [string]$TargetName,      # ten file de luu trong pool
        [switch]$Replace          # neu entry da ton tai: xoa truoc
    )
    $enc = [uri]::EscapeDataString($TargetName)
    if ($Replace) {
        try {
            Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files?name=$enc" -Method Delete -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 30 | Out-Null
        } catch {}
    }
    $form = @{ file = $SourcePath }
    try {
        Invoke-RestMethod -Uri "$ApiBase/v0/management/auth-files" -Method Post -Headers @{ Authorization = "Bearer $ApiKey" } -Form $form -TimeoutSec 60 | Out-Null
        return $true
    } catch {
        Write-Output ("  ! upload loi ({0}): {1}" -f $TargetName, $_.Exception.Message)
        return $false
    }
}

# --- Verify sau upload: status = active ---
# Returns hashtable email -> $true khi active
function Confirm-AuthState {
    param(
        [string]$ApiBase = "http://localhost:8317",
        [string]$ApiKey,
        [System.Collections.IDictionary]$Uploaded,   # email -> auth file name
        [int]$WaitSeconds = 45
    )
    $verifyOk = @{}
    if ($uploaded.Count -eq 0) { return $verifyOk }
    Start-Sleep -Seconds $VerifyWaitSeconds
    $fresh = ((Invoke-WebRequest -Uri "$ApiBase/v0/management/auth-files" -Headers @{ Authorization = "Bearer $ApiKey" } -TimeoutSec 90 -UseBasicParsing).Content | ConvertFrom-Json).files
    $byId = @{}
    foreach ($e in @($fresh.files)) { $byId[$e.id] = $e }
    foreach ($em in $uploaded.Keys) {
        $e = $byId[$uploaded[$em]]
        if ($null -ne $e -and $e.status -eq "active" -and -not $e.disabled) {
            $verifyOk[$em] = $true
            Write-Output ("  OK {0}: active" -f $em)
        } else {
            $st = if ($null -ne $e) { $e.status } else { "MISSING" }
            Write-Output ("  ! {0}: status={1}" -f $em, $st)
        }
    }
    return $verifyOk
}

# --- Notify webhook (Discord/Telegram) ---

function Send-Notify {
    param([string]$WebhookUrl, [string]$Text)
    if (-not $WebhookUrl) { return }
    try {
        if ($WebhookUrl -match "discord") {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body (@{ username = "cliproxy-monitor"; content = $Text } | ConvertTo-Json) -ContentType "application/json" | Out-Null
        } else {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body (@{ chat_id = $env:TELEGRAM_CHAT_ID; text = $Text } | ConvertTo-Json) -ContentType "application/json" | Out-Null
        }
        Write-Output "Notify: da gui."
    } catch { Write-Output "Notify loi: $($_.Exception.Message)" }
}

# --- Mutex helper (Release + Dispose an toan) ---

function Release-RunMutex($Mutex) {
    if ($Mutex) {
        try { $Mutex.ReleaseMutex() | Out-Null } catch {}
        try { $Mutex.Dispose() } catch {}
    }
}

# --- Env runtime cho gpt-tool (UTF-8 stdout chan cp1252 crash) ---

function Set-GptToolRuntime {
    $env:PYTHONIOENCODING = "utf-8"
}

# --- Tach dong OK/FAIL tu stdout cua gpt-tool ---
# Returns hashtable email->|>state
function Get-GptRunResults {
    param([string]$StdoutFile, [string]$OutRoot)
    $okBy = @{}; $failBy = @{}
    $soText = (Get-Content $StdoutFile -Raw -ErrorAction SilentlyContinue)
    if (-not $soText) { $soText = "" }
    foreach ($l in ($soText -split "`n")) {
        if ($l -match '^\s*OK\s+(\S+)\s+(.+)$') { $okBy[$Matches[1].ToLower()] = $true }
        elseif ($l -match '^\s*FAIL\s+(\S+)\s+(.+)$') { $failBy[$Matches[1].ToLower()] = $Matches[2] }
    }
    Get-ChildItem $OutRoot -Filter "*.json" -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $j = Get-Content $_.FullName -Raw | ConvertFrom-Json
            if ($j.email) { $okBy[$j.email.ToLower()] = $true }
        } catch {}
    }
    return @{ OkBy = $okBy; FailBy = $failBy }
}

# --- assures Write-Output khac nhau khong ban ---
Export-ModuleMember -Function `
    Get-MgmtKey, Get-AuthEntries, Redact, Classify-EntryStatus, Classify-LoginFail, `
    Get-CredMap, Send-AuthFile, Confirm-AuthState, Send-Notify, `
    Release-RunMutex, Set-GptToolRuntime, Get-GptRunResults
