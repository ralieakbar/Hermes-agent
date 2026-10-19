#!/usr/bin/env bash
# 9Router permanen di mesin LOKAL (Linux desktop / WSL / macOS) + akses dari HP via Tailscale.
#
#   NINEROUTER_API_KEY=sk-xxx bash tailscale/setup-local.sh
#
# Linux: systemd --user (+ linger) → fallback pm2.  macOS: LaunchAgent (KeepAlive).
# Windows: pakai tailscale/setup-windows.ps1.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

[ "$(id -u)" -ne 0 ] || die "Jalankan sebagai user biasa (bukan root); sudo dipanggil seperlunya"

step "1. Deteksi 9Router"
resolve_nr
disable_builtin_autostart "$HOME"

step "2. Jadikan 9Router permanen"
if [ "$OS" = Linux ]; then
  if systemctl --user show-environment >/dev/null 2>&1; then
    release_from_pm2
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/9router.service" <<EOF
[Unit]
Description=9Router (OpenAI-compatible LLM proxy)
After=network-online.target

[Service]
Type=simple
Environment=PATH=$SVC_PATH
Environment=NODE_ENV=production
ExecStart="$NODE_BIN" "$NR_CLI" ${NR_ARGS[*]}
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable 9router >/dev/null 2>&1
    systemctl --user restart 9router
    # linger: service tetap jalan setelah boot walau belum login
    loginctl enable-linger "$USER" 2>/dev/null || as_root loginctl enable-linger "$USER" || \
      warn "Linger gagal diaktifkan; 9Router baru jalan setelah Anda login"
    ok "systemd --user: 9router.service enabled (journalctl --user -u 9router -f)"
  else
    warn "systemd --user tidak tersedia (mis. WSL tanpa systemd) → pakai pm2"
    setup_pm2
  fi
elif [ "$OS" = Darwin ]; then
  PLIST="$HOME/Library/LaunchAgents/com.9router.service.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.9router.service</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$NR_CLI</string>
EOF
    for a in "${NR_ARGS[@]}"; do printf '    <string>%s</string>\n' "$a"; done
    cat <<EOF
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$SVC_PATH</string>
    <key>NODE_ENV</key><string>production</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/9router.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/9router.err.log</string>
</dict>
</plist>
EOF
  } > "$PLIST"
  plutil -lint "$PLIST" >/dev/null
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
  ok "LaunchAgent aktif: $PLIST (log: ~/Library/Logs/9router.log)"
else
  die "OS tidak didukung: $OS (Windows: tailscale/setup-windows.ps1)"
fi

wait_listening 300 || die "9Router tidak merespons di port $NR_PORT (cek log service di atas)"
ok "9Router merespons di http://127.0.0.1:$NR_PORT"

step "3. Tailscale"
ts_install
ts_login

step "4. Expose ke tailnet (HTTPS, hanya perangkat di akun Tailscale Anda)"
ts_serve
ts_verify

if [ "${SKIP_HERMES:-0}" != 1 ]; then
  step "5. Hubungkan Hermes di mesin ini ke 9Router"
  configure_hermes "$(id -un)" "$HOME"
fi

step "Selesai"
print_summary
