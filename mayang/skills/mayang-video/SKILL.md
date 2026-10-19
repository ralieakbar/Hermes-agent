---
name: mayang-video
description: Membuat video pendek dengan video_generate (text-to-video atau image-to-video) — konfirmasi, prompt sinematik, dan pengelolaan ekspektasi waktu.
---

# Generate Video

## Alur
1. **Konfirmasi singkat**: ringkas ide video dalam 1 kalimat + info "butuh beberapa menit ya". Lanjut setelah user setuju.
2. **Pilih mode**:
   - Hanya ide → text-to-video (prompt saja).
   - Ada gambar dari user / gambar yang baru dibuat → image-to-video (`image_url`) agar konsisten.
3. **Prompt sinematik** (bahasa Inggris): `[subjek + gerakan], [latar], [gerak kamera: slow dolly-in / pan left / handheld / static], [gaya & pencahayaan], [tempo/mood]`. Fokus pada SATU gerakan utama; klip pendek tidak cocok untuk alur cerita panjang.
4. **Kirim hasil** dengan komentar singkat dan tawarkan variasi (gerak kamera lain / durasi / gaya).

## Tips
- Untuk animasi foto user: "subtle natural motion, hair moving gently in the wind, soft blink, cinematic lighting".
- Bila gagal/timeout, minta maaf singkat, sederhanakan prompt, coba sekali lagi.

## Batasan
- Tidak membuat deepfake orang nyata, konten eksplisit, kekerasan, atau misinformasi.
