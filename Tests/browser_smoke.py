#!/usr/bin/env python3
"""Opt-in Zen end-to-end smoke test. Uses a disposable profile and the installed helper.

Run `bash scripts/install-helper.sh` and `make package` first. No third-party Python
packages are required. This never uses or modifies your existing Zen profile.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def helper_processes(browser_pid):
    """Only inspect native helpers descended from this disposable browser process."""
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,comm="], text=True)
    processes = {}
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            processes[int(parts[0])] = (int(parts[1]), parts[2])
    result = []
    for pid, (_, executable) in processes.items():
        if not executable.endswith("/daybreak-helper"):
            continue
        ancestor = pid
        visited = set()
        while ancestor in processes and ancestor not in visited:
            visited.add(ancestor)
            ancestor = processes[ancestor][0]
            if ancestor == browser_pid:
                result.append(pid)
                break
    return result


class Marionette:
    def __init__(self, connection):
        self.connection = connection
        self.sequence = 0
        self.receive()  # Server greeting.

    def exact(self, count):
        result = bytearray()
        while len(result) < count:
            chunk = self.connection.recv(count - len(result))
            if not chunk:
                raise EOFError("Browser closed its automation connection")
            result.extend(chunk)
        return bytes(result)

    def receive(self):
        prefix = bytearray()
        while (value := self.exact(1)) != b":":
            prefix.extend(value)
            if len(prefix) > 12:
                raise ValueError("Invalid browser response length")
        return json.loads(self.exact(int(prefix)))

    def command(self, name, parameters=None):
        self.sequence += 1
        data = json.dumps([0, self.sequence, name, parameters or {}]).encode()
        self.connection.sendall(str(len(data)).encode() + b":" + data)
        result = self.receive()
        if result[1] != self.sequence:
            raise RuntimeError("Unexpected automation response")
        if result[2]:
            raise RuntimeError(f"{name}: {result[2].get('message', result[2])}")
        value = result[3]
        return value.get("value", value) if isinstance(value, dict) else value

    def script(self, source, asynchronous=False):
        return self.command("WebDriver:ExecuteAsyncScript" if asynchronous else "WebDriver:ExecuteScript",
                            {"script": source, "args": [], "newSandbox": False, "sandbox": None})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zen", default="/Applications/Zen.app/Contents/MacOS/zen")
    args = parser.parse_args()
    version = json.loads((ROOT / "extension/manifest.json").read_text())["version"]
    archive = ROOT / "dist" / f"daybreak-{version}-unsigned.xpi"
    if not archive.exists():
        raise SystemExit("Run make package first")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="daybreak-browser-") as temporary:
        profile = Path(temporary) / "profile"
        profile.mkdir()
        prefs = {
            "marionette.port": port, "browser.shell.checkDefaultBrowser": False,
            "browser.startup.homepage": "about:blank", "browser.startup.page": 0,
            "browser.aboutwelcome.enabled": False, "zen.welcome-screen.seen": True,
            "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
        }
        (profile / "user.js").write_text("\n".join(f"user_pref({json.dumps(key)}, {json.dumps(value)});" for key, value in prefs.items()))
        with (Path(temporary) / "browser.log").open("w+") as log:
            process = subprocess.Popen([args.zen, "--headless", "--no-remote", "--profile", str(profile),
                                        "--marionette", "--remote-allow-system-access"], stdout=log, stderr=log)
            connection = None
            try:
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError("Zen exited before automation started")
                    try:
                        connection = socket.create_connection(("127.0.0.1", port), timeout=1)
                        break
                    except OSError:
                        time.sleep(.1)
                if connection is None:
                    raise TimeoutError("Zen automation did not start")
                connection.settimeout(35)
                driver = Marionette(connection)
                session = driver.command("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {"acceptInsecureCerts": False}}})
                driver.command("WebDriver:SetTimeouts", {"script": 30000, "pageLoad": 30000})
                driver.command("Addon:Install", {"path": str(archive), "temporary": True})
                driver.command("Marionette:SetContext", {"value": "chrome"})
                popup = driver.script('return WebExtensionPolicy.getByID("daybreak@jittuu.github.io").getURL("popup.html");')
                driver.command("Marionette:SetContext", {"value": "content"})
                driver.command("WebDriver:Navigate", {"url": popup})
                status = None
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    status = driver.script('const done = arguments[arguments.length - 1]; browser.runtime.sendMessage({type:"status"}).then(done, e => done({error:String(e)}));', True)
                    if status.get("connected") and status.get("networkAvailable"):
                        break
                    time.sleep(.2)
                if not status or not status.get("connected") or not status.get("networkAvailable"):
                    raise RuntimeError("Native helper not ready: " + json.dumps(status))

                result = driver.script('''
                    const done = arguments[arguments.length - 1];
                    fetch("https://www.youtube.com/robots.txt", {cache:"no-store"})
                      .then(async response => done({status:response.status, bytes:(await response.text()).length}))
                      .catch(error => done({error:String(error)}));
                ''', True)
                after = driver.script('const done = arguments[arguments.length - 1]; browser.runtime.sendMessage({type:"status"}).then(done);', True)
                if result.get("status") != 200 or after["requestsRouted"] <= status["requestsRouted"]:
                    raise RuntimeError("YouTube did not route through the extension: " + json.dumps({"fetch": result, "status": after}))

                # An unrelated website must never enter our proxy path.
                driver.command("WebDriver:Navigate", {"url": "https://example.com/"})
                driver.command("WebDriver:Navigate", {"url": popup})
                ordinary = driver.script('const done=arguments[arguments.length-1]; browser.runtime.sendMessage({type:"status"}).then(done);', True)
                if ordinary["requestsRouted"] != after["requestsRouted"]:
                    raise RuntimeError("Unrelated browsing entered the YouTube route")

                helpers = helper_processes(process.pid)
                if len(helpers) != 1:
                    raise RuntimeError(f"Expected one browser-owned helper, found {len(helpers)}")
                # RSS includes shared framework pages; this is an observation, not a budget promise.
                idle_rss = int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(helpers[0])], text=True).strip())

                disabled = driver.script('const done=arguments[arguments.length-1]; browser.runtime.sendMessage({type:"toggle",enabled:false}).then(done);', True)
                if disabled["connected"] or disabled["enabled"]:
                    raise RuntimeError("Disabling did not disconnect the helper")
                deadline = time.monotonic() + 3
                while helper_processes(process.pid) and time.monotonic() < deadline:
                    time.sleep(.1)
                if helper_processes(process.pid):
                    raise RuntimeError("Native helper survived the extension disconnect")
                print(json.dumps({"browserVersion": session.get("capabilities", {}).get("browserVersion"),
                                  "nativeMessaging": "passed", "youtubeFetch": result,
                                  "requestsRouted": after["requestsRouted"], "interface": after["interface"],
                                  "ordinaryWebsiteUnaffected": "passed", "helperProcesses": len(helpers),
                                  "helperRSSKiBAfterFetch": idle_rss,
                                  "toggleDisconnect": "passed", "helperExited": "passed", "profile": "disposable",
                                  "exitNodeBypass": "not established by this test"}, indent=2))
                driver.command("WebDriver:DeleteSession")
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read()[-6000:])
                raise
            finally:
                if connection:
                    connection.close()
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
