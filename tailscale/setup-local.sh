#!/usr/bin/env bash
# Membuat 9Router permanen di mesin LOKAL (Linux/macOS) + sambungkan ke Tailscale
#
# Pemakaian:
#   NINEROUTER_API_KEY=sk-xxx bash setup-local.sh
#   NINEROUTER_PORT=20128 bash setup-local.sh
#
# Setelah selesai, mesin lokal juga terekspos ke tailnet sehingga HP bisa
# memilih 9Router dari VPS atau lokal, tergantung latensi dan preferensi.
set -euo pipefail

NR_PORT="${NINEROUTER_PORT:-20128}"
NR_KEY="${NINEROUTER_API_KEY:-}"

ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR]\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

OS="$(uname -s)"

# ── Deteksi & start 9Router ───────────────────────────────────────────────────
step "1. Pastikan 9Router berjalan di port $NR_PORT"

NR_BIN="$(command -v 9router 2>/dev/null || command -v 9-router 2>/dev/null || true)"
[[ -n "$NR_BIN" ]] || { err "9router tidak ada di PATH. Install: npm i -g 9router"; exit 1; }

if ! (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$NR_PORT "; then
  warn "9Router belum jalan, mencoba start..."
  nohup "$NR_BIN" --port "$NR_PORT" --host 127.0.0.1 &>/tmp/9router-local.log &
  sleep 3
fi
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -q ":$NR_PORT " \
  && ok "9Router listening di port $NR_PORT" \
  || { err "9Router gagal start. Cek /tmp/9router-local.log"; exit 1; }

# ── Auto-start: Linux (systemd --user) ────────────────────────────────────────
setup_linux_systemd() {
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/9router.service" <<EOF
[Unit]
Description=9Router OpenAI-compatible proxy (user session)
After=network.target

[Service]
Type=simple
ExecStart=$(command -v node) $(npm root -g)/9router/bin/9router.js --port $NR_PORT --host 127.0.0.1
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now 9router
  # linger agar service jalan meski user belum login (opsional di desktop)
  loginctl enable-linger "$USER" 2>/dev/null || true
  ok "systemd --user: 9router.service aktif"
}

# ── Auto-start: macOS (LaunchAgent) ───────────────────────────────────────────
setup_macos_launchagent() {
  NR_FULL_BIN="$(node -e "require('path');console.log(require.resolve('9router/bin/9router.js'))" 2>/dev/null \
    || find "$(npm root -g)" -name '9router.js' -path '*/bin/*' 2>/dev/null | head -1 \
    || echo "$NR_BIN")"
  PLIST="$HOME/Library/LaunchAgents/com.9router.plist"
  NODE_BIN="$(command -v node)"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>          <string>com.9router</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$NR_FULL_BIN</string>
    <string>--port</string> <string>$NR_PORT</string>
    <string>--host</string> <string>127.0.0.1</string>
  </array>
  <key>RunAtLoad</key>      <true/>
  <key>KeepAlive</key>      <true/>
  <key>StandardOutPath</key> <string>/tmp/9router.log</string>
  <key>StandardErrorPath</key> <string>/tmp/9router.err</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>NODE_ENV</key> <string>production</string>
  </dict>
</dict>
</plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load -w "$PLIST"
  ok "LaunchAgent terdaftar: $PLIST"
}

step "2. Konfigurasi auto-start"
if [[ "$OS" == "Linux" ]]; then
  if systemctl --user --version >/dev/null 2>&1; then
    setup_linux_systemd
  elif command -v pm2 >/dev/null; then
    pm2 start "$NR_BIN" --name 9router -- --port "$NR_PORT" --host 127.0.0.1
    pm2 save; pm2 startup 2>&1 | grep -E '^sudo|^env ' | head -1 | bash || \
      warn "Jalankan 'pm2 startup' secara manual untuk enable startup otomatis"
    ok "pm2: 9router terdaftar (fallback)"
  else
    warn "Tidak ada systemd --user atau pm2. Install pm2: npm i -g pm2, lalu ulang."
  fi
elif [[ "$OS" == "Darwin" ]]; then
  setup_macos_launchagent
else
  warn "OS tidak dikenali ($OS). Lihat catatan Windows di README."
fi

# ── Install Tailscale lokal ────────────────────────────────────────────────────
step "3. Install Tailscale"

if command -v tailscale >/dev/null; then
  ok "Tailscale sudah ada: $(tailscale version | head -1)"
else
  if [[ "$OS" == "Linux" ]]; then
    curl -fsSL https://tailscale.com/install.sh | sh
  elif [[ "$OS" == "Darwin" ]]; then
    if command -v brew >/dev/null; then
      brew install --cask tailscale
    else
      open "https://tailscale.com/download/mac"
      echo "   Buka link di atas, install Tailscale, lalu lanjutkan skrip."
      read -rp "Tailscale sudah terinstall? (y/N): " C; [[ "${C,,}" == y ]] || exit 0
    fi
  fi
  ok "Tailscale terinstall"
fi

TS_STATUS="$(tailscale status --json 2>/dev/null | python3 -c \
  'import sys,json;print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || echo "")"
if [[ "$TS_STATUS" != "Running" ]]; then
  warn "Tailscale belum login. Jalankan:"
  echo "   sudo tailscale up --ssh"
  echo "   Lalu buka URL autentikasi di browser."
  read -rp "Sudah login? (y/N): " C; [[ "${C,,}" == y ]] || exit 0
else
  ok "Tailscale sudah running"
fi

# ── Expose via tailscale serve ─────────────────────────────────────────────────
step "4. Expose 9Router ke tailnet"

if tailscale serve status 2>/dev/null | grep -q ":$NR_PORT"; then
  ok "Tailscale serve sudah aktif untuk port $NR_PORT"
else
  tailscale serve --bg "http://127.0.0.1:$NR_PORT"
  ok "Tailscale serve dikonfigurasi"
fi

TS_HOST="$(tailscale status --json 2>/dev/null | python3 -c \
  'import sys,json;d=json.load(sys.stdin);s=d.get("Self",{});print(s.get("DNSName","").rstrip("."))' \
  2>/dev/null || echo "<hostname>.ts.net")"
TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || echo "100.x.x.x")"

# ── Simpan API key (opsional) ─────────────────────────────────────────────────
if [[ -n "$NR_KEY" ]]; then
  NR_ENV="${HOME}/.hermes/.env"
  touch "$NR_ENV"; chmod 600 "$NR_ENV"
  grep -v '^NINEROUTER_API_KEY=' "$NR_ENV" > "$NR_ENV.tmp" || true
  echo "NINEROUTER_API_KEY=$NR_KEY" >> "$NR_ENV.tmp"
  mv "$NR_ENV.tmp" "$NR_ENV"
  ok "API key 9Router disimpan ke ~/.hermes/.env"
fi

step "5. Ringkasan"
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  9Router lokal sekarang PERMANEN dan terekspos ke Tailscale:     │"
printf "  │  Tailscale HTTPS: https://%s/v1\n" "$TS_HOST"
printf "  │  Tailscale IP:    http://%s:%s/v1\n" "$TS_IP" "$NR_PORT"
echo "  │  Lokal langsung:  http://127.0.0.1:$NR_PORT/v1                    │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Langkah lanjutan untuk Hermes di klien lain:"
echo "     NINEROUTER_URL=https://$TS_HOST/v1 bash fix-9router.sh"
echo ""
