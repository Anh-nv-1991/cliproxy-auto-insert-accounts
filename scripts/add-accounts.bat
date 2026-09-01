@echo off
setlocal
rem Launcher de double-click cho add-accounts.ps1 (yeu cau PowerShell 7 / pwsh)
rem Cach dung:
rem   add-accounts.bat -LinesFile "gpt-tool\free-acc-01-09-2026.txt"
rem     -> TUONG TAC/DryRun: liet ke acc moi, hoi truoc khi chay that
rem     auto-refresh-dead.bat -Execute -MaxAccounts 5
rem     add-accounts.bat -LinesFile "..." -Execute -Notify -WebhookUrl https://discord.com/api/webhooks/xxx
where pwsh >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
  echo Can PowerShell 7 ^(pwsh^). Tai: https://aka.ms/powershell
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0add-accounts.ps1" %*
pause
endlocal
