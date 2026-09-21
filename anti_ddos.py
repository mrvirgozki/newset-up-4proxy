
#!/usr/bin/env python3
import re
import time
from collections import defaultdict
import subprocess
import os
import signal

# ==============================================
# CONFIG — PWEDENG BAGUHIN KUNG GUSTO
# ==============================================
NGINX_ACCESS_LOG = "/dev/stdout"  # ✅ Tugma sa nginx.conf mo
SCAN_INTERVAL = 10                # Bawat ilang segundo mag-i-scan
MAX_REQUESTS = 80                 # Max request bawat 10s bago balaan
BLOCK_TRIGGER = 3                 # Ilang beses lalagpas bago tuluyang i-block
BLOCK_DURATION = 3600             # Oras ng block (1 oras)

# ==============================================
# VARIABLES
# ==============================================
ip_stats = defaultdict(lambda: {"count": 0, "warn": 0})
blocked_list = {}
running = True

def signal_handler(sig, frame):
    global running
    print("\n🛑 Tinatapos ang Anti-DDoS script...")
    running = False

def block_ip(ip):
    if ip in blocked_list:
        return
    print(f"🛡️ NAG-BLOCK: {ip} — sobrang daming request")
    try:
        subprocess.run(
            ["iptables", "-A", "INPUT", "-s", ip, "-j", "DROP"],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        blocked_list[ip] = time.time() + BLOCK_DURATION
    except Exception as e:
        print(f"⚠️ Hindi ma-block si {ip}: {str(e)}")

def unblock_expired():
    now = time.time()
    expired = [ip for ip, until in blocked_list.items() if now > until]
    for ip in expired:
        print(f"🔓 NAG-UNBLOCK: {ip} — tapos na ang block")
        subprocess.run(
            ["iptables", "-D", "INPUT", "-s", ip, "-j", "DROP"],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        del blocked_list[ip]
        ip_stats.pop(ip, None)

def scan_logs():
    # Kung walang log file, laktawan (Cloud Run style logging)
    if not os.path.exists("/proc/self/fd/1"):
        return

    # Basahin ang huling output / log
    ip_pattern = re.compile(r'(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})')
    
    try:
        # Para sa Cloud Run / stdout logging: gumamit ng simpleng pagbasa
        # Kung may naka-save na log file, basahin iyon
        log_path = "/tmp/virgozki-logs/openresty.log"
        if os.path.exists(log_path):
            with open(log_path, "r") as f:
                lines = f.readlines()[-500:]  # Kunin lang huling 500 linya
        else:
            return

        # Bilangin ang request bawat IP
        temp_count = defaultdict(int)
        for line in lines:
            match = ip_pattern.search(line)
            if match:
                ip = match.group(1)
                # ✅ HUWAG ISAMA ANG SARILING CHECK / HEALTH PROBE
                if ip not in ["127.0.0.1", "::1"]:
                    temp_count[ip] += 1

        # I-check kung lumagpas sa limit
        for ip, count in temp_count.items():
            if count > MAX_REQUESTS:
                ip_stats[ip]["warn"] += 1
                print(f"⚠️ BABALA: {ip} — {count} request sa {SCAN_INTERVAL}s")
                
                if ip_stats[ip]["warn"] >= BLOCK_TRIGGER:
                    block_ip(ip)
                    ip_stats[ip]["warn"] = 0

        # I-reset ang bilang para sa susunod na cycle
        for ip in ip_stats:
            ip_stats[ip]["count"] = 0

    except Exception as e:
        print(f"⚠️ Error sa pag-scan: {str(e)}")

# ==============================================
# SIMULA
# ==============================================
if __name__ == "__main__":
    # I-set ang signal para malinis na pagtigil
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    print("🚀 Anti-DDoS Standalone Script — Nagsimula na")
    print(f"⚙️ Settings: Max {MAX_REQUESTS} request / {SCAN_INTERVAL}s | Block: {BLOCK_DURATION}s")

    while running:
        scan_logs()
        unblock_expired()
        time.sleep(SCAN_INTERVAL)

    print("✅ Anti-DDoS script natapos na")
