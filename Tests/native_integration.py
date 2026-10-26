#!/usr/bin/env python3
"""Exercise the real helper over stdio and loopback; never needs internet or Tailscale."""
import json
from pathlib import Path
import select
import socket
import struct
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / ".build" / "debug" / "daybreak-helper"


def exact(stream, count):
    result = bytearray()
    while len(result) < count:
        chunk = stream.recv(count - len(result)) if isinstance(stream, socket.socket) else stream.read(count - len(result))
        if not chunk:
            raise EOFError("Truncated response")
        result.extend(chunk)
    return bytes(result)


def message(process, command):
    data = json.dumps(command).encode()
    process.stdin.write(struct.pack("<I", len(data)) + data)
    process.stdin.flush()


def response(process):
    if not select.select([process.stdout], [], [], 8)[0]:
        raise TimeoutError("Native host did not respond")
    length, = struct.unpack("<I", exact(process.stdout, 4))
    if not 0 < length <= 65536:
        raise ValueError("Invalid native frame length")
    return json.loads(exact(process.stdout, length))


class NativeIntegration(unittest.TestCase):
    def setUp(self):
        self.process = subprocess.Popen([str(BINARY)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        while True:
            self.status = response(self.process)
            if self.status["type"] == "ready":
                break
        self.proxy = self.status["proxy"]

    def tearDown(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.process.stdout.close()
        self.process.stderr.close()

    def connect(self):
        return socket.create_connection((self.proxy["host"], self.proxy["port"]), timeout=3)

    def authenticate(self, connection, password=None):
        # Deliberately fragment writes: SOCKS is a TCP byte stream, not a message protocol.
        connection.sendall(b"\x05")
        connection.sendall(b"\x01\x02")
        self.assertEqual(exact(connection, 2), b"\x05\x02")
        name = self.proxy["username"].encode()
        token = (password or self.proxy["password"]).encode()
        connection.sendall(bytes([1, len(name)]) + name + bytes([len(token)]) + token)
        return exact(connection, 2)

    def test_native_status_and_browser_eof_shutdown(self):
        self.assertEqual(self.status["protocolVersion"], 1)
        self.assertEqual(self.proxy["host"], "127.0.0.1")
        message(self.process, {"type": "status"})
        value = response(self.process)
        self.assertEqual(value["type"], "status")
        self.assertEqual(value["proxy"]["password"], self.proxy["password"])
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=3), 0)

    def test_unauthenticated_and_wrong_password_clients_are_rejected(self):
        with self.connect() as connection:
            connection.sendall(b"\x05\x01\x00")
            self.assertEqual(exact(connection, 2), b"\x05\xff")
        with self.connect() as connection:
            self.assertEqual(self.authenticate(connection, "wrong-password"), b"\x01\x01")

    def test_non_youtube_domain_is_rejected_before_dns(self):
        with self.connect() as connection:
            self.assertEqual(self.authenticate(connection), b"\x01\x00")
            host = b"youtube.com.attacker.test"
            connection.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack("!H", 443))
            self.assertEqual(exact(connection, 10)[1], 2)

    def test_non_web_ports_literal_ips_and_udp_are_rejected(self):
        for request, reason in [
            (b"\x05\x01\x00\x03\x0byoutube.com" + struct.pack("!H", 22), 2),
            (b"\x05\x01\x00\x01\x7f\x00\x00\x01\x01\xbb", 8),
            (b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00", 7),
        ]:
            with self.connect() as connection:
                self.assertEqual(self.authenticate(connection), b"\x01\x00")
                connection.sendall(request)
                self.assertEqual(exact(connection, 10)[1], reason)

    def test_invalid_native_frame_terminates_without_listening_forever(self):
        self.process.stdin.write(struct.pack("<I", 65537))
        self.process.stdin.flush()
        self.assertEqual(self.process.wait(timeout=3), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
