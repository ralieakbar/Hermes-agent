# Hermes VPS Kit — 9Router Permanen + Tailscale + Profil Mayang

Teruji terhadap **Hermes Agent v0.19.0** (skema config dibaca langsung dari source) dengan mock 9Router OpenAI-compatible (chat, SSE streaming, tool calling).

## 1. Perbaiki 9Router (semua profil)

```bash
git clone https://github.com/ralieakbar/Hermes-agent.git ~/hermes-vps-kit
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

Prasyarat: `npm i -g 9router` sudah terpasang dan provider sudah diatur di dashboard 9Router.
Jalankan sebagai **user biasa** (skrip memanggil `sudo` seperlunya).

| Mesin | Perintah | Auto-start |
|---|---|---|
| VPS Linux | `NINEROUTER_API_KEY=<key> bash tailscale/setup-vps.sh` | systemd (`9router.service`) → fallback pm2 / Docker `restart=always` |
| Linux desktop / WSL | `NINEROUTER_API_KEY=<key> bash tailscale/setup-local.sh` | systemd `--user` + linger → fallback pm2 |
| macOS | `NINEROUTER_API_KEY=<key> bash tailscale/setup-local.sh` | LaunchAgent `com.9router.service` (KeepAlive) |
| Windows | `.\tailscale\setup-windows.ps1` (Admin) | Task Scheduler saat boot — lihat `tailscale/README-windows.md` |

Non-interaktif (cloud-init/CI): tambahkan `TAILSCALE_AUTHKEY=tskey-auth-xxx` (dibaca dari file sementara, tidak tampil di daftar proses).
Opsi lain: `NINEROUTER_PORT`, `INSTALL_METHOD=systemd|pm2|docker`, `TAILSCALE_HOSTNAME`, `TAILSCALE_SSH=0`, `SKIP_HERMES=1`.

Yang dilakukan skrip:
1. Menjalankan 9Router sebagai service dengan `--no-browser --skip-update --host 127.0.0.1`
   (tanpa `--skip-update`, 9Router menampilkan menu interaktif dan service gagal).
2. Menonaktifkan autostart bawaan 9Router yang bind `0.0.0.0` dan berebut port.
3. Install + login Tailscale, lalu `tailscale serve --bg` → HTTPS `https://<host>.<tailnet>.ts.net`
   yang hanya bisa dibuka perangkat di akun Tailscale Anda. Tidak ada port publik yang dibuka.
4. Verifikasi `https://<host>.ts.net/v1/models`, lalu menjalankan `fix-9router.sh` agar Hermes
   di mesin itu memakai `http://127.0.0.1:20128/v1` (jalur tercepat).

### Akses dari HP
1. Install Tailscale: [Android](https://play.google.com/store/apps/details?id=com.tailscale.ipn.android) | [iOS](https://apps.apple.com/app/tailscale/id1470499037), login akun yang sama.
2. Dashboard 9Router: `https://<host-vps>.<tailnet>.ts.net/dashboard`
3. Endpoint untuk aplikasi chat di HP (OpenAI-compatible): `https://<host-vps>.<tailnet>.ts.net/v1` + API key 9Router.
4. Hermes di perangkat lain (laptop, Termux): `NINEROUTER_URL=https://<host-vps>.<tailnet>.ts.net/v1 bash tailscale/update-hermes-url.sh`

> Aktifkan **MagicDNS** dan **HTTPS Certificates** sekali di https://login.tailscale.com/admin/dns.
> Aktifkan juga *Require API key* di dashboard 9Router.

### Perawatan
| Tugas | Perintah |
|---|---|
| Status / log (VPS) | `systemctl status 9router` · `journalctl -u 9router -f` |
| Update 9Router | `npm i -g 9router@latest && sudo systemctl restart 9router` (auto-update dimatikan di mode service) |
| Cek tailnet | `tailscale serve status` · `tailscale status` |
| Lepas akses tailnet | `sudo tailscale serve reset` |

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
