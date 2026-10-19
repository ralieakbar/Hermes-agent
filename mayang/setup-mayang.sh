#!/usr/bin/env bash
# Membuat/memperbarui profil Hermes "mayang": teman ngobrol humanis + gambar, video, suara.
# Jalankan SETELAH fix-9router.sh sukses.
#
#   MAYANG_MODEL=<id-model-9router> bash setup-mayang.sh
#   Opsional: MAYANG_VOICE=id-ID-GadisNeural  FAL_KEY=...  (untuk gambar & video)
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="mayang"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
PDIR="$HERMES_HOME/profiles/$PROFILE"
MAYANG_MODEL="${MAYANG_MODEL:-}"
MAYANG_VOICE="${MAYANG_VOICE:-id-ID-GadisNeural}"   # Edge TTS gratis, suara perempuan Indonesia
IMG_PROVIDER="${IMG_PROVIDER:-fal}"                 # fal | openai | openrouter | xai | krea | deepinfra
VID_PROVIDER="${VID_PROVIDER:-fal}"                 # fal | xai | deepinfra
TS="$(date +%Y%m%d-%H%M%S)"

HERMES_BIN="$(command -v hermes)"
PY="$(head -1 "$(readlink -f "$HERMES_BIN")" | sed 's/^#!//' | awk '{print $1}')"
"$PY" -c 'import yaml' 2>/dev/null || PY="$HERMES_HOME/hermes-agent/venv/bin/python"

# 1) Buat profil (clone dari default agar provider 9Router & token gateway ikut)
if [[ ! -d "$PDIR" ]]; then
  hermes profile create "$PROFILE" --clone \
    --description "Mayang: teman ngobrol natural & humanis; bisa membuat gambar, video, dan voice note."
  # Token bot hasil clone dibuang: satu token tidak boleh dipakai dua gateway (Telegram 409 Conflict).
  sed -i -E '/^(TELEGRAM_BOT_TOKEN|DISCORD_BOT_TOKEN|SLACK_BOT_TOKEN|SLACK_APP_TOKEN|MATRIX_ACCESS_TOKEN|MATTERMOST_TOKEN|WHATSAPP_CLOUD_ACCESS_TOKEN|WHATSAPP_CLOUD_VERIFY_TOKEN)=/d' "$PDIR/.env"
else
  cp -a "$PDIR/config.yaml" "$PDIR/config.yaml.bak-$TS"
fi

# 2) Persona + skill khusus
cp SOUL.md "$PDIR/SOUL.md"
mkdir -p "$PDIR/skills"; cp -r skills/. "$PDIR/skills/"

# 3) Pilih model percakapan dari 9Router
NR_KEY="$(grep -hsE '^NINEROUTER_API_KEY=' "$PDIR/.env" | tail -1 | cut -d= -f2-)"
NR_URL="$("$PY" -c 'import yaml,sys;c=yaml.safe_load(open(sys.argv[1]));print(c["providers"]["9router"]["base_url"])' "$PDIR/config.yaml")"
if [[ -z "$MAYANG_MODEL" ]]; then
  echo "Model tersedia di 9Router:"
  curl -sS -m 20 -H "Authorization: Bearer $NR_KEY" "$NR_URL/models" \
    | "$PY" -c 'import sys,json;[print("  -",m["id"]) for m in json.load(sys.stdin)["data"]]'
  read -rp "ID model untuk Mayang (pilih model chat terkuat yang mendukung tool calling): " MAYANG_MODEL
fi

# 4) Tulis konfigurasi spesialis
"$PY" - "$PDIR/config.yaml" "$MAYANG_MODEL" "$MAYANG_VOICE" "$IMG_PROVIDER" "$VID_PROVIDER" <<'PYEOF'
import sys, yaml
path, model, voice, img, vid = sys.argv[1:6]
c = yaml.safe_load(open(path)) or {}

c["model"] = {"provider": "custom:9router", "default": model}

# Hanya toolset obrolan + kreatif. Tanpa terminal/file/browser/code/delegation/cron.
CHAT = ["memory", "session_search", "skills", "clarify", "vision",
        "image_gen", "video_gen", "tts"]
pt = c.get("platform_toolsets") if isinstance(c.get("platform_toolsets"), dict) else {}
for plat in set(pt) | {"cli", "telegram", "whatsapp", "discord", "signal"}:
    pt[plat] = list(CHAT)
c["platform_toolsets"] = pt
agent = c.setdefault("agent", {})
agent["disabled_toolsets"] = ["terminal", "file", "browser", "code_execution", "delegation",
                              "cronjob", "computer_use", "kanban", "homeassistant", "web", "search"]
agent["max_turns"] = 30

c["tts"] = {**(c.get("tts") or {}), "provider": "edge", "edge": {"voice": voice}}
c["stt"] = {**(c.get("stt") or {}), "enabled": True, "provider": "local",
            "local": {"model": "base", "language": "id"}}
c["voice"] = {**(c.get("voice") or {}), "auto_tts": False}  # Mayang memutuskan sendiri via skill
c["image_gen"] = {**(c.get("image_gen") or {}), "provider": img}
c["video_gen"] = {**(c.get("video_gen") or {}), "provider": vid}

d = c.setdefault("display", {})
d.update({"language": "id", "final_response_markdown": "strip", "show_reasoning": False})
c.setdefault("memory", {}).update({"memory_enabled": True, "user_profile_enabled": True})
c["human_delay"] = {"mode": "natural", "min_ms": 800, "max_ms": 2500}
c["timezone"] = c.get("timezone") or "Asia/Jakarta"

yaml.safe_dump(c, open(path, "w"), sort_keys=False, allow_unicode=True)
print("config.yaml Mayang ditulis")
PYEOF

# 5) Env: jeda mengetik natural di gateway + key kreatif (jika diberikan)
ENVF="$PDIR/.env"; touch "$ENVF"; chmod 600 "$ENVF"
setenv() { grep -v "^$1=" "$ENVF" > "$ENVF.tmp" || true; echo "$1=$2" >> "$ENVF.tmp"; mv "$ENVF.tmp" "$ENVF"; chmod 600 "$ENVF"; }
setenv HERMES_HUMAN_DELAY_MODE natural
[[ -n "${FAL_KEY:-}" ]] && setenv FAL_KEY "$FAL_KEY"
[[ -n "${XAI_API_KEY:-}" ]] && setenv XAI_API_KEY "$XAI_API_KEY"
[[ -n "${OPENAI_API_KEY:-}" ]] && setenv OPENAI_API_KEY "$OPENAI_API_KEY"
"$PY" -m pip show edge-tts >/dev/null 2>&1 || "$PY" -m pip install -q edge-tts

# 6) Validasi
hermes -p "$PROFILE" doctor | grep -Ei 'provider|model|tts|image|video|error|fail' || true
hermes -p "$PROFILE" chat -q "Halo Mayang, kenalan dong. Jawab singkat aja ya."
echo
echo "Selesai. Langkah lanjutan:"
echo "  • Hubungkan platform chat khusus Mayang : hermes -p $PROFILE gateway setup"
echo "  • Jalankan gateway Mayang             : hermes -p $PROFILE gateway install && hermes -p $PROFILE gateway start"
echo "  • Cek/ubah tool per platform           : hermes -p $PROFILE tools"
