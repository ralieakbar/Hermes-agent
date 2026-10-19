#!/usr/bin/env bash
# Arahkan semua profil Hermes di perangkat INI (laptop, HP via Termux, dsb.)
# ke 9Router di VPS/lokal lewat Tailscale. Perangkat ini harus sudah login Tailscale.
#
#   NINEROUTER_URL=https://<hostname>.<tailnet>.ts.net/v1 NINEROUTER_API_KEY=sk-xxx \
#     bash tailscale/update-hermes-url.sh
set -euo pipefail

KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$KIT_DIR/fix-9router.sh" ] || { echo "[ERR] fix-9router.sh tidak ditemukan di $KIT_DIR" >&2; exit 1; }

NR_URL="${NINEROUTER_URL:-}"
if [ -z "$NR_URL" ]; then
  echo "URL 9Router via Tailscale (lihat ringkasan setup-vps.sh), contoh:"
  echo "  https://vps-ku.tail1234.ts.net/v1"
  read -rp "URL: " NR_URL
fi
case "$NR_URL" in
  http://100.*|http://*.ts.net*)
    echo "[WARN] 9Router hanya bind 127.0.0.1; pakai URL HTTPS dari 'tailscale serve' (https://<host>.ts.net/v1)" ;;
esac

NINEROUTER_URL="$NR_URL" exec bash "$KIT_DIR/fix-9router.sh"
