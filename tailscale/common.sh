# shellcheck shell=bash
# Fungsi bersama untuk setup-vps.sh & setup-local.sh. Kompatibel bash 3.2 (macOS).

NR_PORT="${NINEROUTER_PORT:-20128}"
NR_KEY="${NINEROUTER_API_KEY:-}"
OS="$(uname -s)"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }
die()  { err "$*"; exit 1; }

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# curl tanpa -f: exit 0 untuk respons HTTP apa pun (9Router membalas 307 di "/")
nr_listening() { curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$NR_PORT/"; }

# Start pertama untuk user baru: 9Router memasang runtime sql.js via npm (bisa beberapa menit)
wait_listening() {
  local start=$SECONDS limit="${1:-300}" last=0
  while [ $((SECONDS - start)) -lt "$limit" ]; do
    nr_listening && return 0
    if [ $((SECONDS - last)) -ge 30 ] && [ $((SECONDS - start)) -ge 15 ]; then
      warn "Menunggu 9Router siap ($((SECONDS - start))s; start pertama memasang runtime)..."; last=$SECONDS
    fi
    sleep 2
  done
  return 1
}

# Tanpa TTY, cli.js hanya stabil dengan --skip-update (masuk mode background);
# tanpa flag itu ia menampilkan menu interaktif dan service gagal.
NR_ARGS=(--no-browser --skip-update --host 127.0.0.1 --port "$NR_PORT")

resolve_nr() {
  NODE_BIN="$(command -v node)" || die "node tidak ditemukan di PATH"
  NR_BIN="$(command -v 9router || true)"
  [ -n "$NR_BIN" ] || die "9router tidak ada di PATH. Install: npm i -g 9router"
  NR_CLI="$("$NODE_BIN" -e 'console.log(require("fs").realpathSync(process.argv[1]))' "$NR_BIN")"
  [ -f "$NR_CLI" ] || die "cli.js 9router tidak ditemukan ($NR_CLI)"
  SVC_PATH="$(dirname "$NODE_BIN"):/usr/local/bin:/usr/bin:/bin"
  [ "$OS" = Darwin ] && SVC_PATH="$SVC_PATH:/opt/homebrew/bin"
  ok "9router: $NR_CLI (node $("$NODE_BIN" -v), v$("$NODE_BIN" "$NR_CLI" --version 2>/dev/null || echo '?'))"
}

# Autostart bawaan 9Router bind ke 0.0.0.0 dan berebut port dengan service kita
disable_builtin_autostart() {
  local home="${1:-$HOME}" plist
  if [ -f "$home/.config/autostart/9router.desktop" ]; then
    rm -f "$home/.config/autostart/9router.desktop"
    ok "Autostart bawaan 9Router (XDG, 0.0.0.0) dinonaktifkan"
  fi
  plist="$home/Library/LaunchAgents/com.9router.autostart.plist"
  if [ -f "$plist" ]; then
    launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    ok "Autostart bawaan 9Router (LaunchAgent, 0.0.0.0) dinonaktifkan"
  fi
}

# pm2 akan menghidupkan ulang 9Router yang dimatikan service lain → lepas dari pm2
release_from_pm2() {
  command -v pm2 >/dev/null 2>&1 || return 0
  [ -e "${PM2_HOME:-$HOME/.pm2}/rpc.sock" ] || return 0   # daemon pm2 tidak aktif
  pm2 jlist 2>/dev/null | grep -q '"name":"9router"' || return 0
  pm2 delete 9router >/dev/null && pm2 save >/dev/null
  ok "Entri pm2 '9router' dilepas (digantikan service sistem)"
}

setup_pm2() {
  command -v pm2 >/dev/null 2>&1 || npm install -g pm2 >/dev/null
  pm2 delete 9router >/dev/null 2>&1 || true
  pm2 start "$NR_CLI" --name 9router --interpreter "$NODE_BIN" -- "${NR_ARGS[@]}" >/dev/null
  pm2 save >/dev/null
  local out rc=0 cmd
  # root: pm2 startup langsung memasang dirinya; user biasa: ia mencetak perintah sudo
  out="$(pm2 startup 2>&1)" || rc=$?
  cmd="$(printf '%s\n' "$out" | grep -E '^sudo ' | tail -1 || true)"
  if [ -n "$cmd" ]; then
    if bash -c "$cmd" >/dev/null; then ok "pm2 startup terdaftar"; else warn "Gagal menjalankan: $cmd"; fi
  elif [ "$rc" -eq 0 ]; then ok "pm2 startup terdaftar"
  else warn "pm2 startup gagal; jalankan 'pm2 startup' manual agar auto-start setelah reboot"; fi
  ok "pm2: 9router berjalan"
}

# ── Tailscale ─────────────────────────────────────────────────────────────────
ts_bin() {
  if command -v tailscale >/dev/null 2>&1; then command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

ts() { if [ "$OS" = Darwin ]; then "$TS_BIN" "$@"; else as_root "$TS_BIN" "$@"; fi; }

json_get() { # json_get <js-expr atas objek d>
  "$NODE_BIN" -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{try{const d=JSON.parse(s);console.log(eval(process.argv[1])??"")}catch(e){console.log("")}})' "$1"
}

ts_install() {
  TS_BIN="$(ts_bin)"
  if [ -n "$TS_BIN" ]; then ok "Tailscale sudah ada: $("$TS_BIN" version 2>/dev/null | head -1)"; return; fi
  if [ "$OS" = Linux ]; then
    curl -fsSL https://tailscale.com/install.sh | as_root sh
    as_root systemctl enable --now tailscaled >/dev/null 2>&1 || true
  elif [ "$OS" = Darwin ]; then
    command -v brew >/dev/null 2>&1 || die "Install Tailscale dari https://tailscale.com/download/mac lalu ulangi skrip"
    brew install --cask tailscale-app 2>/dev/null || brew install --cask tailscale
    open -a Tailscale || true
    sleep 5
  fi
  TS_BIN="$(ts_bin)"
  [ -n "$TS_BIN" ] || die "Instalasi Tailscale gagal"
  ok "Tailscale terinstall"
}

ts_login() {
  local state kf=""
  state="$(ts status --json 2>/dev/null | json_get 'd.BackendState')"
  if [ "$state" = Running ]; then ok "Tailscale sudah login"; return; fi
  local args=(up)
  [ "$OS" = Linux ] && [ "${TAILSCALE_SSH:-1}" = 1 ] && args+=(--ssh)
  [ -n "${TAILSCALE_HOSTNAME:-}" ] && args+=(--hostname "$TAILSCALE_HOSTNAME")
  if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    # via file agar auth key tidak terlihat di daftar proses
    kf="$(mktemp)"; chmod 600 "$kf"; printf '%s' "$TAILSCALE_AUTHKEY" > "$kf"
    args+=(--auth-key "file:$kf")
  else
    warn "Buka URL login yang muncul di bawah (bisa dari HP), lalu tunggu..."
  fi
  ts "${args[@]}" || ts up
  [ -n "$kf" ] && rm -f "$kf"
  ok "Tailscale login berhasil"
}

ts_serve() {
  if ts serve status --json 2>/dev/null | grep -q "127.0.0.1:$NR_PORT"; then
    ok "tailscale serve sudah aktif → 127.0.0.1:$NR_PORT"
  else
    warn "Jika diminta, aktifkan HTTPS/Serve lewat URL yang muncul (sekali per tailnet)"
    ts serve --bg "http://127.0.0.1:$NR_PORT"
    ok "tailscale serve: HTTPS tailnet → 127.0.0.1:$NR_PORT"
  fi
  TS_DNS="$(ts status --json 2>/dev/null | json_get '(d.Self&&d.Self.DNSName||"").replace(/\.$/,"")')"
  [ -n "$TS_DNS" ] || TS_DNS="<hostname>.<tailnet>.ts.net"
  TS_IP="$(ts ip -4 2>/dev/null | head -1 || true)"
}

# Sertifikat HTTPS diterbitkan saat request pertama → beri waktu
ts_verify() {
  local i=0 code
  while [ "$i" -lt 12 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$TS_DNS/v1/models" || true)"
    case "$code" in 2??|401|403) ok "HTTPS tailnet OK (https://$TS_DNS/v1/models → $code)"; return 0 ;; esac
    sleep 5; i=$((i + 1))
  done
  warn "Belum bisa diverifikasi (kode: ${code:-none}). Pastikan MagicDNS & HTTPS aktif di https://login.tailscale.com/admin/dns"
}

# Hubungkan Hermes di mesin ini ke 9Router lokal (jalur tercepat, tanpa lewat tailnet)
configure_hermes() {
  local user="$1" home="$2" url="http://127.0.0.1:$NR_PORT/v1"
  [ -f "$KIT_DIR/fix-9router.sh" ] || { warn "fix-9router.sh tidak ditemukan, lewati konfigurasi Hermes"; return; }
  if [ "$(id -un)" = "$user" ]; then
    command -v hermes >/dev/null 2>&1 || { warn "Hermes belum terinstall di mesin ini, lewati"; return; }
    NINEROUTER_URL="$url" NINEROUTER_API_KEY="$NR_KEY" bash "$KIT_DIR/fix-9router.sh" || warn "fix-9router.sh melaporkan masalah (lihat di atas)"
  else
    [ -d "$home/.hermes" ] || { warn "Hermes belum ada untuk user $user, lewati"; return; }
    NINEROUTER_URL="$url" NINEROUTER_API_KEY="$NR_KEY" \
      sudo --preserve-env=NINEROUTER_URL,NINEROUTER_API_KEY -u "$user" -H bash -lc 'bash "$0"' "$KIT_DIR/fix-9router.sh" \
      || warn "fix-9router.sh melaporkan masalah (lihat di atas)"
  fi
}

print_summary() {
  echo ""
  echo "  9Router PERMANEN (auto-start setelah reboot, restart otomatis bila crash)"
  echo "  ─────────────────────────────────────────────────────────────────────"
  echo "  Dari HP/laptop (tailnet) : https://$TS_DNS/v1"
  echo "  Dashboard dari HP        : https://$TS_DNS/dashboard"
  echo "  Di mesin ini             : http://127.0.0.1:$NR_PORT/v1"
  [ -n "${TS_IP:-}" ] && echo "  IP Tailscale mesin ini   : $TS_IP (9Router hanya via URL HTTPS di atas)"
  echo ""
  echo "  HP: install Tailscale (Play Store / App Store) → login akun yang sama → buka URL dashboard."
  echo "  Hermes di perangkat lain:"
  echo "     NINEROUTER_URL=https://$TS_DNS/v1 bash tailscale/update-hermes-url.sh"
  echo ""
}
