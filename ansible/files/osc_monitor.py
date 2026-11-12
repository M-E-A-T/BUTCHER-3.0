#!/usr/bin/env python3
"""Live terminal view of the BUTCHER audio server's OSC broadcast.

Listens on UDP 9000 (shared with any other listener via SO_REUSEPORT) and shows
/audio/bpm, /audio/onset/{low,mid,high} and /audio/lmh. Stdlib only.
"""
import socket
import struct
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000
BAR_W = 40
FLASH_S = 0.12

RESET, BOLD, DIM = "\x1b[0m", "\x1b[1m", "\x1b[2m"
COLORS = {"low": "\x1b[31m", "mid": "\x1b[33m", "high": "\x1b[36m"}


def osc_str(data, i):
    end = data.index(b"\0", i)
    return data[i:end].decode("ascii", "replace"), (end + 4) & ~3


def parse(data, out):
    if data.startswith(b"#bundle"):
        i = 16
        while i + 4 <= len(data):
            (n,) = struct.unpack(">i", data[i:i + 4])
            parse(data[i + 4:i + 4 + n], out)
            i += 4 + n
        return
    addr, i = osc_str(data, 0)
    tags, i = osc_str(data, i)
    args = []
    for t in tags[1:]:
        if t == "f":
            args.append(struct.unpack(">f", data[i:i + 4])[0]); i += 4
        elif t == "i":
            args.append(struct.unpack(">i", data[i:i + 4])[0]); i += 4
        elif t == "s":
            s, i = osc_str(data, i); args.append(s)
        else:
            break
    out.append((addr, args))


def bar(v, color):
    v = max(0.0, min(1.0, v))
    n = int(v * BAR_W)
    return f"{color}{'█' * n}{DIM}{'·' * (BAR_W - n)}{RESET} {v:5.2f}"


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if hasattr(socket, "SO_REUSEPORT"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.settimeout(1 / 30)

    host = socket.gethostname()
    bpm = 0.0
    lmh = [0.0, 0.0, 0.0]
    onset_t = {"low": 0.0, "mid": 0.0, "high": 0.0}
    onset_n = {"low": 0, "mid": 0, "high": 0}
    last_rx, pkts, src = 0.0, 0, "-"
    last_draw = 0.0

    sys.stdout.write("\x1b[?25l\x1b[2J")
    try:
        while True:
            try:
                data, (ip, _) = sock.recvfrom(65536)
                msgs = []
                try:
                    parse(data, msgs)
                except (ValueError, struct.error):
                    msgs = []
                now = time.time()
                last_rx, src = now, ip
                pkts += 1
                for addr, args in msgs:
                    if addr == "/audio/bpm" and args:
                        bpm = float(args[0])
                    elif addr == "/audio/lmh" and len(args) >= 3:
                        lmh = [float(a) for a in args[:3]]
                    elif addr.startswith("/audio/onset/"):
                        band = addr.rsplit("/", 1)[1]
                        if band in onset_t:
                            onset_t[band] = now
                            onset_n[band] += 1
            except socket.timeout:
                pass

            now = time.time()
            if now - last_draw < 1 / 30:
                continue
            last_draw = now
            live = now - last_rx < 1.0
            status = f"\x1b[32m● LIVE{RESET}" if live else f"\x1b[31m● NO SIGNAL{RESET}"
            lines = [
                f"{BOLD}M.E.A.T. visualizer feed{RESET}  {DIM}{host}  udp:{PORT}  from {src}  pkts {pkts}{RESET}",
                status,
                "",
                f"{BOLD}BPM{RESET}    {BOLD}{bpm:7.2f}{RESET}",
                "",
                f"{BOLD}LMH{RESET}",
            ]
            for name, v in zip(("low", "mid", "high"), lmh):
                lines.append(f"  {name:<5}{bar(v, COLORS[name])}")
            lines += ["", f"{BOLD}ONSET{RESET}"]
            for name in ("low", "mid", "high"):
                hit = now - onset_t[name] < FLASH_S
                dot = f"{COLORS[name]}{BOLD}██ HIT{RESET}" if hit else f"{DIM}·· ---{RESET}"
                lines.append(f"  {name:<5}{dot}   count {onset_n[name]}")
            sys.stdout.write("\x1b[H" + "\n".join(l + "\x1b[K" for l in lines) + "\x1b[J")
            sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\x1b[?25h" + RESET + "\n")


if __name__ == "__main__":
    main()
