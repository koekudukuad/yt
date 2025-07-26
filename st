#!/bin/bash

# ===================================================================
#           SETUP SCRIPT YTLIVE STREAMER FOR DEBIAN/UBUNTU (v5 - DEFINITIVE FIX)
# ===================================================================

set -e # Hentikan skrip jika ada error

# --- Variabel Konfigurasi ---
PYTHON_SCRIPT_NAME="ytlive"
PYTHON_SCRIPT_PATH="/usr/local/bin/${PYTHON_SCRIPT_NAME}"
WORKER_SCRIPT_PATH="/usr/local/bin/ytlive-worker.sh"
CHANNELS_BASE_DIR="/root/data/channels"
SERVICE_USER="ytlive"
SERVICE_GROUP="ytlive"
FFMPEG_JV_DIR="/opt/ffmpeg-johnvansickle"

# --- Fungsi Logging ---
log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[PERINGATAN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }

# --- 1. Konfigurasi Sistem ---
log_info "Mengatur zona waktu dan memperbarui paket..."
timedatectl set-timezone Asia/Jakarta || log_warn "Gagal mengatur zona waktu."
apt-get update -y >/dev/null || log_error "Gagal memperbarui daftar paket."
apt-get install -y python3 python3-pip cron wget tar xz-utils acl || log_error "Gagal menginstal dependensi."
pip3 install psutil requests || log_error "Gagal menginstal psutil/requests."

# --- 2. Pembersihan Total ---
log_info "Membersihkan instalasi sebelumnya secara total..."
killall -9 ffmpeg &>/dev/null || true
systemctl stop 'ytlive-*.service' 'ytlive-*.timer' &>/dev/null || true
systemctl disable 'ytlive-*.service' 'ytlive-*.timer' &>/dev/null || true
find /etc/systemd/system -name 'ytlive-*' -delete
rm -f /etc/cron.d/ytlive_*
systemctl daemon-reload
rm -f "${PYTHON_SCRIPT_PATH}" "${WORKER_SCRIPT_PATH}" /usr/bin/ffmpeg /usr/bin/ffprobe
rm -rf "${FFMPEG_JV_DIR}/"
(crontab -r &>/dev/null) || true
(crontab -u ${SERVICE_USER} -r &>/dev/null) || true
log_info "Pembersihan total selesai."

# --- 3. Instal FFMPEG ---
log_info "Menginstal FFMPEG dari John Vansickle..."
mkdir -p "${FFMPEG_JV_DIR}"
cd /tmp
wget -q --show-progress "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
tar -xf ffmpeg-release-amd64-static.tar.xz -C "${FFMPEG_JV_DIR}" --strip-components=1
ln -sf "${FFMPEG_JV_DIR}/ffmpeg" /usr/bin/ffmpeg
ln -sf "${FFMPEG_JV_DIR}/ffprobe" /usr/bin/ffprobe
if ! /usr/bin/ffmpeg -version | grep -q "johnvansickle.com"; then log_error "Instalasi FFMPEG gagal."; fi
log_info "FFMPEG berhasil diinstal."

# --- 4. Buat Direktori, Pengguna, dan Atur Izin Akses ---
log_info "Membuat direktori, pengguna, dan mengatur izin akses..."
mkdir -p "${CHANNELS_BASE_DIR}"
id -g "${SERVICE_GROUP}" &>/dev/null || groupadd "${SERVICE_GROUP}"
id -u "${SERVICE_USER}" &>/dev/null || useradd -r -s /bin/false -g "${SERVICE_GROUP}" "${SERVICE_USER}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${CHANNELS_BASE_DIR}"
setfacl -m u:${SERVICE_USER}:x /root
setfacl -m u:${SERVICE_USER}:x /root/data
log_info "Direktori dan izin akses berhasil dikonfigurasi."

# --- 5. Buat Skrip Pekerja (Bash Worker) ---
log_info "Membuat skrip pekerja di ${WORKER_SCRIPT_PATH}..."
cat << EOF > "${WORKER_SCRIPT_PATH}"
#!/bin/bash
set -e
CHANNEL_NAME=\$1
# Panggil Python HANYA untuk merender audio. Jika gagal, skrip akan berhenti.
/usr/bin/python3 ${PYTHON_SCRIPT_PATH} _internal_render "\$CHANNEL_NAME"
# Jalankan (exec) FFMPEG. Perintah FFMPEG diambil dari output Python.
exec \$(/usr/bin/python3 ${PYTHON_SCRIPT_PATH} _internal_get_ffmpeg_cmd "\$CHANNEL_NAME")
EOF
chmod +x "${WORKER_SCRIPT_PATH}"

# --- 6. Buat Template Service Systemd (Streaming) ---
log_info "Membuat template service Systemd untuk streaming..."
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

# --- 7. Buat Template Service Systemd (Jadwal START) ---
log_info "Membuat template service Systemd untuk jadwal START..."
cat << EOF > "/etc/systemd/system/ytlive-schedule-start@.service"
[Unit]
Description=Scheduled start for YTLive Streamer channel %i
[Service]
Type=oneshot
User=${SERVICE_USER}
ExecStart=${PYTHON_SCRIPT_PATH} start %i
EOF

# --- 8. Buat Template Service Systemd (Jadwal STOP) ---
log_info "Membuat template service Systemd untuk jadwal STOP..."
cat << EOF > "/etc/systemd/system/ytlive-schedule-stop@.service"
[Unit]
Description=Scheduled stop for YTLive Streamer channel %i
[Service]
Type=oneshot
User=${SERVICE_USER}
ExecStart=${PYTHON_SCRIPT_PATH} stop %i
EOF
systemctl daemon-reload

# --- 9. Tempatkan Skrip Manajemen (Python CLI) - DEFINITIVE FIX ---
log_info "Menempatkan script manajemen Python ke ${PYTHON_SCRIPT_PATH}..."
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
VOLUME_MUSIK_LATAR = 0.1
SERVICE_USER = "ytlive"
LIFETIME_TAG = "# LIFETIME_STREAM"
FFMPEG_PATH = "/usr/bin/ffmpeg"
SYSTEMD_DIR = Path("/etc/systemd/system")
# ===================================================================

# --- Kode Warna ---
COLOR_RESET, COLOR_INFO, COLOR_ERROR, COLOR_CYAN, COLOR_STATUS_RUNNING, COLOR_STATUS_STOPPED, COLOR_STATUS_CRASH = "\033[0m", "\033[0;32m", "\033[0;31m", "\033[0;36m", "\033[0;32m", "\033[0;33m", "\033[0;31m"

def print_info(message): print(f"{COLOR_INFO}[INFO]{COLOR_RESET} {message}")
def print_warn(message): print(f"\033[33m[PERINGATAN]{COLOR_RESET} {message}")
def print_error(message): print(f"{COLOR_ERROR}[ERROR]{COLOR_RESET} {message}")

def _get_paths(channel_name):
    channel_dir = CHANNELS_DIR / channel_name
    return {
        "dir": channel_dir, "lock": channel_dir / ".stream.lock", "log": channel_dir / "stream.log",
        "audio": channel_dir / "rendered_audio_mix.mp3", "playlist": channel_dir / "playlist.txt",
        "key": channel_dir / "stream_key.txt"
    }

def _get_channel_mode(paths):
    if not paths["dir"].is_dir(): return "N/A"
    videos = list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv"))
    if not videos or any(v.stat().st_size == 0 for v in videos): return "N/A"
    audios = list(paths["dir"].glob("*.m4a")) + list(paths["dir"].glob("*.mp3"))
    if not audios or any(a.stat().st_size == 0 for a in audios): return "A (Video Saja)"
    return "B (Suara Utama + Latar)" if any('suara_utama' in f.name for f in audios) else "C (Playlist Audio)"

def _render_audio(channel_name, paths):
    # PERBAIKAN: Selalu hapus file render lama untuk memastikan proses bersih
    paths["audio"].unlink(missing_ok=True)
    paths["playlist"].unlink(missing_ok=True)
    
    with open(paths["log"], 'a') as f: f.write(f"INFO: Memulai render audio untuk '{channel_name}'...\n")
    
    # PERBAIKAN: Ambil semua file audio lalu kecualikan file render itu sendiri
    all_source_audios = list(paths["dir"].glob("*.m4a")) + list(paths["dir"].glob("*.mp3"))
    audios = [f for f in all_source_audios if f.name != paths["audio"].name]

    suara_utama = next((f for f in audios if 'suara_utama' in f.name), None)
    
    input_cmds, filter_complex = [], ""
    norm_filter = "aresample=resampler=soxr:osr=44100,aformat=sample_rates=44100:channel_layouts=stereo:sample_fmts=fltp"
    
    if suara_utama: # Mode B
        musik_latar = [f for f in audios if f != suara_utama]
        vol_match = re.search(r'suara_utama_(\d+)', suara_utama.name)
        vol = float(vol_match.group(1)) / 100 if vol_match else 1.0
        input_cmds.extend(["-i", str(suara_utama)])
        if musik_latar:
            with open(paths["playlist"], "w") as pf:
                for f in random.sample(musik_latar, len(musik_latar)):
                    escaped_path = str(f).replace("'", r"'\\''")
                    pf.write(f"file '{escaped_path}'\n")
            input_cmds.extend(["-f", "concat", "-safe", "0", "-stream_loop", "-1", "-i", str(paths["playlist"])])
            filter_complex = f"[0:a]volume={vol},{norm_filter}[v];[1:a]volume={VOLUME_MUSIK_LATAR},{norm_filter}[b];[v][b]amix=inputs=2:duration=first[a]"
        else:
            filter_complex = f"[0:a]volume={vol},{norm_filter}[a]"
    else: # Mode C
        with open(paths["playlist"], "w") as pf:
            for f in random.sample(audios, len(audios)):
                escaped_path = str(f).replace("'", r"'\\''")
                pf.write(f"file '{escaped_path}'\n")
        input_cmds.extend(["-f", "concat", "-safe", "0", "-i", str(paths["playlist"])])
        filter_complex = f"[0:a]volume=1.0,{norm_filter}[a]"
        
    render_cmd = [FFMPEG_PATH] + input_cmds + ["-filter_complex", filter_complex, "-map", "[a]", "-c:a", "libmp3lame", "-b:a", "128k", "-y", str(paths["audio"])]
    return subprocess.run(["nice", "-n", "19"] + render_cmd, capture_output=True, text=True)

def _build_ffmpeg_command(paths, mode, force_audio_copy=False):
    if not paths["key"].is_file() or paths["key"].stat().st_size == 0: return None
    key = paths["key"].read_text().strip()
    videos = list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv"))
    video = videos[(datetime.now().timetuple().tm_yday - 1) % len(videos)]
    
    out_opts = ["-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-f", "flv", "-maxrate", MAX_BITRATE, "-bufsize", BUFFER_SIZE, f"{YOUTUBE_RTMP_URL}/{key}"]
    cmd_list = [FFMPEG_PATH, "-re", "-fflags", "+genpts", "-stream_loop", "-1", "-i", str(video)]
    
    if mode == "A (Video Saja)" or force_audio_copy:
        cmd_list.extend(["-map", "0:v:0", "-map", "0:a:0?"])
    else:
        cmd_list.extend(["-stream_loop", "-1", "-i", str(paths["audio"]), "-map", "0:v:0", "-map", "1:a:0"])
    
    cmd_list.extend(out_opts)
    return cmd_list

def handle_start(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): return print_error(f"Channel '{args.channel}' tidak ditemukan.")
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode == 0:
        return print_warn(f"Service untuk '{args.channel}' sudah berjalan.")
    
    paths["lock"].write_text(LIFETIME_TAG)
    
    try:
        subprocess.run(['systemctl', 'start', f"ytlive-stream@{args.channel}.service"], check=True)
        print_info(f"Streaming '{args.channel}' dimulai secara manual via Systemd.")
        if (SYSTEMD_DIR / f"ytlive-schedule-start@{args.channel}.timer").exists():
            print_warn("Jadwal yang ada untuk channel ini TIDAK dihapus.")
    except subprocess.CalledProcessError:
        print_error(f"Gagal memulai service. Cek log dengan: ytlive debug {args.channel}")

def handle_stop(args, quiet=False):
    subprocess.run(['systemctl', 'stop', f"ytlive-stream@{args.channel}.service"], check=False, capture_output=True)
    paths = _get_paths(args.channel)
    for f in [paths["lock"], paths["audio"], paths["playlist"]]: f.unlink(missing_ok=True)
    if not quiet: print_info(f"Stream '{args.channel}' dihentikan.")

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
        elif (paths['lock'].exists() and not is_scheduled) or (is_scheduled and not any(f"ytlive-schedule-start@{ch_name}.timer" in t for t in timers)):
             status = f"{COLOR_STATUS_CRASH}[  CRASH  ]{COLOR_RESET}"
        
        if is_scheduled:
            try:
                start_time_str = start_timer[2]
                stop_time_str = stop_timer[2]
                
                start_time = datetime.strptime(start_time_str, '%H:%M:%S').strftime('%H:%M')
                stop_time = datetime.strptime(stop_time_str, '%H:%M:%S').strftime('%H:%M')
                jadwal = f"{start_time} - {stop_time}"
            except (ValueError, IndexError):
                jadwal = "Scheduled (Error Parsing)"
        elif paths["lock"].exists():
            jadwal = "Manual/Lifetime"

        print(f"{ch_name:<25} {COLOR_CYAN}{mode:<28}{COLOR_RESET} {status:<20} {jadwal}")
    print("-" * 100)

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
    if input(f"{COLOR_WARN}Anda yakin ingin menghapus semua file untuk '{args.channel}'? Ketik 'DELETE': {COLOR_RESET}") == "DELETE":
        shutil.rmtree(paths["dir"]); print_info(f"Channel '{args.channel}' dihapus.")

def handle_log(args):
    log_file = _get_paths(args.channel)["log"]
    if not log_file.exists(): return print_info(f"Log file untuk '{args.channel}' tidak ditemukan.")
    print(f"-> Menampilkan log untuk '{args.channel}' (Ctrl+C untuk keluar)...")
    try:
        with subprocess.Popen(['tail', '-F', str(log_file)]) as proc: proc.wait()
    except KeyboardInterrupt: print("\nKeluar dari mode log.")

def handle_status(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): return print_error(f"Channel '{args.channel}' tidak ditemukan.")
    print("-" * 60); print(f"Status Detail untuk Channel: {COLOR_CYAN}{args.channel}{COLOR_RESET}")
    mode = _get_channel_mode(paths); print(f"  - Mode             : {mode}")
    status_str = f"{COLOR_STATUS_STOPPED}STOPPED{COLOR_RESET}"
    if Path(f"/etc/systemd/system/ytlive-stream@{args.channel}.service").exists():
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode == 0: status_str = f"{COLOR_STATUS_RUNNING}RUNNING{COLOR_RESET}"
        elif paths['lock'].exists(): status_str = f"{COLOR_STATUS_CRASH}CRASHED{COLOR_RESET}"
    print(f"  - Status Service   : {status_str}")
    print("  - Log Terakhir     : ")
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
    subprocess.run(['journalctl', '-u', service_name, '-n', '50', '--no-pager'])
    print("-" * 60)

def handle_schedule(args):
    paths = _get_paths(args.channel)
    if "N/A" in _get_channel_mode(paths): return print_error("Mode channel tidak valid atau file media kosong.")
    try:
        start_dt = datetime.strptime(args.start_time, '%H:%M')
        if args.stop_time:
            stop_dt = datetime.strptime(args.stop_time, '%H:%M')
        else:
            stop_dt = start_dt + timedelta(hours=17, minutes=59)
    except ValueError:
        return print_error("Format waktu salah. Gunakan HH:MM. Contoh: 08:00 atau 21:30")

    handle_unschedule(args, quiet=True)
    paths["lock"].unlink(missing_ok=True)

    ch_name = args.channel
    start_cal = f"*-*-* {start_dt.strftime('%H:%M:%S')}"
    stop_cal = f"*-*-* {stop_dt.strftime('%H:%M:%S')}"

    start_timer_content = f"""[Unit]
Description=Timer to start YTLive channel {ch_name}
[Timer]
OnCalendar={start_cal}
Persistent=true
Unit=ytlive-schedule-start@{ch_name}.service
[Install]
WantedBy=timers.target"""
    (SYSTEMD_DIR / f"ytlive-schedule-start@{ch_name}.timer").write_text(start_timer_content)

    stop_timer_content = f"""[Unit]
Description=Timer to stop YTLive channel {ch_name}
[Timer]
OnCalendar={stop_cal}
Persistent=true
Unit=ytlive-schedule-stop@{ch_name}.service
[Install]
WantedBy=timers.target"""
    (SYSTEMD_DIR / f"ytlive-schedule-stop@{ch_name}.timer").write_text(stop_timer_content)
    
    try:
        subprocess.run(['systemctl', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', 'enable', f"ytlive-schedule-start@{ch_name}.timer"], check=True, capture_output=True)
        subprocess.run(['systemctl', 'enable', f"ytlive-schedule-stop@{ch_name}.timer"], check=True, capture_output=True)
        subprocess.run(['systemctl', 'start', f"ytlive-schedule-start@{ch_name}.timer"], check=True, capture_output=True)
        subprocess.run(['systemctl', 'start', f"ytlive-schedule-stop@{ch_name}.timer"], check=True, capture_output=True)
        print_info(f"Jadwal '{ch_name}' berhasil diatur: {start_dt.strftime('%H:%M')} - {stop_dt.strftime('%H:%M')}")
    except subprocess.CalledProcessError as e:
        print_error(f"Gagal mengatur timer systemd. Coba jalankan skrip dengan sudo. Detail: {e.stderr.decode()}")

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
    def _clean_single(name):
        paths = _get_paths(name)
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{name}.service"]).returncode == 0:
            return print_warn(f"Melewatkan '{name}' karena sedang berjalan.")
        print_info(f"Membersihkan file sementara untuk '{name}'...")
        for f in [paths["audio"], paths["playlist"], paths["log"], paths["lock"]]:
            if f.exists():
                f.unlink()
                print(f"  -> Dihapus: {f.name}")
    
    if args.channel.lower() == 'all':
        for d in CHANNELS_DIR.iterdir():
            if d.is_dir(): _clean_single(d.name)
    else: _clean_single(args.channel)

def handle_lifetime(args):
    paths = _get_paths(args.channel)
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-stream@{args.channel}.service"]).returncode != 0:
        handle_start(args) # Jika belum jalan, jalankan dulu
    
    handle_unschedule(args, quiet=True)
    paths["lock"].write_text(LIFETIME_TAG)
    print_info(f"Stream '{args.channel}' telah diatur ke mode LIFETIME (permanen).")


def _internal_render(args):
    paths = _get_paths(args.channel)
    mode = _get_channel_mode(paths)
    if mode in ["A (Video Saja)", "N/A"]: sys.exit(0)
    result = _render_audio(args.channel, paths)
    if result.returncode != 0:
        with open(paths["log"], 'a') as f:
            f.write(f"ERROR: Gagal merender audio.\nSTDOUT: {result.stdout}\nSTDERR: {result.stderr}\n")
        sys.exit(1)
    sys.exit(0)

def _internal_get_ffmpeg_cmd(args):
    paths = _get_paths(args.channel)
    mode = _get_channel_mode(paths)
    cmd = _build_ffmpeg_command(paths, mode)
    if cmd: print(" ".join(shlex.quote(c) for c in cmd))
    else:
        with open(paths["log"], 'a') as f:
            f.write("ERROR: Gagal membangun perintah FFMPEG. Pastikan stream_key.txt ada dan tidak kosong.\n")
        sys.exit(1)

def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith('_internal'):
        parser = argparse.ArgumentParser()
        parser.add_argument('command'); parser.add_argument('channel')
        args = parser.parse_args()
        if args.command == '_internal_render': _internal_render(args)
        elif args.command == '_internal_get_ffmpeg_cmd': _internal_get_ffmpeg_cmd(args)
        return

    parser = argparse.ArgumentParser(description="YTLive Streamer", formatter_class=argparse.RawTextHelpFormatter)
    subparsers = parser.add_subparsers(dest='command'); subparsers.required = True
    
    handler_map = {
        'start': handle_start, 'stop': handle_stop, 'list': handle_list,
        'status': handle_status, 'create': handle_create, 'delete': handle_delete,
        'log': handle_log, 'schedule': handle_schedule, 'unschedule': handle_unschedule,
        'clean': handle_clean, 'lifetime': handle_lifetime, 'debug': handle_debug
    }
    
    if len(sys.argv) == 2 and sys.argv[1] not in handler_map and not sys.argv[1].startswith('-'):
        if (CHANNELS_DIR / sys.argv[1]).is_dir(): sys.argv.insert(1, 'status')
        else: print_error(f"Channel '{sys.argv[1]}' tidak ditemukan."); sys.exit(1)

    p_start = subparsers.add_parser('start', help='Mulai stream. Contoh: ytlive start <channel>'); p_start.add_argument('channel')
    p_stop = subparsers.add_parser('stop', help='Hentikan stream. Contoh: ytlive stop <channel>'); p_stop.add_argument('channel')
    p_list = subparsers.add_parser('list', help='Tampilkan status semua channel. Contoh: ytlive list')
    p_status = subparsers.add_parser('status', help='Tampilkan status detail. Contoh: ytlive status <channel>'); p_status.add_argument('channel')
    p_create = subparsers.add_parser('create', help='Buat channel baru. Contoh: ytlive create <channel>'); p_create.add_argument('channel')
    p_delete = subparsers.add_parser('delete', help='Hapus channel. Contoh: ytlive delete <channel>'); p_delete.add_argument('channel')
    p_log = subparsers.add_parser('log', help='Tampilkan log realtime. Contoh: ytlive log <channel>'); p_log.add_argument('channel')
    p_debug = subparsers.add_parser('debug', help='Tampilkan log systemd untuk debug. Contoh: ytlive debug <channel>'); p_debug.add_argument('channel')
    p_schedule = subparsers.add_parser('schedule', help='Jadwalkan stream. Contoh: ytlive schedule <channel> 08:00 [22:00]'); p_schedule.add_argument('channel'); p_schedule.add_argument('start_time'); p_schedule.add_argument('stop_time', nargs='?', default=None)
    p_unschedule = subparsers.add_parser('unschedule', help='Hapus jadwal. Contoh: ytlive unschedule <channel>'); p_unschedule.add_argument('channel')
    p_clean = subparsers.add_parser('clean', help='Bersihkan file sementara. Contoh: ytlive clean all'); p_clean.add_argument('channel')
    p_lifetime = subparsers.add_parser('lifetime', help='Jadikan stream permanen. Contoh: ytlive lifetime <channel>'); p_lifetime.add_argument('channel')

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
log_info "        YTLIVE STREAMER SETUP COMPLETE!"
log_info "==================================================="
log_info "Direktori channel Anda ada di: ${CHANNELS_BASE_DIR}"
log_info "Semua izin akses telah dikonfigurasi secara otomatis."
log_info ""
log_info "Untuk melihat perintah, ketik: ${PYTHON_SCRIPT_NAME}"
log_info "Selamat melakukan streaming! ✅"
