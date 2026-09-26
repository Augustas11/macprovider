#!/usr/bin/env python3
"""Pause or resume the live :8080 provider over its control socket (same EUID).
usage: live-ctl.py pause|resume   -> prints the ack frame; exit 0 iff accepted."""
import glob, json, socket, sys, time
op = sys.argv[1]
paths = glob.glob("/var/folders/*/*/T/macprovider-cli/ctl.sock")
if not paths: print("no control socket"); sys.exit(2)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(180); s.connect(paths[0])
s.sendall((json.dumps({"type": f"{op}_request"}) + "\n").encode())
buf = b""; deadline = time.time() + 180
while time.time() < deadline:
    chunk = s.recv(65536)
    if not chunk: break
    buf += chunk
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        try: frame = json.loads(line)
        except Exception: continue
        if frame.get("type") == f"{op}_ack":
            print(json.dumps(frame)); sys.exit(0 if frame.get("accepted") else 1)
print("no ack"); sys.exit(3)
