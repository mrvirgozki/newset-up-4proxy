#!/usr/bin/env python3

import os
import signal
import subprocess
import sys
import time

running = True

SCAN_INTERVAL = int(os.getenv("ANTI_DDOS_INTERVAL", "30"))


def signal_handler(signum, frame):
    global running
    running = False


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


def check_active_connections():
    """Nagre-report ng bilang ng aktibong TCP connections sa system."""
    try:
        # Binibilang ang mga ESTABLISHED connections
        result = subprocess.run(
            "ss -ant | grep -c ESTAB",
            shell=True,
            capture_output=True,
            text=True,
        )
        count = result.stdout.strip()
        print(f"[ANTI-DDOS] Active TCP Connections: {count}", flush=True)
    except Exception as e:
        print(f"[ANTI-DDOS] Error checking connections: {e}", flush=True)


def main():
    print("Anti-DDoS monitor started", flush=True)
    print(
        f"Monitoring mode active | interval={SCAN_INTERVAL}s",
        flush=True,
    )

    while running:
        check_active_connections()

        # Maayos na pag-sleep para mabilis mag-respond sa SIGTERM
        for _ in range(SCAN_INTERVAL):
            if not running:
                break
            time.sleep(1)

    print("Anti-DDoS monitor stopped", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
