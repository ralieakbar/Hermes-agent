# 9Router Permanen di Windows + Tailscale

## Auto-start 9Router di Windows

### Metode A — pm2-windows-service (Rekomendasi)

```powershell
# Install pm2 dan module windows service
npm install -g pm2 pm2-windows-service
pm2-service-install -n pm2

# Daftarkan 9Router
pm2 start 9router --name 9router -- --port 20128 --host 127.0.0.1
pm2 save
```

Setelah ini, 9Router otomatis jalan setiap Windows boot meski tidak ada user login.

### Metode B — Task Scheduler (tanpa npm tambahan)

1. Buka **Task Scheduler** (Win+R → `taskschd.msc`)
2. Klik **Create Basic Task** → beri nama `9Router`
3. Trigger: **When the computer starts**
4. Action: **Start a program**
   - Program: `node`
   - Arguments: `C:\Users\<kamu>\AppData\Roaming\npm\node_modules\9router\bin\9router.js --port 20128 --host 127.0.0.1`
5. Centang **Run whether user is logged on or not** → masukkan password
6. Centang **Run with highest privileges**

### Metode C — NSSM (Non-Sucking Service Manager)

```powershell
# Download nssm dari nssm.cc, letakkan di PATH
nssm install 9router node "C:\Users\<kamu>\AppData\Roaming\npm\node_modules\9router\bin\9router.js"
nssm set 9router AppParameters "--port 20128 --host 127.0.0.1"
nssm set 9router Start SERVICE_AUTO_START
nssm start 9router
```

---

## Install Tailscale di Windows

1. Download dari: https://tailscale.com/download/windows
2. Install dan login dengan akun yang sama
3. Buka PowerShell sebagai Admin:

```powershell
# Expose 9Router ke tailnet
tailscale serve --bg http://127.0.0.1:20128
```

4. Cek hostname:

```powershell
tailscale status
```

---

## Update Hermes di Windows

Buka Git Bash atau WSL, lalu:

```bash
NINEROUTER_URL=https://<hostname>.ts.net/v1 bash fix-9router.sh
```

---

## Akses dari HP

1. Install Tailscale di HP (Play Store / App Store)
2. Login dengan akun yang sama
3. Buka browser HP → `https://<hostname-windows>.ts.net`
4. Hermes di HP: set `NINEROUTER_URL=https://<hostname-windows>.ts.net/v1`
