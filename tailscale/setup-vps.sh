#!/usr/bin/env bash
# 9Router permanen di VPS Linux + akses aman dari HP via Tailscale (tanpa buka port publik).
#
# Jalankan sebagai user yang memakai 9Router (bukan "sudo bash"); sudo dipanggil seperlunya:
#   NINEROUTER_API_KEY=sk-xxx bash tailscale/setup-vps.sh
#   NINEROUTER_API_KEY=sk-xxx TAILSCALE_AUTHKEY=tskey-auth-xxx bash tailscale/setup-vps.sh   # non-interaktif
#
# Variabel: NINEROUTER_PORT (20128), INSTALL_METHOD (auto|systemd|pm2|docker),
#           TAILSCALE_AUTHKEY, TAILSCALE_HOSTNAME, TAILSCALE_SSH (1/0), SKIP_HERMES (0/1)
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

[ "$OS" = Linux ] || die "Skrip ini untuk VPS Linux. Mesin lokal: tailscale/setup-local.sh"
NR_USER="${SUDO_USER:-$(id -un)}"
NR_HOME="$(getent passwd "$NR_USER" | cut -d: -f6)"
METHOD="${INSTALL_METHOD:-auto}"

step "1. Deteksi 9Router"
DOCKER_CT=""
if command -v docker >/dev/null 2>&1; then
  DOCKER_CT="$(as_root docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -i 9router | awk '{print $1}' | head -1 || true)"
fi
if [ "$METHOD" = auto ]; then
  if [ -n "$DOCKER_CT" ]; then METHOD=docker
  elif systemctl --version >/dev/null 2>&1 && [ -d /run/systemd/system ]; then METHOD=systemd
  else METHOD=pm2; fi
fi
[ "$METHOD" = docker ] || resolve_nr
ok "Metode auto-start: $METHOD (user: $NR_USER)"

step "2. Jadikan 9Router permanen"
case "$METHOD" in
  systemd)
    disable_builtin_autostart "$NR_HOME"
    [ "$(id -un)" = "$NR_USER" ] && release_from_pm2
    as_root tee /etc/systemd/system/9router.service >/dev/null <<EOF
[Unit]
Description=9Router (OpenAI-compatible LLM proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$NR_USER
WorkingDirectory=$NR_HOME
Environment=HOME=$NR_HOME
Environment=PATH=$SVC_PATH
Environment=NODE_ENV=production
ExecStart="$NODE_BIN" "$NR_CLI" ${NR_ARGS[*]}
Restart=always
RestartSec=5
KillMode=control-group
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
    as_root systemctl daemon-reload
    as_root systemctl enable 9router >/dev/null 2>&1
    as_root systemctl restart 9router
    ok "systemd: 9router.service enabled (journalctl -u 9router -f untuk log)"
    ;;
  pm2)
    disable_builtin_autostart "$NR_HOME"
    setup_pm2
    ;;
  docker)
    [ -n "$DOCKER_CT" ] || die "Container 9Router tidak ditemukan"
    as_root docker update --restart=always "$DOCKER_CT" >/dev/null
    as_root docker start "$DOCKER_CT" >/dev/null || true
    ok "Docker: container '$DOCKER_CT' → restart=always"
    if as_root docker port "$DOCKER_CT" 2>/dev/null | grep -qE '0\.0\.0\.0|\[::\]'; then
      warn "Port container terbuka ke publik. Disarankan publish ke 127.0.0.1 saja: -p 127.0.0.1:$NR_PORT:$NR_PORT"
    fi
    ;;
  *) die "INSTALL_METHOD tidak dikenal: $METHOD" ;;
esac

wait_listening 300 || die "9Router tidak merespons di port $NR_PORT. Cek: journalctl -u 9router -n 50 (atau pm2 logs 9router)"
ok "9Router merespons di http://127.0.0.1:$NR_PORT"

step "3. Tailscale"
ts_install
ts_login

step "4. Expose ke tailnet (HTTPS, hanya perangkat di akun Tailscale Anda)"
ts_serve
ts_verify

if [ "${SKIP_HERMES:-0}" != 1 ]; then
  step "5. Hubungkan Hermes di VPS ini ke 9Router"
  configure_hermes "$NR_USER" "$NR_HOME"
fi

step "Selesai"
print_summary
