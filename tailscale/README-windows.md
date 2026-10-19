# 9Router Permanen di Windows + Tailscale

## Otomatis (disarankan)

PowerShell **Run as Administrator**, dari folder kit:

```powershell
npm i -g 9router                                   # jika belum
Set-ExecutionPolicy -Scope Process Bypass -Force
.\tailscale\setup-windows.ps1                      # opsional: -Port 20128
```

Skrip ini:
1. Menonaktifkan autostart bawaan 9Router (`Startup\9router.vbs`, bind `0.0.0.0`).
2. Mendaftarkan Task Scheduler `9Router` — jalan saat boot tanpa perlu login (S4U, akun Anda,
   data `%APPDATA%\9router` tetap sama), restart otomatis bila gagal, bind `127.0.0.1`.
3. Menginstall Tailscale (winget), login, lalu `tailscale serve --bg http://127.0.0.1:20128`.

## Manual (jika tidak bisa menjalankan skrip)

Path yang benar adalah `cli.js` dan **wajib** memakai `--skip-update` (tanpa konsol,
9Router menampilkan menu interaktif lalu berhenti jika flag ini tidak ada).

```powershell
$node = (Get-Command node).Source
$cli  = Join-Path (npm root -g).Trim() '9router\cli.js'
nssm install 9router $node "`"$cli`" --no-browser --skip-update --host 127.0.0.1 --port 20128"
nssm set 9router ObjectName ".\$env:USERNAME" "<password-windows>"   # agar memakai %APPDATA% Anda
nssm set 9router Start SERVICE_AUTO_START
nssm start 9router

& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg http://127.0.0.1:20128
```

## Hermes di Windows (WSL / Git Bash)

```bash
NINEROUTER_URL=https://<hostname>.<tailnet>.ts.net/v1 bash fix-9router.sh
```

## Akses dari HP

1. Install Tailscale di HP (Play Store / App Store), login akun yang sama.
2. Dashboard: `https://<hostname-pc>.<tailnet>.ts.net/dashboard`
3. Endpoint API: `https://<hostname-pc>.<tailnet>.ts.net/v1`
