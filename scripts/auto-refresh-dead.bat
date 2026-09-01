@echo off
setlocal
rem Launcher de double-click cho auto-refresh-dead.ps1 (yeu cau PowerShell 7 / pwsh)
rem - Khong tham so : che do TUONG TAC (tu kiem tra + hoi xac nhan truoc khi chay that)
rem - Co tham so    : truyen thang. Vi du:
rem     auto-refresh-dead.bat -Execute -MaxAccounts 5
rem     auto-refresh-dead.bat -Execute -Notify -WebhookUrl https://discord.com/api/webhooks/xxx
where pwsh >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
  echo Can PowerShell 7 ^(pwsh^). Tai: https://aka.ms/powershell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto-refresh-dead.ps1" %*
endlocal
