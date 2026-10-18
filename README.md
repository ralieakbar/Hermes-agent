# Hermes VPS Kit — 9Router Permanen + Tailscale + Profil Mayang

Teruji terhadap **Hermes Agent v0.19.0** (skema config dibaca langsung dari source) dengan mock 9Router OpenAI-compatible (chat, SSE streaming, tool calling).

## 1. Perbaiki 9Router (semua profil)

```bash
git clone -b claude/epic-pasteur-iffmca https://github.com/ralieakbar/Hermes-agent.git ~/hermes-vps-kit
cd ~/hermes-vps-kit
DRY_RUN=1 NINEROUTER_API_KEY=<key> bash fix-9router.sh   # diagnosa dulu
NINEROUTER_API_KEY=<key> bash fix-9router.sh             # terapkan
# 9Router di container/host lain:
NINEROUTER_URL=http://<host-9router>:20128/v1 NINEROUTER_API_KEY=<key> bash fix-9router.sh
```

| Penyebab umum masalah | Yang dilakukan skrip |
|---|---|
| `base_url` tanpa `/v1` atau berakhiran `/chat/completions` | Dinormalisasi ke `.../v1` |
| Entri ganda `custom_providers` + `model.base_url` saling bertabrakan | Disatukan ke `providers.9router`, model → `custom:9router` |
| API key tertulis di YAML / key lama | Dipindah ke `.env` sebagai `NINEROUTER_API_KEY` (chmod 600) |
| `model.default` tidak ada di daftar 9Router (404/400) | Dicek ke `/v1/models`, diberi peringatan + perintah perbaikan |
| Model tidak mendukung tool calling | Diuji dengan tool `ping` |
| `EmptyStreamError` (Hermes selalu streaming) | Diuji SSE `stream:true` + saran solusi |
| Timeout pada model lambat | `request_timeout_seconds`/`stale_timeout_seconds` = 300 |
| Fallback/auxiliary memakai URL mentah 9Router | Diarahkan ke provider bernama |

Backup otomatis: `config.yaml.bak-<timestamp>` dan `.env.bak-<timestamp>` di tiap profil.

## 2. 9Router Permanen + Akses via Tailscale (dari HP)

### VPS (Linux)
```bash
# Install & jalankan — 9Router jadi auto-start + bisa diakses dari HP
NINEROUTER_API_KEY=<key> bash tailscale/setup-vps.sh

# Dengan Tailscale auth key (non-interaktif, cocok untuk CI/cloud-init):
NINEROUTER_API_KEY=<key> TAILSCALE_AUTHKEY=tskey-auth-xxx bash tailscale/setup-vps.sh
```

### Mesin Lokal (Linux/macOS)
```bash
NINEROUTER_API_KEY=<key> bash tailscale/setup-local.sh
```

### Windows
Lihat `tailscale/README-windows.md` untuk pm2-windows-service / Task Scheduler / NSSM.

### Update Hermes di klien lain (HP, laptop)
```bash
# Setelah setup VPS selesai, jalankan di mesin klien:
NINEROUTER_URL=https://<hostname>.<tailnet>.ts.net/v1 bash tailscale/update-hermes-url.sh
```

### Akses dari HP
1. Install Tailscale di HP: [Android](https://play.google.com/store/apps/details?id=com.tailscale.ipn.android) | [iOS](https://apps.apple.com/app/tailscale/id1470499037)
2. Login dengan akun Tailscale yang sama
3. Buka browser HP → `https://<hostname-vps>.ts.net` → dashboard 9Router
4. Hermes di HP: `NINEROUTER_URL=https://<hostname-vps>.ts.net/v1`

| Yang dilakukan | Hasil |
|---|---|
| `systemd`/`pm2`/LaunchAgent/Task Scheduler | 9Router auto-start setelah reboot |
| `tailscale serve --bg` | HTTPS tailnet tanpa buka firewall publik |
| MagicDNS Tailscale | Nama host stabil, tidak perlu ingat IP |
| `fix-9router.sh` dengan URL baru | Semua profil Hermes diperbarui sekaligus |

---

## 3. Profil Mayang

```bash
cd ~/hermes-vps-kit/mayang
MAYANG_MODEL=<id-model-9router> FAL_KEY=<key-fal> bash setup-mayang.sh
hermes -p mayang gateway setup      # bot Telegram/WhatsApp KHUSUS Mayang
hermes -p mayang gateway install && hermes -p mayang gateway start
```

- **Persona**: `SOUL.md` — hangat, empatik, bahasa Indonesia natural, mengikuti gaya lawan bicara.
- **Toolset** (semua platform): `memory, session_search, skills, clarify, vision, image_gen, video_gen, tts`.
  Diblokir: terminal, file, browser, code_execution, delegation, cronjob, computer_use, web.
- **Skill khusus**: `mayang-percakapan`, `mayang-visual`, `mayang-video`, `mayang-suara`.
- **Suara**: Edge TTS gratis `id-ID-GadisNeural` (ganti: `MAYANG_VOICE=id-ID-ArdiNeural`); STT lokal bahasa Indonesia.
- **Gambar/Video**: provider `fal` (butuh `FAL_KEY`). Alternatif: `IMG_PROVIDER=openai|openrouter|xai`, `VID_PROVIDER=xai|deepinfra` + key terkait.
- **Human delay** natural 0,8–2,5 detik di gateway.
- Token bot hasil clone dihapus agar tidak bentrok (Telegram 409 Conflict) dengan profil default.
