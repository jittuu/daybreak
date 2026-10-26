#!/usr/bin/env python3
"""Opt-in internet test of real SOCKS5 + remote DNS + TLS forwarding. No browser changes."""
import argparse
import json
from pathlib import Path
import select
import socket
import ssl
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.recv(count - len(result)) if isinstance(stream, socket.socket) else stream.read(count - len(result))
        if not chunk:
            raise EOFError("Truncated response")
        result.extend(chunk)
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / ".build/debug/daybreak-helper")
    parser.add_argument("--host", default="www.youtube.com")
    parser.add_argument("--path", default="/robots.txt")
    args = parser.parse_args()
    start = time.monotonic()
    process = subprocess.Popen([str(args.binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    try:
        if not select.select([process.stdout], [], [], 8)[0]:
            raise TimeoutError("Helper did not start")
        length, = struct.unpack("<I", exact(process.stdout, 4))
        status = json.loads(exact(process.stdout, length))
        if status.get("type") != "ready" or not status.get("networkAvailable"):
            raise RuntimeError("No usable physical network: " + str(status.get("interface")))
        proxy = status["proxy"]
        with socket.create_connection(("127.0.0.1", proxy["port"]), timeout=30) as raw:
            raw.sendall(b"\x05\x01\x02")
            if exact(raw, 2) != b"\x05\x02":
                raise RuntimeError("SOCKS method rejected")
            username, password = proxy["username"].encode(), proxy["password"].encode()
            raw.sendall(bytes([1, len(username)]) + username + bytes([len(password)]) + password)
            if exact(raw, 2) != b"\x01\x00":
                raise RuntimeError("SOCKS authentication rejected")
            host = args.host.encode("ascii")
            raw.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 443))
            result = exact(raw, 10)
            if result[1] != 0:
                raise RuntimeError(f"SOCKS connection failed with code {result[1]}")
            with ssl.create_default_context().wrap_socket(raw, server_hostname=args.host) as secured:
                secured.sendall(f"GET {args.path} HTTP/1.1\r\nHost: {args.host}\r\nConnection: close\r\n\r\n".encode("ascii"))
                total = 0
                first = b""
                while chunk := secured.recv(32768):
                    if not first:
                        first = chunk.split(b"\r\n", 1)[0]
                    total += len(chunk)
                    if total > 16 * 1024 * 1024:
                        raise RuntimeError("Smoke response exceeded 16 MiB")
                if b" 200 " not in first:
                    raise RuntimeError("Unexpected upstream response: " + first.decode("ascii", "replace"))
                print(json.dumps({"host": args.host, "interface": status["interface"],
                                  "httpStatus": first.decode("ascii"), "bytesReceived": total,
                                  "seconds": round(time.monotonic() - start, 3),
                                  "tlsVerified": True}, indent=2))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        if process.returncode:
            print(process.stderr.read().decode("utf8", "replace"))
        process.stdout.close()
        process.stderr.close()


if __name__ == "__main__":
    main()
