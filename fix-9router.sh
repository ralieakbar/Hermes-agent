#!/usr/bin/env bash
# Diagnosa + perbaiki integrasi 9Router di semua profil Hermes (default + ~/.hermes/profiles/*).
# Aman dijalankan berulang: setiap config.yaml & .env di-backup sebelum diubah.
#
# Pemakaian:
#   NINEROUTER_API_KEY=sk-xxx bash fix-9router.sh
#   NINEROUTER_URL=http://9router:20128/v1 bash fix-9router.sh      # jika 9Router di container lain
#   DRY_RUN=1 bash fix-9router.sh                                    # hanya diagnosa, tanpa menulis
set -euo pipefail

NR_URL="${NINEROUTER_URL:-http://127.0.0.1:20128/v1}"
NR_KEY="${NINEROUTER_API_KEY:-}"
NR_NAME="9router"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
DRY_RUN="${DRY_RUN:-0}"
TS="$(date +%Y%m%d-%H%M%S)"

ok()   { printf '\033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR]\033[0m %s\n' "$*"; }
step() { printf '\n\033[36m== %s ==\033[0m\n' "$*"; }

# Normalisasi URL: wajib berakhiran /v1, tanpa /chat/completions
NR_URL="${NR_URL%/}"; NR_URL="${NR_URL%/chat/completions}"
[[ "$NR_URL" == */v1 ]] || NR_URL="$NR_URL/v1"

# Python milik venv Hermes (punya PyYAML)
HERMES_BIN="$(command -v hermes || true)"
[[ -n "$HERMES_BIN" ]] || { err "Perintah 'hermes' tidak ditemukan di PATH"; exit 1; }
PY="$(head -1 "$(readlink -f "$HERMES_BIN")" | sed 's/^#!//' | awk '{print $1}')"
[[ -x "$PY" ]] && "$PY" -c 'import yaml' 2>/dev/null || PY="$HERMES_HOME/hermes-agent/venv/bin/python"
"$PY" -c 'import yaml' 2>/dev/null || { err "PyYAML tidak tersedia di $PY"; exit 1; }

step "1. Status layanan 9Router"
PORT="$(sed -E 's#^https?://[^:/]+:?([0-9]*).*#\1#' <<<"$NR_URL")"
[[ -n "$PORT" ]] || { [[ "$NR_URL" == https://* ]] && PORT=443 || PORT=80; }
if command -v ss >/dev/null && ss -ltn | grep -q ":$PORT "; then ok "Port $PORT listening"
else warn "Port $PORT tidak terlihat listening di host ini (normal jika 9Router di container/host lain)"; fi
command -v pm2 >/dev/null && pm2 jlist 2>/dev/null | grep -qi 9router && ok "9Router terdeteksi di pm2"
systemctl list-units --type=service 2>/dev/null | grep -i 9router && true
command -v docker >/dev/null && docker ps --format '{{.Names}} {{.Image}} {{.Status}}' 2>/dev/null | grep -i 9router && true
if [[ "$NR_URL" == *127.0.0.1* || "$NR_URL" == *localhost* ]] && [[ -f /.dockerenv ]]; then
  warn "Skrip berjalan di dalam container tetapi URL memakai localhost — gunakan nama service/IP 9Router"
fi

step "2. Uji endpoint $NR_URL"
if [[ -z "$NR_KEY" ]]; then
  # Ambil key yang sudah tersimpan jika ada
  NR_KEY="$(grep -hsE '^NINEROUTER_API_KEY=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2- | tr -d '"'"'" || true)"
fi
[[ -n "$NR_KEY" ]] || read -rsp "Masukkan API key 9Router (Dashboard → Endpoint → API Keys): " NR_KEY && echo
AUTH=(-H "Authorization: Bearer $NR_KEY")

MODELS_JSON="$(curl -sS -m 20 "${AUTH[@]}" "$NR_URL/models" || true)"
MODEL_IDS="$("$PY" -c 'import sys,json
try: print("\n".join(m["id"] for m in json.loads(sys.stdin.read()).get("data",[])))
except Exception: pass' <<<"$MODELS_JSON")"
if [[ -z "$MODEL_IDS" ]]; then
  err "GET /models gagal. Respons: ${MODELS_JSON:0:300}"
  echo "   Cek: 9Router hidup? URL benar (harus .../v1)? API key valid & 'Require API key' sesuai?"
  exit 2
fi
ok "$(wc -l <<<"$MODEL_IDS") model/combo tersedia"; sed 's/^/     - /' <<<"$MODEL_IDS" | head -40

probe_model() {  # $1=model → cek chat + tool calling (Hermes butuh tool calling)
  local body res
  body="$("$PY" -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"max_tokens":64,"stream":False,
  "messages":[{"role":"user","content":"Panggil tool ping dengan x=1"}],
  "tools":[{"type":"function","function":{"name":"ping","description":"ping","parameters":{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}}}]}))' "$1")"
  res="$(curl -sS -m 60 "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body" "$NR_URL/chat/completions" || true)"
  "$PY" -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print("ERROR non-JSON"); sys.exit()
if "error" in d: print("ERROR", json.dumps(d["error"])[:200]); sys.exit()
m=d.get("choices",[{}])[0].get("message",{})
print("TOOLS_OK" if m.get("tool_calls") else "CHAT_ONLY")' <<<"$res"
}

probe_stream() {  # $1=model → Hermes SELALU streaming; stream kosong = penyebab "EmptyStreamError"
  local body res
  body="$("$PY" -c 'import json,sys;print(json.dumps({"model":sys.argv[1],"max_tokens":32,"stream":True,
  "messages":[{"role":"user","content":"Balas: ok"}]}))' "$1")"
  res="$(curl -sS -N -m 60 "${AUTH[@]}" -H 'Content-Type: application/json' -d "$body" "$NR_URL/chat/completions" || true)"
  if grep -q '"finish_reason":"[a-z_]*"\|"finish_reason": "[a-z_]*"' <<<"$res" && grep -q '^data: ' <<<"$res"; then echo "STREAM_OK"
  else echo "STREAM_FAIL ${res:0:200}"; fi
}

step "3. Perbaiki config semua profil"
PROFILE_DIRS=("$HERMES_HOME"); for d in "$HERMES_HOME"/profiles/*/; do [[ -d "$d" ]] && PROFILE_DIRS+=("${d%/}"); done

for P in "${PROFILE_DIRS[@]}"; do
  CFG="$P/config.yaml"; ENVF="$P/.env"; NAME="$(basename "$P")"; [[ "$P" == "$HERMES_HOME" ]] && NAME="default"
  [[ -f "$CFG" ]] || { warn "[$NAME] config.yaml tidak ada, lewati"; continue; }
  echo "--- profil: $NAME"

  CUR_MODEL="$("$PY" -c 'import yaml,sys;c=yaml.safe_load(open(sys.argv[1])) or {};m=c.get("model");print((m.get("default") or m.get("model") or "") if isinstance(m,dict) else (m or ""))' "$CFG")"
  if [[ -n "$CUR_MODEL" ]]; then
    if grep -qxF "$CUR_MODEL" <<<"$MODEL_IDS"; then
      R="$(probe_model "$CUR_MODEL")"
      case "$R" in TOOLS_OK) ok "[$NAME] $CUR_MODEL → chat + tool calling OK";;
        CHAT_ONLY) warn "[$NAME] $CUR_MODEL → tidak memanggil tool. Pilih model/combo yang mendukung function calling";;
        *) err "[$NAME] $CUR_MODEL → $R";; esac
      R="$(probe_stream "$CUR_MODEL")"
      if [[ "$R" == STREAM_OK ]]; then ok "[$NAME] $CUR_MODEL → streaming SSE OK"
      else err "[$NAME] $CUR_MODEL → streaming gagal (${R#STREAM_FAIL })"
        echo "      Solusi: update 9Router (npm i -g 9router@latest), cek akun upstream di dashboard 9Router,"
        echo "      atau pakai combo dengan fallback agar akun yang limit/expired dilewati otomatis."
      fi
    else
      warn "[$NAME] model '$CUR_MODEL' TIDAK ada di daftar 9Router (penyebab umum error 404/400). Set ulang dengan:"
      echo "      hermes -p $NAME config set model.default <id-dari-daftar-di-atas>"
    fi
  fi

  [[ "$DRY_RUN" == 1 ]] && continue
  cp -a "$CFG" "$CFG.bak-$TS"
  "$PY" - "$CFG" "$NR_URL" "$NR_NAME" <<'PYEOF'
import sys, yaml
from urllib.parse import urlparse
cfg_path, url, name = sys.argv[1:4]
host = urlparse(url).netloc
c = yaml.safe_load(open(cfg_path)) or {}
changes = []

def points_to_9router(u):
    return isinstance(u, str) and (host in u or ":20128" in u or "9router" in u.lower())

# a) Provider bernama, format baru `providers:` (satu sumber kebenaran)
provs = c.get("providers") if isinstance(c.get("providers"), dict) else {}
for k in list(provs):
    if k != name and isinstance(provs[k], dict) and points_to_9router(provs[k].get("base_url") or provs[k].get("url")):
        provs.pop(k); changes.append(f"hapus provider duplikat providers.{k}")
entry = provs.get(name) if isinstance(provs.get(name), dict) else {}
entry.pop("api_key", None)                   # key di .env, bukan di YAML
entry.pop("url", None); entry.pop("api", None)
entry.update({
    "base_url": url,
    "key_env": "NINEROUTER_API_KEY",
    "api_mode": "chat_completions",          # 9Router = OpenAI-compatible
    "request_timeout_seconds": entry.get("request_timeout_seconds", 300),
    "stale_timeout_seconds": entry.get("stale_timeout_seconds", 300),
})
provs[name] = entry; c["providers"] = provs; changes.append(f"providers.{name} dinormalisasi")

# b) Buang entri legacy `custom_providers` yang menunjuk 9Router (sumber konflik)
legacy = c.get("custom_providers")
if isinstance(legacy, list):
    keep = [e for e in legacy if not (isinstance(e, dict) and points_to_9router(e.get("base_url") or e.get("url")))]
    if len(keep) != len(legacy):
        changes.append(f"hapus {len(legacy)-len(keep)} entri custom_providers legacy 9Router")
    if keep: c["custom_providers"] = keep
    else: c.pop("custom_providers", None)

# c) Arahkan model utama ke provider bernama bila sebelumnya memakai 9Router
m = c.get("model")
if isinstance(m, str): m = {"default": m}
if isinstance(m, dict):
    p = str(m.get("provider", "")).lower()
    uses_nr = points_to_9router(m.get("base_url")) or p in ("custom", f"custom:{name}", "custom:9-router", "9router", "custom:9router-local")
    if uses_nr:
        m["provider"] = f"custom:{name}"
        for k in ("base_url", "api_key", "api_mode"): m.pop(k, None)
        changes.append(f"model.provider → custom:{name}")
    c["model"] = m

# d) Fallback & auxiliary yang memakai 9Router via base_url mentah
for fb in c.get("fallback_providers") or []:
    if isinstance(fb, dict) and points_to_9router(fb.get("base_url")):
        fb["provider"] = f"custom:{name}"; fb.pop("base_url", None); fb.pop("api_key", None)
        changes.append("fallback_providers → custom provider bernama")
for task, aux in (c.get("auxiliary") or {}).items():
    if isinstance(aux, dict) and points_to_9router(aux.get("base_url")):
        aux["provider"] = f"custom:{name}"; aux["base_url"] = ""; aux["api_key"] = ""
        changes.append(f"auxiliary.{task} → custom:{name}")

yaml.safe_dump(c, open(cfg_path, "w"), sort_keys=False, allow_unicode=True)
print("   " + "\n   ".join(changes))
PYEOF

  touch "$ENVF"; cp -a "$ENVF" "$ENVF.bak-$TS"
  grep -v '^NINEROUTER_API_KEY=' "$ENVF.bak-$TS" > "$ENVF" || true
  echo "NINEROUTER_API_KEY=$NR_KEY" >> "$ENVF"; chmod 600 "$ENVF"
  ok "[$NAME] config + .env diperbarui (backup: *.bak-$TS)"
done

[[ "$DRY_RUN" == 1 ]] && { warn "DRY_RUN=1 → tidak ada perubahan ditulis"; exit 0; }

step "4. Validasi & restart gateway"
for P in "${PROFILE_DIRS[@]}"; do
  NAME="$(basename "$P")"; [[ "$P" == "$HERMES_HOME" ]] && NAME="default"
  hermes -p "$NAME" doctor 2>&1 | grep -Ei 'provider|model|9router|error|fail' | head -15 || true
  hermes -p "$NAME" gateway status >/dev/null 2>&1 && hermes -p "$NAME" gateway restart && ok "[$NAME] perintah restart gateway dijalankan (cek pesan di atas)"
done
ok "Selesai. Uji cepat: hermes chat -q 'halo, tes 9router'"
