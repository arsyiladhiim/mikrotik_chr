# MikroTik CHR Native Installer for VPS 🚀

<p align="center">
  <img src="https://img.shields.io/badge/RouterOS-v6%20%2F%20v7-blue?style=for-the-badge&logo=mikrotik" alt="RouterOS Version">
  <img src="https://img.shields.io/badge/Platform-VPS%20Native-success?style=for-the-badge&logo=linux" alt="Platform">
  <img src="https://img.shields.io/badge/License-MIT-orange?style=for-the-badge" alt="License">
</p>

Repositori ini menyediakan otomatisasi skrip shell (`bash`) untuk melakukan *replace* (mengganti) sistem operasi VPS Linux (seperti Ubuntu/Debian) secara langsung menjadi **MikroTik Cloud Hosted Router (CHR)** secara *native*. 

Menggunakan metode ini jauh lebih optimal dibandingkan Docker/QEMU karena memberikan performa 100% tanpa *overhead*, serta mendukung penuh fitur *bridging*, *VLAN*, *EoIP*, *OSPF/BGP*, dan *OpenVPN* (TCP/UDP) tanpa kendala.

---

## ⚠️ Peringatan Penting (Read Before Proceeding)
1. **PENGHAPUSAN DATA TOTAL:** Proses instalasi ini akan menimpa dan **menghapus seluruh data serta OS lama** yang ada di disk utama VPS Anda. Pastikan Anda sudah mem-backup data penting sebelum mengeksekusinya.
2. **Rescue Mode / Live Environment:** Skrip ini **wajib** dijalankan di dalam mode pemulihan VPS (**Rescue Mode / Recovery CD**) dari panel kontrol VPS Anda (seperti DigitalOcean, Vultr, Hetzner, IDCloudHost, dll.) agar disk utama tidak terkunci oleh sistem.
3. **Akses Konsol / VNC:** Pastikan Anda memiliki akses ke **Web VNC / Console** dari panel VPS untuk memantau proses *booting* pertama kali setelah instalasi selesai.

---

## 📁 Struktur Berkas Repositori
* `install_v7.sh` — Skrip instalasi otomatis untuk **RouterOS v7** (Recommended / Versi Terbaru).
* `install_v6.sh` — Skrip instalasi otomatis untuk **RouterOS v6** (Long-term / Kompatibilitas Klien Lama).

---

## 🚀 Panduan Instalasi (Installation Guide)

Ikuti langkah-langkah di bawah ini di dalam terminal **Rescue Mode** VPS Anda:

### 1. Kloning Repositori
Clone repositori ini ke dalam direktori VPS Anda:
```bash
git clone [https://github.com/arsyiladhiim/mikrotik_chr.git](https://github.com/arsyiladhiim/mikrotik_chr.git)
cd mikrotik_chr

chmod +x install_v6.sh install_v7.sh
sudo apt-get update
sudo apt-get install -y dos2unix
dos2unix install_v6.sh install_v7.sh

Opsi A: Untuk menginstal MikroTik CHR Versi 7
bash install_v7.sh

Opsi B: Untuk menginstal MikroTik CHR Versi 6
bash install_v6.sh