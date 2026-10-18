#!/usr/bin/env bash
# Membuat 9Router permanen di VPS + expose via Tailscale (akses dari HP/lokal)
#
# Prasyarat:
#   - 9Router sudah terinstall: npm i -g 9router  (atau sudah jalan via pm2/docker)
#   - Akses sudo / root
#   - Akun Tailscale (gratis di tailscale.com)
#
# Pemakaian:
#   NINEROUTER_API_KEY=sk-xxx bash setup-vps.sh
#   NINEROUTER_PORT=20128 TAILSCALE_AUTHKEY=tskey-auth-xxx bash setup-vps.sh
#
# Setelah selesai, 9Router dapat diakses dari HP via:
#   https://<hostname>.<tailnet>.ts.net/v1  (Tailscale HTTPS)
#   http://<tailscale-ip>:20128/v1          (HTTP langsung)
set -euo pipefail

NR_PORT="${NINEROUTER_PORT:-20128}"
NR_KEY="${NINEROUTER_API_KEY:-}"
TS_AUTHKEY="${TAILSCALE_AUTHKEY:-}"    # opsional: bisa login interaktif juga
INSTALL_METHOD="${INSTALL_METHOD:-auto}"  # auto | systemd | pm2 | docker

ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR]\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

# ── Deteksi metode instalasi 9Router ──────────────────────────────────────────
step "1. Deteksi instalasi 9Router"

NR_BIN="$(command -v 9router 2>/dev/null || command -v 9-router 2>/dev/null || true)"
NR_DOCKER=0; NR_PM2=0; NR_NATIVE=0

if command -v docker >/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -qi 9router; then
  NR_DOCKER=1; ok "9Router ditemukan di Docker"
elif command -v pm2 >/dev/null && pm2 jlist 2>/dev/null | grep -qi 9router; then
  NR_PM2=1; ok "9Router ditemukan di pm2"
elif [[ -n "$NR_BIN" ]]; then
  NR_NATIVE=1; ok "9Router ditemukan sebagai binary: $NR_BIN"
else
  err "9Router tidak terdeteksi. Install dulu: npm i -g 9router"
  echo "   Lalu jalankan skrip ini lagi."
  exit 1
fi

# Pastikan 9Router sudah jalan dan listening
if ss -ltn 2>/dev/null | grep -q ":$NR_PORT "; then
  ok "9Router sudah listening di port $NR_PORT"
else
  warn "9Router belum listening di port $NR_PORT — mencoba start..."
  if [[ "$NR_DOCKER" == 1 ]]; then
    warn "Jalankan container 9Router secara manual, lalu ulang skrip ini."
    exit 1
  elif [[ "$NR_PM2" == 1 ]]; then
    pm2 start 9router || pm2 restart 9router
  elif [[ -n "$NR_BIN" ]]; then
    nohup "$NR_BIN" --port "$NR_PORT" --host 127.0.0.1 &>/tmp/9router.log &
    sleep 3
    ss -ltn | grep -q ":$NR_PORT " || { err "9Router gagal start. Cek /tmp/9router.log"; exit 1; }
  fi
  ok "9Router berhasil distart"
fi

# ── Jadikan permanen (auto-start) ─────────────────────────────────────────────
step "2. Konfigurasi auto-start 9Router"

if [[ "$NR_PM2" == 1 || ("$NR_NATIVE" == 1 && "$INSTALL_METHOD" == "pm2") ]]; then
  # Metode pm2
  if ! command -v pm2 >/dev/null; then
    npm install -g pm2; ok "pm2 terinstall"
  fi
  if ! pm2 jlist 2>/dev/null | grep -qi 9router; then
    pm2 start "$NR_BIN" --name 9router -- --port "$NR_PORT" --host 127.0.0.1
  fi
  pm2 save
  # Startup script (butuh sekali dijalankan sebagai user yang sama)
  pm2 startup 2>&1 | grep -E '^sudo|^env ' | head -1 | bash || \
    warn "Jalankan perintah 'pm2 startup' secara manual untuk enable startup otomatis"
  ok "pm2: 9Router terdaftar + startup tersimpan"

elif [[ "$NR_DOCKER" == 1 ]]; then
  warn "Docker: pastikan container 9Router pakai --restart always atau restart: always di docker-compose.yml"
  CONTAINER="$(docker ps --format '{{.Names}}' | grep -i 9router | head -1)"
  if [[ -n "$CONTAINER" ]]; then
    docker update --restart=always "$CONTAINER"
    ok "Docker container '$CONTAINER' → restart:always"
  fi

else
  # Systemd unit (metode paling andal untuk VPS headless)
  if ! systemctl --version >/dev/null 2>&1; then
    warn "systemd tidak tersedia, beralih ke pm2"
    if ! command -v pm2 >/dev/null; then npm install -g pm2; fi
    pm2 start "${NR_BIN:-9router}" --name 9router -- --port "$NR_PORT" --host 127.0.0.1
    pm2 save; pm2 startup 2>&1 | grep -E '^sudo|^env ' | head -1 | bash || true
    ok "pm2: 9Router terdaftar sebagai fallback"
  else
    NR_USER="${SUDO_USER:-$USER}"
    NR_GROUP="$(id -gn "$NR_USER")"
    cat > /etc/systemd/system/9router.service <<EOF
[Unit]
Description=9Router OpenAI-compatible proxy
After=network.target

[Service]
Type=simple
User=$NR_USER
Group=$NR_GROUP
ExecStart=$(command -v node) $(npm root -g)/9router/bin/9router.js --port $NR_PORT --host 127.0.0.1
Restart=always
RestartSec=5
Environment=NODE_ENV=production
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now 9router
    ok "systemd: 9router.service aktif dan di-enable (auto-start setelah reboot)"
  fi
fi

# ── Install & konfigurasi Tailscale ───────────────────────────────────────────
step "3. Install Tailscale"

if ! command -v tailscale >/dev/null; then
  curl -fsSL https://tailscale.com/install.sh | sh
  ok "Tailscale terinstall"
else
  ok "Tailscale sudah ada: $(tailscale version | head -1)"
fi

# Login ke Tailscale
TS_STATUS="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("BackendState",""))' 2>/dev/null || echo "")"
if [[ "$TS_STATUS" == "Running" ]]; then
  ok "Tailscale sudah login dan running"
else
  if [[ -n "$TS_AUTHKEY" ]]; then
    tailscale up --authkey "$TS_AUTHKEY" --ssh
    ok "Tailscale login dengan authkey"
  else
    echo ""
    warn "Tailscale belum login. Jalankan perintah berikut:"
    echo "   sudo tailscale up --ssh"
    echo ""
    echo "   Lalu buka URL yang muncul di browser untuk autentikasi."
    echo "   Setelah login, lanjutkan dengan: bash setup-vps.sh  (lagi)"
    echo "   — atau jalankan langkah 4 dan 5 secara manual (lihat di bawah)."
    echo ""
    read -rp "Sudah login Tailscale? (y/N): " CONFIRM
    [[ "${CONFIRM,,}" == y ]] || { warn "Skrip dihentikan. Jalankan lagi setelah login Tailscale."; exit 0; }
  fi
fi

# ── Expose 9Router via Tailscale serve ────────────────────────────────────────
step "4. Expose 9Router ke tailnet via 'tailscale serve'"

# tailscale serve: proxy HTTPS ke localhost:NR_PORT
# Hasilnya: https://<hostname>.<tailnet>.ts.net → http://127.0.0.1:NR_PORT
if tailscale serve status 2>/dev/null | grep -q ":$NR_PORT"; then
  ok "Tailscale serve sudah aktif untuk port $NR_PORT"
else
  tailscale serve --bg "http://127.0.0.1:$NR_PORT"
  ok "Tailscale serve dikonfigurasi: HTTPS → 127.0.0.1:$NR_PORT"
fi

# Ambil hostname Tailscale
TS_HOST="$(tailscale status --json 2>/dev/null | python3 -c \
  'import sys,json;d=json.load(sys.stdin);s=d.get("Self",{});print(s.get("DNSName","").rstrip("."))' 2>/dev/null || echo "<hostname>.ts.net")"

# ── Simpan API key ke file konfigurasi (opsional) ─────────────────────────────
if [[ -n "$NR_KEY" ]]; then
  NR_ENV="${HOME}/.hermes/.env"
  touch "$NR_ENV"; chmod 600 "$NR_ENV"
  grep -v '^NINEROUTER_API_KEY=' "$NR_ENV" > "$NR_ENV.tmp" || true
  echo "NINEROUTER_API_KEY=$NR_KEY" >> "$NR_ENV.tmp"
  mv "$NR_ENV.tmp" "$NR_ENV"
  ok "API key 9Router disimpan ke ~/.hermes/.env"
fi

# ── Cetak ringkasan ───────────────────────────────────────────────────────────
step "5. Ringkasan akses"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
echo "  │  9Router sekarang PERMANEN dan dapat diakses dari mana saja:    │"
echo "  │                                                                   │"
printf "  │  Dari HP/lokal (Tailscale):  https://%s/v1\n" "$TS_HOST"
echo "  │  Dari VPS lokal (langsung):  http://127.0.0.1:$NR_PORT/v1          │"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || echo "100.x.x.x")"
printf "  │  IP Tailscale VPS:           %s                       │\n" "$TS_IP"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Langkah lanjutan:"
echo ""
echo "  1. Di HP: install Tailscale → login akun yang sama"
echo "     Android: https://play.google.com/store/apps/details?id=com.tailscale.ipn.android"
echo "     iOS:     https://apps.apple.com/app/tailscale/id1470499037"
echo ""
echo "  2. Update Hermes di klien remote (HP/laptop) dengan URL Tailscale:"
echo "     NINEROUTER_URL=https://$TS_HOST/v1 bash fix-9router.sh"
echo ""
echo "  3. Akses dashboard 9Router dari browser HP:"
echo "     https://$TS_HOST"
echo ""
