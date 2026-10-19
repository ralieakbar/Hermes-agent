#Requires -Version 5.1
<#
  9Router permanen di Windows + akses dari HP via Tailscale.
  Jalankan di PowerShell "Run as Administrator":
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\tailscale\setup-windows.ps1            # atau: .\tailscale\setup-windows.ps1 -Port 20128
#>
param([int]$Port = 20128)
$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Step($m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function Test-Port { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); $true } catch { $false } }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Jalankan PowerShell sebagai Administrator.'
}

Step '1. Deteksi 9Router'
$node = (Get-Command node -ErrorAction Stop).Source
$cli = Join-Path ((& npm root -g) | Out-String).Trim() '9router\cli.js'
if (-not (Test-Path $cli)) { throw '9router belum terinstall. Jalankan: npm i -g 9router' }
Ok "9router: $cli"

# Autostart bawaan 9Router bind 0.0.0.0 dan berebut port
$vbs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\9router.vbs'
if (Test-Path $vbs) { Remove-Item $vbs -Force; Ok 'Autostart bawaan 9Router (0.0.0.0) dinonaktifkan' }

Step '2. Jadikan 9Router permanen (Task Scheduler, saat boot, tanpa perlu login)'
# Tanpa konsol, cli.js hanya stabil dengan --skip-update
$argLine = "`"$cli`" --no-browser --skip-update --host 127.0.0.1 --port $Port"
$action    = New-ScheduledTaskAction -Execute $node -Argument $argLine -WorkingDirectory $env:USERPROFILE
$trigger   = New-ScheduledTaskTrigger -AtStartup
# S4U: jalan sebagai user ini (data %APPDATA%\9router tetap sama) tanpa menyimpan password
$principal = New-ScheduledTaskPrincipal -UserId $id.Name -LogonType S4U -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName '9Router' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName '9Router'
$ready = $false
foreach ($i in 1..300) { if (Test-Port) { $ready = $true; break }; Start-Sleep 1 }
if (-not $ready) { throw "9Router tidak merespons di port $Port. Cek Task Scheduler > 9Router > History." }
Ok "9Router merespons di http://127.0.0.1:$Port (Task Scheduler: 9Router)"

Step '3. Tailscale'
$ts = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $ts)) {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
  } else { throw 'Install Tailscale dari https://tailscale.com/download/windows lalu ulangi skrip.' }
}
if (-not (Test-Path $ts)) { throw 'Instalasi Tailscale gagal.' }
$state = try { (& $ts status --json | ConvertFrom-Json).BackendState } catch { '' }
if ($state -ne 'Running') {
  if ($env:TAILSCALE_AUTHKEY) { & $ts up --auth-key $env:TAILSCALE_AUTHKEY } else { Warn 'Login di browser yang terbuka...'; & $ts up }
}
Ok 'Tailscale login'

Step '4. Expose ke tailnet (HTTPS)'
if (-not ((& $ts serve status --json | Out-String) -match "127.0.0.1:$Port")) {
  Warn 'Jika diminta, aktifkan HTTPS/Serve lewat URL yang muncul (sekali per tailnet)'
  & $ts serve --bg "http://127.0.0.1:$Port"
}
$dns = ((& $ts status --json | ConvertFrom-Json).Self.DNSName).TrimEnd('.')
Ok "tailscale serve: https://$dns -> 127.0.0.1:$Port"

Step 'Selesai'
Write-Host ""
Write-Host "  Dari HP/laptop (tailnet) : https://$dns/v1"
Write-Host "  Dashboard dari HP        : https://$dns/dashboard"
Write-Host "  Di PC ini                : http://127.0.0.1:$Port/v1"
Write-Host ""
Write-Host "  Hermes (WSL/Git Bash) di PC ini:"
Write-Host "     NINEROUTER_URL=https://$dns/v1 bash fix-9router.sh"
