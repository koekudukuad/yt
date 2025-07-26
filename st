#!/bin/bash

# ===================================================================
#           SETUP SCRIPT YTLIVE STREAMER FOR DEBIAN/UBUNTU
# ===================================================================

# Pastikan hanya root yang menjalankan script ini
if [[ $EUID -ne 0 ]]; then
   echo "Skrip ini harus dijalankan sebagai root atau dengan sudo."
   exit 1
fi

# --- Variabel Konfigurasi ---
PYTHON_SCRIPT_NAME="ytlive"
PYTHON_SCRIPT_PATH="/usr/local/bin/${PYTHON_SCRIPT_NAME}"
CHANNELS_BASE_DIR="/root/data/channels"
SERVICE_USER="ytlive" 
SERVICE_GROUP="ytlive"
FFMPEG_JV_DIR="/opt/ffmpeg-johnvansickle"

# --- Fungsi Logging ---
log_info() { echo -e "\e[32m[INFO]\e[0m $1"; }
log_warn() { echo -e "\e[33m[PERINGATAN]\e[0m $1"; }
log_error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

# --- 1. Konfigurasi Sistem ---
log_info "Mengatur zona waktu dan memperbarui paket..."
timedatectl set-timezone Asia/Jakarta || { log_error "Gagal mengatur zona waktu."; exit 1; }
apt-get update -y >/dev/null || { log_error "Gagal memperbarui daftar paket."; exit 1; }
apt-get install -y python3 python3-pip cron wget tar xz-utils acl || { log_error "Gagal menginstal dependensi."; exit 1; }
pip3 install psutil requests || { log_error "Gagal menginstal psutil/requests."; exit 1; }

# --- 2. Pembersihan ---
log_info "Membersihkan instalasi sebelumnya..."
systemctl stop 'ytlive-*.service' &>/dev/null
systemctl disable 'ytlive-*.service' &>/dev/null
find /etc/systemd/system -name 'ytlive-*.service' -delete
systemctl daemon-reload
rm -f "${PYTHON_SCRIPT_PATH}" /usr/bin/ffmpeg /usr/bin/ffprobe
rm -rf "${FFMPEG_JV_DIR}/"
# KUNCI PERBAIKAN: Hapus crontab lama dari root DAN user ytlive untuk kebersihan
crontab -r &>/dev/null
crontab -u ${SERVICE_USER} -r &>/dev/null
log_info "Pembersihan crontab selesai."

# --- 3. Instal FFMPEG ---
log_info "Menginstal FFMPEG dari John Vansickle..."
mkdir -p "${FFMPEG_JV_DIR}" || { log_error "Gagal membuat direktori FFMPEG."; exit 1; }
cd /tmp || exit 1
FFMPEG_URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz"
wget -q --show-progress "${FFMPEG_URL}" || { log_error "Gagal mengunduh FFMPEG."; exit 1; }
tar -xf ffmpeg-release-amd64-static.tar.xz -C "${FFMPEG_JV_DIR}" --strip-components=1 || { log_error "Gagal mengekstrak FFMPEG."; exit 1; }
ln -sf "${FFMPEG_JV_DIR}/ffmpeg" /usr/bin/ffmpeg || { log_error "Gagal membuat symlink ffmpeg."; exit 1; }
ln -sf "${FFMPEG_JV_DIR}/ffprobe" /usr/bin/ffprobe || { log_error "Gagal membuat symlink ffprobe."; exit 1; }
if ! /usr/bin/ffmpeg -version | grep -q "johnvansickle.com"; then log_error "Instalasi FFMPEG gagal."; exit 1; fi
log_info "FFMPEG berhasil diinstal."

# --- 4. Buat Direktori, Pengguna, dan Atur Izin Akses ---
log_info "Membuat direktori, pengguna, dan mengatur izin akses..."
mkdir -p "${CHANNELS_BASE_DIR}" || { log_error "Gagal membuat direktori channels."; exit 1; }
id -g "${SERVICE_GROUP}" &>/dev/null || groupadd "${SERVICE_GROUP}"
id -u "${SERVICE_USER}" &>/dev/null || useradd -r -s /bin/false -g "${SERVICE_GROUP}" "${SERVICE_USER}"
chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${CHANNELS_BASE_DIR}" || { log_error "Gagal mengubah kepemilikan direktori data."; exit 1; }
setfacl -m u:${SERVICE_USER}:x /root
setfacl -m u:${SERVICE_USER}:x /root/data
log_info "Direktori dan izin akses berhasil dikonfigurasi."

# --- 5. Tempatkan Script Python ---
log_info "Menempatkan script Python ke ${PYTHON_SCRIPT_PATH}..."
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
SERVICE_GROUP = "ytlive"
CRON_TAG = "# YTSTREAMER_PY"
LIFETIME_TAG = "# LIFETIME_STREAM"
FFMPEG_PATH = "/usr/bin/ffmpeg"
# ===================================================================

# --- Kode Warna ---
COLOR_RESET, COLOR_INFO, COLOR_WARN, COLOR_ERROR, COLOR_CYAN, COLOR_STATUS_RUNNING, COLOR_STATUS_STOPPED, COLOR_STATUS_CRASH = "\033[0m", "\033[0;32m", "\033[0;33m", "\033[0;31m", "\033[0;36m", "\033[0;32m", "\033[0;33m", "\033[0;31m"

def print_info(message): print(f"{COLOR_INFO}[INFO]{COLOR_RESET} {message}")
def print_warn(message): print(f"{COLOR_WARN}[PERINGATAN]{COLOR_RESET} {message}")
def print_error(message): print(f"{COLOR_ERROR}[ERROR]{COLOR_RESET} {message}")

def _get_paths(channel_name):
    channel_dir = CHANNELS_DIR / channel_name
    return {
        "dir": channel_dir, "lock": channel_dir / ".stream.lock",
        "log": channel_dir / "stream.log", "audio": channel_dir / "rendered_audio_mix.mp3",
        "playlist": channel_dir / "playlist.txt", "key": channel_dir / "stream_key.txt"
    }

def _get_channel_mode(paths):
    if not paths["dir"].is_dir(): return "N/A (Direktori tidak ada)"
    videos = list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv"))
    if not videos or any(v.stat().st_size == 0 for v in videos): return "N/A (Video kosong)"
    audios = list(paths["dir"].glob("*.m4a")) + list(paths["dir"].glob("*.mp3"))
    if not audios or any(a.stat().st_size == 0 for a in audios): return "A (Video Saja)"
    return "B (Suara Utama + Latar)" if any('suara_utama' in f.name for f in audios) else "C (Playlist Audio)"

def _render_audio(channel_name, paths):
    with open(paths["log"], 'a') as f: f.write(f"INFO: Memulai render audio untuk '{channel_name}'...\n")
    audios = list(paths["dir"].glob("*.m4a")) + list(paths["dir"].glob("*.mp3"))
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
                    escaped = str(f).replace("'", r"'\\''")
                    pf.write(f"file '{escaped}'\n")
            input_cmds.extend(["-f", "concat", "-safe", "0", "-stream_loop", "-1", "-i", str(paths["playlist"])])
            filter_complex = f"[0:a]volume={vol},{norm_filter}[a_utama];[1:a]volume={VOLUME_MUSIK_LATAR},{norm_filter}[a_latar];[a_utama][a_latar]amix=inputs=2:duration=first[a_final]"
        else:
            filter_complex = f"[0:a]volume={vol},{norm_filter}[a_final]"
    else: # Mode C
        with open(paths["playlist"], "w") as pf:
            for f in random.sample(audios, len(audios)):
                escaped = str(f).replace("'", r"'\\''")
                pf.write(f"file '{escaped}'\n")
        input_cmds.extend(["-f", "concat", "-safe", "0", "-i", str(paths["playlist"])])
        filter_complex = f"[0:a]volume=1.0,{norm_filter}[a_final]"
        
    render_cmd = [FFMPEG_PATH] + input_cmds + ["-filter_complex", filter_complex, "-map", "[a_final]", "-c:a", "libmp3lame", "-b:a", "128k", "-ar", "44100", "-ac", "2", "-y", str(paths["audio"])]
    try:
        with open(paths["log"], 'a') as f: subprocess.run(["nice", "-n", "19"] + render_cmd, check=True, stdout=f, stderr=subprocess.STDOUT)
        return True
    except subprocess.CalledProcessError:
        with open(paths["log"], 'a') as f: f.write("FATAL: Gagal merender audio.\n")
        return False

def _build_ffmpeg_command(paths, mode, force_audio_copy=False):
    key = paths["key"].read_text().strip()
    if not key: return None
    videos = list(paths["dir"].glob("*.mp4")) + list(paths["dir"].glob("*.mkv"))
    if not videos: return None
    video = videos[(datetime.now().timetuple().tm_yday - 1) % len(videos)]
    
    input_opts = ["-re", "-fflags", "+genpts", "-stream_loop", "-1", "-i"]
    output_opts = ["-c:v", "copy", "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-f", "flv", "-maxrate", MAX_BITRATE, "-bufsize", BUFFER_SIZE, "-g", "60", f"{YOUTUBE_RTMP_URL}/{key}"]
    
    if mode == "A (Video Saja)" or force_audio_copy:
        return [FFMPEG_PATH] + input_opts + [str(video), "-map", "0:v:0", "-map", "0:a:0?"] + output_opts
    else:
        if not paths["audio"].is_file() or paths["audio"].stat().st_size == 0: return None
        return [FFMPEG_PATH] + input_opts + [str(video), "-i", str(paths["audio"])] + ["-map", "0:v:0", "-map", "1:a:0"] + output_opts

def handle_start(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): print_error(f"Channel '{args.channel}' tidak ditemukan."); return
    if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-{args.channel}.service"]).returncode == 0:
        print_warn("Service sudah berjalan. Memulai ulang..."); handle_stop(args, quiet=True); time.sleep(1)
    
    paths["lock"].write_text(LIFETIME_TAG)
    internal_cmd = [sys.executable, os.path.realpath(__file__), '_internal_start', args.channel]
    
    if _manage_channel_service(args.channel, 'create_and_start', internal_cmd):
        print_info(f"Streaming '{args.channel}' dimulai via Systemd.")
        print_info(f"Untuk melihat log, jalankan: ytlive log {args.channel}")
    else: 
        print_error(f"Gagal memulai service untuk '{args.channel}'.")
        paths["lock"].unlink(missing_ok=True)

def handle_stop(args, quiet=False):
    paths = _get_paths(args.channel)
    if _manage_channel_service(args.channel, 'stop_and_delete'):
        if not quiet: print_info(f"Stream '{args.channel}' dihentikan.")
    for f in [paths["lock"], paths["audio"], paths["playlist"]]: f.unlink(missing_ok=True)

def handle_list(args):
    print(f"{'NAMA CHANNEL':<25} {'MODE':<28} {'STATUS':<15} {'JADWAL'}")
    print("-" * 100)
    if not CHANNELS_DIR.is_dir(): return
    try:
        cron_list = subprocess.run(['crontab', '-l'], capture_output=True, text=True).stdout.splitlines()
    except Exception: cron_list = []
    
    for channel_dir in sorted(CHANNELS_DIR.iterdir()):
        if not channel_dir.is_dir(): continue
        ch_name, paths = channel_dir.name, _get_paths(channel_dir.name)
        mode = _get_channel_mode(paths)
        status, jadwal = f"{COLOR_STATUS_STOPPED}[ STOPPED ]{COLOR_RESET}", "Manual"
        
        is_scheduled = any(CRON_TAG in line and ch_name in line for line in cron_list)
        if not is_scheduled and paths["lock"].exists():
            jadwal = "Manual/Lifetime"

        if Path(f"/etc/systemd/system/ytlive-{ch_name}.service").exists():
            if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-{ch_name}.service"]).returncode == 0: status = f"{COLOR_STATUS_RUNNING}[ RUNNING ]{COLOR_RESET}"
            elif paths['lock'].exists(): status = f"{COLOR_STATUS_CRASH}[  CRASH  ]{COLOR_RESET}"
        
        if is_scheduled:
            s = next((l.split() for l in cron_list if f"START_{ch_name}" in l), None)
            e = next((l.split() for l in cron_list if f"STOP_{ch_name}" in l), None)
            if s and e: jadwal = f"{s[1].zfill(2)}:{s[0].zfill(2)} - {e[1].zfill(2)}:{e[0].zfill(2)}"
        
        print(f"{ch_name:<25} {COLOR_CYAN}{mode:<28}{COLOR_RESET} {status:<15} {jadwal}")
    print("-" * 100)

def handle_create(args):
    paths = _get_paths(args.channel)
    if paths["dir"].exists(): print_info(f"Channel '{args.channel}' sudah ada."); return
    paths["dir"].mkdir(parents=True, exist_ok=True)
    paths["key"].touch()
    try:
        subprocess.run(['chown', '-R', f'{SERVICE_USER}:{SERVICE_GROUP}', str(paths["dir"])], check=True)
        print_info(f"Channel '{args.channel}' dibuat di {paths['dir']}")
        print(f"       Jangan lupa isi stream key di: '{paths['key']}'")
    except subprocess.CalledProcessError:
        print_error("Gagal mengatur izin.")

def handle_delete(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].exists(): print_error(f"Channel '{args.channel}' tidak ditemukan."); return
    handle_stop(args, quiet=True); handle_unschedule(args, quiet=True)
    if input(f"{COLOR_WARN}Hapus '{args.channel}'? Ketik 'DELETE': {COLOR_RESET}") == "DELETE":
        shutil.rmtree(paths["dir"]); print_info(f"Channel '{args.channel}' dihapus.")

def handle_log(args):
    log_file = _get_paths(args.channel)["log"]
    if not log_file.exists(): print_info(f"Log file untuk '{args.channel}' tidak ditemukan."); return
    print(f"-> Menampilkan log untuk '{args.channel}' (Ctrl+C untuk keluar)...")
    try:
        with subprocess.Popen(['tail', '-F', str(log_file)]) as proc: proc.wait()
    except KeyboardInterrupt: print("\nKeluar dari mode log.")

def handle_status(args):
    paths = _get_paths(args.channel)
    if not paths["dir"].is_dir(): print_error(f"Channel '{args.channel}' tidak ditemukan."); return
    print("-" * 60)
    print(f"Status Detail untuk Channel: {COLOR_CYAN}{args.channel}{COLOR_RESET}")
    mode = _get_channel_mode(paths); print(f"  - Mode            : {mode}")
    status_str = f"{COLOR_STATUS_STOPPED}STOPPED{COLOR_RESET}"
    if Path(f"/etc/systemd/system/ytlive-{args.channel}.service").exists():
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-{args.channel}.service"]).returncode == 0: status_str = f"{COLOR_STATUS_RUNNING}RUNNING{COLOR_RESET}"
        elif paths['lock'].exists(): status_str = f"{COLOR_STATUS_CRASH}CRASHED{COLOR_RESET}"
    print(f"  - Status Service    : {status_str}")
    print(f"  - Log Terakhir      : ")
    if not paths["log"].exists(): print("    (Log file tidak ditemukan)")
    else:
        try:
            for line in paths["log"].read_text().splitlines()[-15:]: print(f"    {line}")
        except Exception as e: print(f"    (Gagal membaca log: {e})")
    print("-" * 60)

def handle_schedule(args):
    paths, start_str, stop_str = _get_paths(args.channel), args.start_time, args.stop_range
    mode = _get_channel_mode(paths)
    if "N/A" in mode: print_error("Mode channel tidak valid."); return
    try:
        start_h, start_m = map(int, start_str.split(':'))
        s_dt = datetime.now().replace(hour=start_h, minute=start_m)
        stop_h, stop_m = map(int, stop_str.split(':')) if stop_str else ((start_h + 17) % 24, (start_m + 59) % 60)
        e_dt = datetime.now().replace(hour=stop_h, minute=stop_m)
    except (ValueError, TypeError): print_error("Format waktu salah: HH:MM."); return
    
    handle_unschedule(args, quiet=True)
    paths["lock"].unlink(missing_ok=True)
    
    script = os.path.realpath(__file__)
    # KUNCI PERBAIKAN: Perintah cron sekarang menggunakan `sudo -u` untuk dijalankan sebagai user ytlive
    base_cmd = f"sudo -u {SERVICE_USER} {sys.executable} {script}"
    jobs = [
        f"{s_dt.minute} {s_dt.hour} * * * {base_cmd} start {args.channel} {CRON_TAG} START_{args.channel}",
        f"{e_dt.minute} {e_dt.hour} * * * {base_cmd} stop {args.channel} {CRON_TAG} STOP_{args.channel}"
    ]
    if mode != "A (Video Saja)":
        render_m, render_h = (s_dt.minute - 5 + 60) % 60, s_dt.hour if s_dt.minute >= 5 else (s_dt.hour - 1 + 24) % 24
        jobs.insert(0, f"{render_m} {render_h} * * * {base_cmd} _internal_start {args.channel} --render-only {CRON_TAG} RENDER_{args.channel}")
        
    try:
        # KUNCI PERBAIKAN: Menulis ke crontab ROOT
        current_cron = subprocess.run(['crontab', '-l'], capture_output=True, text=True).stdout
        new_cron = current_cron.strip() + '\n' + '\n'.join(jobs) + '\n'
        subprocess.run(['crontab', '-'], input=new_cron, text=True, check=True)
        print_info(f"Jadwal '{args.channel}' diatur: {s_dt.strftime('%H:%M')} - {e_dt.strftime('%H:%M')}")
    except Exception as e: print_error(f"Gagal menulis ke crontab: {e}")

def handle_unschedule(args, quiet=False):
    try:
        # KUNCI PERBAIKAN: Mengedit crontab ROOT
        current_cron = subprocess.run(['crontab', '-l'], capture_output=True, text=True).stdout
        new_cron = '\n'.join([l for l in current_cron.splitlines() if not (CRON_TAG in l and args.channel in l)]) + '\n'
        subprocess.run(['crontab', '-'], input=new_cron, text=True, check=True)
        if not quiet: print_info(f"Jadwal untuk '{args.channel}' dihapus.")
    except Exception:
        if not quiet: print_warn("Gagal mengubah crontab atau tidak ada crontab.")

def handle_clean(args):
    def _clean_single(name):
        paths = _get_paths(name)
        if subprocess.run(['systemctl', 'is-active', '--quiet', f"ytlive-{name}.service"]).returncode == 0:
            print_warn(f"Melewatkan '{name}' karena sedang berjalan.")
            return
        print_info(f"Membersihkan file sementara untuk '{name}'...")
        for f in [paths["audio"], paths["playlist"], paths["log"], paths["lock"]]:
            if f.exists():
                f.unlink(); print(f"  -> Dihapus: {f.name}")
    
    if args.channel.lower() == 'all':
        for d in CHANNELS_DIR.iterdir():
            if d.is_dir(): _clean_single(d.name)
    else: _clean_single(args.channel)

def _manage_channel_service(channel_name, action, command_list=None):
    service_name, service_path = f"ytlive-{channel_name}.service", Path(f"/etc/systemd/system/ytlive-{channel_name}.service")
    if action == 'create_and_start':
        log_file_path = _get_paths(channel_name)["log"]
        service_content = f"""[Unit]
Description=YTLive for {channel_name}
[Service]
User={SERVICE_USER}
Group={SERVICE_GROUP}
WorkingDirectory={CHANNELS_DIR/channel_name}
ExecStart={' '.join(shlex.quote(arg) for arg in command_list)}
StandardOutput=append:{log_file_path}
StandardError=append:{log_file_path}
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target"""
        try:
            service_path.write_text(service_content)
            for cmd in ['daemon-reload', f'enable {service_name}', f'start {service_name}']:
                subprocess.run(['systemctl', *cmd.split()], check=True, capture_output=True)
            return True
        except (subprocess.CalledProcessError, IOError) as e:
            print_error(f"Service error: {e.stderr.decode() if hasattr(e, 'stderr') else e}"); return False
    elif action == 'stop_and_delete' and service_path.exists():
        for cmd in [f'stop {service_name}', f'disable {service_name}']: subprocess.run(['systemctl', *cmd.split()], check=False, capture_output=True)
        service_path.unlink(); subprocess.run(['systemctl', 'daemon-reload'], check=False)
    return True

def _internal_start(args):
    paths, channel_name = _get_paths(args.channel), args.channel
    paths["log"].touch(exist_ok=True)
    mode = _get_channel_mode(paths)
    if "N/A" in mode: sys.exit(1)
    render_success = True
    if mode != "A (Video Saja)":
        if args.render_only or not paths["audio"].is_file() or paths["audio"].stat().st_size == 0:
            render_success = _render_audio(channel_name, paths)
    if args.render_only: sys.exit(0 if render_success else 1)
    ffmpeg_cmd = _build_ffmpeg_command(paths, mode, force_audio_copy=(not render_success))
    if not ffmpeg_cmd: sys.exit(1)
    os.execv(FFMPEG_PATH, ffmpeg_cmd)

def main():
    if len(sys.argv) > 1 and sys.argv[1] == '_internal_start':
        parser = argparse.ArgumentParser()
        parser.add_argument('command'); parser.add_argument('channel')
        parser.add_argument('--render-only', action='store_true')
        args = parser.parse_args(); _internal_start(args)
        return

    parser = argparse.ArgumentParser(description="YTLive Streamer", formatter_class=argparse.RawTextHelpFormatter)
    subparsers = parser.add_subparsers(dest='command'); subparsers.required = True
    
    handler_map = {
        'start': handle_start, 'stop': handle_stop, 'list': handle_list,
        'status': handle_status, 'create': handle_create, 'delete': handle_delete,
        'log': handle_log, 'schedule': handle_schedule, 'unschedule': handle_unschedule,
        'clean': handle_clean
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
    p_schedule = subparsers.add_parser('schedule', help='Jadwalkan stream. Contoh: ytlive schedule <channel> 08:00 22:00'); p_schedule.add_argument('channel'); p_schedule.add_argument('start_time'); p_schedule.add_argument('stop_range', nargs='?')
    p_unschedule = subparsers.add_parser('unschedule', help='Hapus jadwal. Contoh: ytlive unschedule <channel>'); p_unschedule.add_argument('channel')
    p_clean = subparsers.add_parser('clean', help='Bersihkan file sementara. Contoh: ytlive clean all'); p_clean.add_argument('channel')

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
log_info "Direktori channel Anda ada di: ${CHANNELS_BASE_DIR}"
log_info "Semua izin akses telah dikonfigurasi secara otomatis."
log_info ""
log_info "Untuk melihat perintah, ketik: ${PYTHON_SCRIPT_NAME}"
log_info "Selamat melakukan streaming!"
