#!/bin/bash

# ===================================================================
#     SETUP SCRIPT YTLIVE STREAMER FOR DEBIAN/UBUNTU (v17.4 - Final Path Fix)
# ===================================================================

set -e # HENTIKAN SKRIP JIKA ADA ERROR

# --- Variabel Konfigurasi ---
PYTHON_SCRIPT_NAME="ytlive"
PYTHON_SCRIPT_PATH="/usr/local/bin/${PYTHON_SCRIPT_NAME}"
WORKER_SCRIPT_PATH="/usr/local/bin/ytlive-worker.sh"
CHANNELS_BASE_DIR="/root/data/channels"
SERVICE_USER="ytlive"
SERVICE_GROUP="ytlive"

# --- Konfigurasi FFmpeg JVS 6.0.1 AMD64 yang stabil ---
FFMPEG_URL="https://www.johnvansickle.com/ffmpeg/old-releases/ffmpeg-6.0.1-amd64-static.tar.xz"
FFMPEG_TARGET_PATH="/usr/local/bin"
FFMPEG_BINARY_PATH="${FFMPEG_TARGET_PATH}/ffmpeg"

# --- Fungsi Logging ---
log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[PERINGATAN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- 1. Konfigurasi Sistem ---
log_info "Mengatur zona waktu dan memperbarui paket..."
timedatectl set-timezone Asia/Jakarta || log_warn "Gagal mengatur zona waktu."
apt-get update -y >/dev/null || log_error "Gagal memperbarui daftar paket."
apt-get install -y python3 python3-pip python3-dev gcc wget tar xz-utils acl policykit-1 python3-psutil python3-requests || log_error "Gagal menginstal dependensi dasar."

# --- 2. Instalasi FFmpeg Cerdas & Penyesuaian PATH (v17.4) ---
log_info "Memeriksa versi FFmpeg yang terinstal..."

# Cek file langsung di path target, lebih andal daripada 'command -v'
if [ -f "${FFMPEG_BINARY_PATH}" ] && "${FFMPEG_BINARY_PATH}" -version 2>&1 | grep -q "ffmpeg version 6.0.1"; then
    log_info "FFmpeg JVS v6.0.1 sudah terinstal di ${FFMPEG_BINARY_PATH}. Melewati instalasi."
else
    log_warn "FFmpeg v6.0.1 tidak ditemukan atau versi salah. Memulai instalasi..."

    log_info "Menghapus FFmpeg dari APT (jika ada) untuk menghindari konflik..."
    apt-get purge -y ffmpeg &>/dev/null || true

    log_info "Menghapus instalasi FFmpeg manual lama di ${FFMPEG_TARGET_PATH}..."
    rm -f "${FFMPEG_BINARY_PATH}" "${FFMPEG_TARGET_PATH}/ffprobe" || true

    log_info "Mengunduh FFmpeg JVS v6.0.1..."
    wget -q "${FFMPEG_URL}" -O /tmp/ffmpeg.tar.xz || log_error "Gagal mengunduh FFmpeg dari JVS."
    
    log_info "Mengekstrak dan menginstal..."
    tar -xf /tmp/ffmpeg.tar.xz -C /tmp
    EXTRACTED_DIR=$(find /tmp -maxdepth 1 -type d -name "ffmpeg-*-static" -print -quit)
    if [ -z "${EXTRACTED_DIR}" ]; then
        log_error "Gagal menemukan direktori hasil ekstraksi FFmpeg."
    fi

    mv "${EXTRACTED_DIR}/ffmpeg" "${FFMPEG_BINARY_PATH}" || log_error "Gagal memindahkan binary FFmpeg."
    mv "${EXTRACTED_DIR}/ffprobe" "${FFMPEG_TARGET_PATH}/ffprobe" || true
    chmod +x "${FFMPEG_BINARY_PATH}" "${FFMPEG_TARGET_PATH}/ffprobe"
    rm -rf /tmp/ffmpeg.tar.xz "${EXTRACTED_DIR}"

    log_info "FFmpeg v6.0.1 AMD64 berhasil diinstal di ${FFMPEG_BINARY_PATH}."

    # === BLOK PERBAIKAN PENTING UNTUK PATH ===
    log_info "Membuat symbolic link untuk memastikan 'ffmpeg' dapat dipanggil secara global..."
    # Hapus link lama/rusak jika ada, lalu buat yang baru
    rm -f /usr/bin/ffmpeg
    ln -s "${FFMPEG_BINARY_PATH}" /usr/bin/ffmpeg
    log_info "Symbolic link dibuat: /usr/bin/ffmpeg -> ${FFMPEG_BINARY_PATH}"

    log_info "Membersihkan cache path shell agar command baru segera dikenali..."
    hash -r
    # === AKHIR BLOK PERBAIKAN ===
fi


# --- 3. Pembaruan Skrip (Non-Disruptive) ---
log_info "Memeriksa stream yang sedang berjalan sebelum pembaruan skrip..."
if systemctl is-active --quiet 'ytlive-stream@*.service'; then
    log_warn "STREAM AKTIF TERDETEKSI!"
    log_warn "Skrip akan diperbarui, namun TIDAK akan mengganggu stream yang sedang berjalan."
    log_warn "Perubahan akan berlaku setelah stream tersebut Anda restart secara manual (ytlive reload NAMA_CHANNEL)."
else
    log_info "Tidak ada stream aktif. Melakukan pembersihan standar."
    systemctl stop 'ytlive-*.service' 'ytlive-*.timer' &>/dev/null || true
fi

log_info "Menonaktifkan service dan timer lama untuk persiapan pembaruan..."
systemctl disable 'ytlive-*.service' 'ytlive-*.timer' &>/dev/null || true
rm -f /etc/systemd/system/ytlive-stream@.service
rm -f /etc/systemd/system/ytlive-schedule-start@.service
rm -f /etc/systemd/system/ytlive-schedule-stop@.service
rm -f /etc/sudoers.d/ytlive
systemctl daemon-reload
rm -f "${PYTHON_SCRIPT_PATH}" "${WORKER_SCRIPT_PATH}"
log_info "Pembaruan skrip (Bash dan Python) selesai."

# --- 4. Buat Direktori & Pengguna ---
log_info "Membuat direktori, pengguna, dan izin akses..."
mkdir -p "${CHANNELS_BASE_DIR}"
id -g "${SERVICE_GROUP}" &>/dev/null || groupadd "${SERVICE_GROUP}"
id -u "${SERVICE_USER}" &>/dev/null || useradd -r -s /bin/false -g "${SERVICE_GROUP}" "${SERVICE_USER}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${CHANNELS_BASE_DIR}"
setfacl -m u:${SERVICE_USER}:x /root
setfacl -m u:${SERVICE_USER}:x /root/data
log_info "Direktori dan izin akses berhasil dikonfigurasi."

# --- 5. Buat Aturan Izin Sudo ---
log_info "Membuat aturan Sudo untuk izin service..."
echo 'ytlive ALL=(ALL) NOPASSWD: /bin/systemctl start ytlive-*, /bin/systemctl stop ytlive-*' | tee /etc/sudoers.d/ytlive
chmod 0440 /etc/sudoers.d/ytlive
log_info "Aturan Sudo berhasil dibuat."

# --- 6. Buat Skrip Pekerja (Bash Worker) ---
log_info "Membuat skrip pekerja di ${WORKER_SCRIPT_PATH}..."
cat << EOF > "${WORKER_SCRIPT_PATH}"
#!/bin/bash
set -e
CHANNEL_NAME=\$1
exec \$(/usr/bin/python3 ${PYTHON_SCRIPT_PATH} _internal_get_ffmpeg_cmd "\$CHANNEL_NAME") &>> stream.log
EOF
chmod +x "${WORKER_SCRIPT_PATH}"

# --- 7. Buat Template Service Systemd ---
log_info "Membuat template service Systemd..."
cat << EOF > "/etc/systemd/system/ytlive-stream@.service"
[Unit]
Description=YTLive Streamer for %i
[Service]
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${CHANNELS_BASE_DIR}/%i
ExecStart=${WORKER_SCRIPT_PATH} %i
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
cat << EOF > "/etc/systemd/system/ytlive-schedule-start@.service"
[Unit]
Description=Scheduled start for YTLive Streamer channel %i
[Service]
Type=oneshot
User=${SERVICE_USER}
ExecStart=${PYTHON_SCRIPT_PATH} start %i
EOF
cat << EOF > "/etc/systemd/system/ytlive-schedule-stop@.service"
[Unit]
Description=Scheduled stop for YTLive Streamer channel %i
[Service]
Type=oneshot
User=${SERVICE_USER}
ExecStart=${PYTHON_SCRIPT_PATH} stop %i
EOF
systemctl daemon-reload

# --- 8. Tempatkan Skrip Manajemen (Python CLI) - FINAL ---
log_info "Menempatkan script manajemen Python ke ${PYTHON_SCRIPT_PATH}..."
# (Isi skrip Python tidak perlu diubah, karena sudah memanggil path yang benar)
cat << 'EOF' > "${PYTHON_SCRIPT_PATH}"
#!/usr/bin/env python3
import os
import sys
import subprocess
import argparse
import shlex
import random
import time
from pathlib import Path
from datetime import datetime, timedelta
import shutil
import re

# ===================================================================
# --- PUSAT KONFIGURASI ---
# ===================================================================
CHANNELS_DIR = Path("/root/data/channels")
YOUTUBE_RTMP_URL = "rtmp://a.rtmp.youtube.com/live2"
MAX_BITRATE = "2500k"
BUFFER_SIZE = "5000k"
SERVICE_USER = "ytlive"
SERVICE_GROUP = "ytlive"
LIFETIME_TAG = "# LIFETIME_STREAM"
FFMPEG_PATH = "/usr/local/bin/ffmpeg"
SYSTEMD_DIR = Path("/etc/systemd/system")
# ===================================================================

# --- Kode Warna ---
COLOR_RESET = "\033[0m"
COLOR_INFO = "\033[0;32m"
COLOR_WARN = "\033[0;33m"
COLOR_ERROR = "\033[0;31m"
COLOR_CYAN = "\033[0;36m"
COLOR_STATUS_RUNNING = COLOR_INFO
COLOR_STATUS_STOPPED = COLOR_WARN
COLOR_STATUS_CRASH = COLOR_ERROR
# ===================================================================

def print_info(message): print(f"{COLOR_INFO}[INFO]{COLOR_RESET} {message}")
def print_warn(message): print(f"{COLOR_WARN}[PERINGATAN]{COLOR_RESET} {message}")
def print_error(message): print(f"{COLOR_ERROR}[ERROR]{COLOR_RESET} {message}")

def _get_paths(channel_name):
    channel_dir = CHANNELS_DIR / channel_name
    return {
        "dir": channel_dir, "lock": channel_dir / ".stream.lock", "log": channel_dir / "stream.log",
        "key": channel_dir / "stream_key.txt"
    }

def _get_channel_mode(paths):
    if not paths["dir"].is_dir(): return "N/A"
    videos = list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv"))
    if not videos or any(v.stat().st_size == 0 for v in videos): return "N/A (Video Kosong)"
    audios = list(paths["dir"].glob("*.mp3")) + list(paths["dir"].glob("*.m4a"))
    if len(audios) > 0:
        return "B (Video + Audio Harian)"
    else:
        return "A (Video Saja)"

def _build_ffmpeg_command(paths, mode):
    if not paths["key"].is_file() or paths["key"].stat().st_size == 0: return None
    key = paths["key"].read_text().strip()
    videos = sorted(list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv")))
    day_of_year = datetime.now().timetuple().tm_yday
    video = videos[(day_of_year - 1) % len(videos)]
    cmd_list = [FFMPEG_PATH, "-re", "-fflags", "+genpts", "-stream_loop", "-1", "-i", str(video)]
    common_out_opts = ["-f", "flv", "-maxrate", MAX_BITRATE, "-bufsize", BUFFER_SIZE, f"{YOUTUBE_RTMP_URL}/{key}"]
    if mode == "A (Video Saja)":
        cmd_list.extend(["-c:v", "copy", "-c:a", "copy"])
    elif mode == "B (Video + Audio Harian)":
        audios = sorted(list(paths["dir"].glob("*.mp3")) + list(paths["dir"].glob("*.m4a")))
        daily_audio_file = audios[(day_of_year - 1) % len(audios)]
        cmd_list.extend(["-stream_loop", "-1", "-i", str(daily_audio_file),
                         "-map", "0:v:0", "-map", "1:a:0",
                         "-c:v", "copy", "-c:a", "copy"])
    else:
        return None
    cmd_list.extend(common_out_opts)
    return cmd_list

def handle_start(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): return print_error(f"Channel '{args.channel}' tidak ditemukan.")
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode == 0:
        return print_warn(f"Service untuk '{args.channel}' sudah berjalan.")
    paths["lock"].write_text(LIFETIME_TAG)
    try:
        subprocess.run(['sudo', 'systemctl', 'start', f"ytlive-stream@{args.channel}.service"], check=True)
        print_info(f"Streaming '{args.channel}' dimulai via Systemd.")
        if (SYSTEMD_DIR / f"ytlive-schedule-start@{args.channel}.timer").exists():
            print_warn("Jadwal yang ada untuk channel ini TIDAK dihapus.")
    except subprocess.CalledProcessError:
        print_error(f"Gagal memulai service. Cek log dengan: ytlive debug {args.channel}")

def handle_stop(args, quiet=False):
    subprocess.run(['sudo', 'systemctl', 'stop', f"ytlive-stream@{args.channel}.service"], check=False, capture_output=True)
    paths = _get_paths(args.channel)
    paths["lock"].unlink(missing_ok=True)
    if not quiet: print_info(f"Stream '{args.channel}' dihentikan.")

def handle_reload(args):
    print_info(f"Memuat ulang (reload) stream untuk '{args.channel}'...")
    handle_stop(args, quiet=True)
    time.sleep(2)
    handle_start(args)

def handle_list(args):
    print(f"{'NAMA CHANNEL':<25} {'MODE':<28} {'STATUS':<20} {'JADWAL'}")
    print("-" * 100)
    if not CHANNELS_DIR.is_dir(): return
    timers_output = subprocess.run(['systemctl', 'list-timers', 'ytlive-schedule-*', '--no-legend', '--all'], capture_output=True, text=True).stdout
    timers = [line.split() for line in timers_output.splitlines() if 'ytlive-schedule' in line]
    for channel_dir in sorted(CHANNELS_DIR.iterdir()):
        if not channel_dir.is_dir(): continue
        ch_name, paths = channel_dir.name, _get_paths(channel_dir.name)
        mode = _get_channel_mode(paths)
        status, jadwal = f"{COLOR_STATUS_STOPPED}[ STOPPED ]{COLOR_RESET}", "Manual"
        start_timer = next((t for t in timers if f"ytlive-schedule-start@{ch_name}.timer" in t), None)
        stop_timer = next((t for t in timers if f"ytlive-schedule-stop@{ch_name}.timer" in t), None)
        is_scheduled = start_timer and stop_timer
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{ch_name}.service"]).returncode == 0:
            status = f"{COLOR_STATUS_RUNNING}[ RUNNING ]{COLOR_RESET}"
        elif paths['lock'].exists() and not is_scheduled:
            status = f"{COLOR_STATUS_CRASH}[  CRASH  ]{COLOR_RESET}"
        if is_scheduled:
            try:
                start_time_str = start_timer[2]; stop_time_str = stop_timer[2]
                start_time = datetime.strptime(start_time_str, '%H:%M:%S').strftime('%H:%M')
                stop_time = datetime.strptime(stop_time_str, '%H:%M:%S').strftime('%H:%M')
                jadwal = f"{start_time} - {stop_time}"
            except (ValueError, IndexError):
                jadwal = "Terjadwal (Error Parsing)"
        elif paths["lock"].exists():
            jadwal = "Manual/Lifetime"
        print(f"{ch_name:<25} {COLOR_CYAN}{mode:<28}{COLOR_RESET} {status:<20} {jadwal}")
    print("-" * 100)

def handle_timers(args):
    print_info("Menampilkan Jadwal Timer Systemd untuk YTLive...")
    print("-" * 70)
    subprocess.run(['systemctl', 'list-timers', 'ytlive-schedule-*', '--no-pager'])
    print("-" * 70)

def handle_create(args):
    paths = _get_paths(args.channel)
    if paths["dir"].exists(): print_info(f"Channel '{args.channel}' sudah ada."); return
    paths["dir"].mkdir(parents=True, exist_ok=True); paths["key"].touch()
    subprocess.run(['chown', '-R', f'{SERVICE_USER}:{SERVICE_GROUP}', str(paths["dir"])])
    print_info(f"Channel '{args.channel}' dibuat di: {paths['dir']}")

def handle_delete(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].exists(): return print_error(f"Channel '{args.channel}' tidak ditemukan.")
    handle_stop(args, quiet=True); handle_unschedule(args, quiet=True)
    if input(f"{COLOR_WARN}Anda yakin ingin menghapus '{args.channel}'? Ketik 'DELETE': {COLOR_RESET}") == "DELETE":
        shutil.rmtree(paths["dir"]); print_info(f"Channel '{args.channel}' dihapus.")

def handle_log(args):
    log_file = _get_paths(args.channel)["log"]
    if not log_file.exists(): return print_info(f"Log file untuk '{args.channel}' tidak ditemukan.")
    print(f"-> Menampilkan log untuk '{args.channel}' (Ctrl+C untuk keluar)...")
    try:
        with subprocess.Popen(['tail', '-f', str(log_file)]) as proc: proc.wait()
    except KeyboardInterrupt: print("\nKeluar dari mode log.")

def handle_status(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): return print_error(f"Channel '{args.channel}' tidak ditemukan.")
    print("-" * 60); print(f"Status Detail untuk Channel: {COLOR_CYAN}{args.channel}{COLOR_RESET}")
    mode = _get_channel_mode(paths); print(f"  - Mode               : {mode}")
    status_str = f"{COLOR_STATUS_STOPPED}STOPPED{COLOR_RESET}"
    if Path(f"/etc/systemd/system/ytlive-stream@{args.channel}.service").exists():
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode == 0: status_str = f"{COLOR_STATUS_RUNNING}RUNNING{COLOR_RESET}"
        elif paths['lock'].exists(): status_str = f"{COLOR_STATUS_CRASH}CRASHED{COLOR_RESET}"
    print(f"  - Status Service     : {status_str}")
    print("  - Log Terakhir       : ")
    if not paths["log"].exists(): print("    (Log file tidak ditemukan)")
    else:
        try:
            for line in paths["log"].read_text().splitlines()[-15:]: print(f"    {line}")
        except Exception as e: print(f"    (Gagal membaca log: {e})")
    print("-" * 60)

def handle_debug(args):
    service_name = f"ytlive-stream@{args.channel}.service"
    print("-" * 60); print(f"Menampilkan log Systemd (journalctl) untuk: {COLOR_CYAN}{service_name}{COLOR_RESET}")
    print("Log ini sangat penting jika status channel adalah [CRASHED]"); print("-" * 60)
    try:
        subprocess.run(['journalctl', '-u', service_name, '-f', '--no-pager'])
    except KeyboardInterrupt:
        print("\nKeluar dari mode debug.")
    print("-" * 60)

def _clean_single_channel(name, quiet=False):
    paths = _get_paths(name)
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{name}.service"]).returncode == 0:
        if not quiet: print_warn(f"Melewatkan pembersihan '{name}' karena sedang berjalan.")
        return False
    if not quiet: print_info(f"Membersihkan file sementara untuk '{name}'...")
    for f in [paths["log"], paths["lock"]]:
        if f.exists():
            f.unlink()
            if not quiet: print(f"  -> Dihapus: {f.name}")
    return True

def handle_schedule(args):
    _clean_single_channel(args.channel)
    paths = _get_paths(args.channel)
    if "N/A" in _get_channel_mode(paths): return print_error("Mode channel tidak valid atau file media kosong.")
    try:
        start_dt = datetime.strptime(args.start_time, '%H:%M')
        if args.stop_time:
            stop_dt = datetime.strptime(args.stop_time, '%H:%M')
        else:
            stop_dt = start_dt + timedelta(hours=17, minutes=59)
    except ValueError:
        return print_error("Format waktu salah. Gunakan HH:MM.")
    handle_unschedule(args, quiet=True)
    paths["lock"].unlink(missing_ok=True)
    ch_name = args.channel
    start_cal = f"*-*-* {start_dt.strftime('%H:%M:%S')}"
    stop_cal = f"*-*-* {stop_dt.strftime('%H:%M:%S')}"
    start_timer_content = f"""[Unit]\nDescription=Timer to start YTLive channel {ch_name}\n[Timer]\nOnCalendar={start_cal}\nPersistent=true\nUnit=ytlive-schedule-start@{ch_name}.service\n[Install]\nWantedBy=timers.target"""
    stop_timer_content = f"""[Unit]\nDescription=Timer to stop YTLive channel {ch_name}\n[Timer]\nOnCalendar={stop_cal}\nPersistent=true\nUnit=ytlive-schedule-stop@{ch_name}.service\n[Install]\nWantedBy=timers.target"""
    (SYSTEMD_DIR / f"ytlive-schedule-start@{ch_name}.timer").write_text(start_timer_content)
    (SYSTEMD_DIR / f"ytlive-schedule-stop@{ch_name}.timer").write_text(stop_timer_content)
    try:
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'enable', f"ytlive-schedule-start@{ch_name}.timer", f"ytlive-schedule-stop@{ch_name}.timer"], check=True, capture_output=True)
        subprocess.run(['systemctl', 'start', f"ytlive-schedule-start@{ch_name}.timer", f"ytlive-schedule-stop@{ch_name}.timer"], check=True, capture_output=True)
        print_info(f"Jadwal '{ch_name}' berhasil diatur: {start_dt.strftime('%H:%M')} - {stop_dt.strftime('%H:%M')}")
    except subprocess.CalledProcessError as e:
        print_error(f"Gagal mengatur timer systemd. Detail: {e.stderr.decode()}")

def handle_unschedule(args, quiet=False):
    ch_name = args.channel
    start_timer = f"ytlive-schedule-start@{ch_name}.timer"
    stop_timer = f"ytlive-schedule-stop@{ch_name}.timer"
    if not (SYSTEMD_DIR / start_timer).exists():
        if not quiet: print_info(f"Tidak ada jadwal untuk '{ch_name}'.")
        return
    subprocess.run(['systemctl', 'stop', start_timer, stop_timer], capture_output=True, check=False)
    subprocess.run(['systemctl', 'disable', start_timer, stop_timer], capture_output=True, check=False)
    (SYSTEMD_DIR / start_timer).unlink(missing_ok=True)
    (SYSTEMD_DIR / stop_timer).unlink(missing_ok=True)
    subprocess.run(['systemctl', 'daemon-reload'], capture_output=True, check=False)
    if not quiet: print_info(f"Jadwal untuk '{ch_name}' dihapus.")

def handle_clean(args):
    if args.channel.lower() == 'all':
        for d in CHANNELS_DIR.iterdir():
            if d.is_dir(): _clean_single_channel(d.name)
    else:
        _clean_single_channel(args.channel)

def handle_lifetime(args):
    paths = _get_paths(args.channel)
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode != 0:
        handle_start(args)
    handle_unschedule(args, quiet=True)
    paths["lock"].write_text(LIFETIME_TAG)
    print_info(f"Stream '{args.channel}' telah diatur ke mode LIFETIME (permanen).")

def _internal_get_ffmpeg_cmd(args):
    paths = _get_paths(args.channel)
    mode = _get_channel_mode(paths)
    cmd = _build_ffmpeg_command(paths, mode)
    if cmd: print(" ".join(shlex.quote(c) for c in cmd))
    else:
        with open(paths["log"], 'a') as f: f.write("ERROR: Gagal membangun perintah FFMPEG.\n")
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="YTLive Streamer", formatter_class=argparse.RawTextHelpFormatter)
    subparsers = parser.add_subparsers(dest='command', required=True)
    handler_map = {'start': handle_start, 'stop': handle_stop, 'reload': handle_reload, 'list': handle_list, 'status': handle_status, 'create': handle_create, 'delete': handle_delete, 'log': handle_log, 'schedule': handle_schedule, 'unschedule': handle_unschedule, 'clean': handle_clean, 'lifetime': handle_lifetime, 'debug': handle_debug, 'timer': handle_timers}
    if len(sys.argv) > 1 and sys.argv[1].startswith('_internal'):
        internal_parser = argparse.ArgumentParser()
        internal_parser.add_argument('command'); internal_parser.add_argument('channel')
        args = internal_parser.parse_args()
        if args.command == '_internal_get_ffmpeg_cmd': _internal_get_ffmpeg_cmd(args)
        return
    if len(sys.argv) == 2 and sys.argv[1] not in handler_map and not sys.argv[1].startswith('-'):
        if (CHANNELS_DIR / sys.argv[1]).is_dir(): sys.argv.insert(1, 'status')
        else: print_error(f"Channel '{sys.argv[1]}' tidak ditemukan."); sys.exit(1)
    
    p_start = subparsers.add_parser('start', help='Mulai stream'); p_start.add_argument('channel')
    p_stop = subparsers.add_parser('stop', help='Hentikan stream'); p_stop.add_argument('channel')
    p_reload = subparsers.add_parser('reload', help='Restart stream'); p_reload.add_argument('channel')
    p_list = subparsers.add_parser('list', help='Tampilkan semua channel')
    p_timer = subparsers.add_parser('timer', help='Tampilkan jadwal timer')
    p_status = subparsers.add_parser('status', help='Tampilkan status detail'); p_status.add_argument('channel')
    p_create = subparsers.add_parser('create', help='Buat channel baru'); p_create.add_argument('channel')
    p_delete = subparsers.add_parser('delete', help='Hapus channel'); p_delete.add_argument('channel')
    p_log = subparsers.add_parser('log', help='Tampilkan log realtime'); p_log.add_argument('channel')
    p_debug = subparsers.add_parser('debug', help='Tampilkan log systemd'); p_debug.add_argument('channel')
    p_schedule = subparsers.add_parser('schedule', help='Jadwalkan stream: <channel> HH:MM [HH:MM]'); p_schedule.add_argument('channel'); p_schedule.add_argument('start_time'); p_schedule.add_argument('stop_time', nargs='?')
    p_unschedule = subparsers.add_parser('unschedule', help='Hapus jadwal'); p_unschedule.add_argument('channel')
    p_clean = subparsers.add_parser('clean', help='Bersihkan file sementara'); p_clean.add_argument('channel')
    p_lifetime = subparsers.add_parser('lifetime', help='Jadikan stream permanen'); p_lifetime.add_argument('channel')
    
    for name, func in handler_map.items():
        if name in subparsers.choices: subparsers.choices[name].set_defaults(func=func)
    if len(sys.argv) == 1:
        parser.print_help(); print("\n" + "="*20 + " STATUS CHANNEL SAAT INI " + "="*20); handle_list(None); sys.exit(0)
    args = parser.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
EOF

chmod +x "${PYTHON_SCRIPT_PATH}" || { log_error "Gagal membuat skrip Python dapat dieksekusi."; exit 1; }
log_info "Skrip Python berhasil ditempatkan."

log_info "==================================================="
log_info "        YTLIVE STREAMER SETUP COMPLETE!"
log_info "==================================================="
log_info "FFmpeg yang stabil (JVS v6.0.1) telah diverifikasi/diinstal."
log_warn "JANGAN LUPA: Stream yang sedang berjalan harus di-reload (ytlive reload NAMA_CHANNEL)!"
log_info "Untuk melihat perintah, ketik: ${PYTHON_SCRIPT_NAME}"
log_info "Selamat melakukan streaming! ✅"
