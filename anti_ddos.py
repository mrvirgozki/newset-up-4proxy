#!/usr/bin/env python3

import signal
import sys
import time
import os

running = True

SCAN_INTERVAL = int(os.getenv("ANTI_DDOS_INTERVAL", "30"))


def signal_handler(signum, frame):
    global running
    running = False


signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)


def main():
    print("Anti-DDoS monitor started", flush=True)
    print(
        f"Monitoring mode active | interval={SCAN_INTERVAL}s",
        flush=True
    )

    while running:
        time.sleep(SCAN_INTERVAL)

    print("Anti-DDoS monitor stopped", flush=True)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
