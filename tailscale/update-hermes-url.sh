#!/usr/bin/env bash
# Perbarui semua profil Hermes agar memakai URL 9Router dari Tailscale.
# Jalankan di mesin yang BERBEDA dengan VPS (laptop, HP via Termux, dsb.)
# setelah setup-vps.sh atau setup-local.sh berhasil di sisi server.
#
# Pemakaian:
#   NINEROUTER_URL=https://<hostname>.ts.net/v1 bash update-hermes-url.sh
#   NINEROUTER_URL=http://100.x.x.x:20128/v1   bash update-hermes-url.sh
set -euo pipefail

NR_URL="${NINEROUTER_URL:-}"
[[ -n "$NR_URL" ]] || {
  echo "Masukkan URL 9Router via Tailscale:"
  echo "  Contoh: https://vps-ku.tail1234.ts.net/v1"
  echo "  Atau:   http://100.x.x.x:20128/v1"
  read -rp "URL: " NR_URL
}

# Delegate ke fix-9router.sh di direktori parent
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$SCRIPT_DIR/fix-9router.sh" ]]; then
  NINEROUTER_URL="$NR_URL" bash "$SCRIPT_DIR/fix-9router.sh"
else
  err "fix-9router.sh tidak ditemukan di $SCRIPT_DIR"
  exit 1
fi
