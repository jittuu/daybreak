#!/usr/bin/env python3
"""Opt-in playback/egress validation. Requires an already-active Tailscale exit node.

Uses a disposable Zen profile. Leaves Tailscale and the existing browser profile
unchanged. Writes diagnostics under .build/playback by default.
"""
import argparse
import base64
import csv
from contextlib import contextmanager
import ipaddress
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from browser_smoke import Marionette, helper_processes

ROOT = Path(__file__).resolve().parents[1]
IP_URL = "https://api4.ipify.org/"


def public_ip(interface=None):
    command = ["curl", "-4", "--silent", "--show-error", "--max-time", "20"]
    if interface:
        command.extend(["--interface", interface])
    result = subprocess.check_output(command + [IP_URL], text=True)
    return str(ipaddress.ip_address(result.strip()))


def verify_stream_sockets(raw, streams, interface):
    sockets = {}
    for row in csv.reader(raw.splitlines()):
        if len(row) < 5 or not row[0].startswith("tcp") or "<->" not in row[0]:
            continue
        remote = row[0].split("<->", 1)[1]
        address, _, port = remote.rpartition(":")
        if port != "443" or row[1] == "lo0":
            continue
        if row[1] != interface:
            raise RuntimeError("Helper HTTPS connection used an unexpected interface: " + row[1])
        address = address.strip("[]")
        received = int(row[3] or 0)
        sockets[address] = max(sockets.get(address, 0), received)
    if not sockets:
        raise RuntimeError("No external helper HTTPS sockets were observed")
    matches = []
    for host in sorted({stream["host"] for stream in streams}):
        addresses = set()
        for kind in ["A", "AAAA"]:
            command = ["curl", "--silent", "--show-error", "--max-time", "10", "--interface", interface,
                       "--header", "accept: application/dns-json", "--get", "--data-urlencode", "name=" + host,
                       "--data-urlencode", "type=" + kind, "https://1.1.1.1/dns-query"]
            answer = json.loads(subprocess.check_output(command, text=True))
            addresses.update(item["data"] for item in answer.get("Answer", []) if item.get("type") in [1, 28])
        for address in sorted(addresses):
            if sockets.get(address, 0) > 16384:
                matches.append({"host": host, "address": address, "interface": interface,
                                "bytesReceived": sockets[address]})
    if not matches:
        raise RuntimeError("Could not correlate a video CDN hostname with physical-interface traffic")
    return matches


@contextmanager
def browser(executable, report):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    with tempfile.TemporaryDirectory(prefix="daybreak-playback-") as temporary:
        profile = Path(temporary) / "profile"
        profile.mkdir()
        prefs = {
            "marionette.port": port, "browser.shell.checkDefaultBrowser": False,
            "browser.startup.homepage": "about:blank", "browser.startup.page": 0,
            "browser.aboutwelcome.enabled": False, "zen.welcome-screen.seen": True,
            "datareporting.policy.dataSubmissionPolicyBypassNotification": True,
            "media.autoplay.default": 0, "media.volume_scale": "0.0",
            "intl.accept_languages": "en-US,en",
        }
        (profile / "user.js").write_text("\n".join(f"user_pref({json.dumps(k)}, {json.dumps(v)});" for k, v in prefs.items()))
        with (report / "browser.log").open("w") as log:
            process = subprocess.Popen([executable, "--headless", "--no-remote", "--profile", str(profile),
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
                connection.settimeout(40)
                driver = Marionette(connection)
                driver.command("WebDriver:NewSession", {"capabilities": {"alwaysMatch": {"acceptInsecureCerts": False}}})
                driver.command("WebDriver:SetTimeouts", {"script": 30000, "pageLoad": 30000})
                try:
                    yield driver, process
                finally:
                    try:
                        driver.command("WebDriver:DeleteSession")
                    except Exception:
                        pass
            finally:
                if connection:
                    connection.close()
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def extension_status(driver):
    return driver.script('const done=arguments[arguments.length-1]; browser.runtime.sendMessage({type:"status"}).then(done,e=>done({error:String(e)}));', True)


def media_state(driver):
    return driver.script('''
        const v=document.querySelector("video");
        const q=v?.getVideoPlaybackQuality?.();
        const streams=performance.getEntriesByType("resource").filter(e=>{
          try {const h=new URL(e.name).hostname; return h==="googlevideo.com"||h.endsWith(".googlevideo.com");}catch{return false;}
        }).map(e=>({host:new URL(e.name).hostname,transferSize:e.transferSize,encodedBodySize:e.encodedBodySize,duration:e.duration}));
        return {title:document.title,url:location.origin+location.pathname,
          video:v?{time:v.currentTime,readyState:v.readyState,paused:v.paused,ended:v.ended,
            width:v.videoWidth,height:v.videoHeight,decodedFrames:q?.totalVideoFrames??0,
            droppedFrames:q?.droppedVideoFrames??0,error:v.error?.code??null}:null,
          adShowing:!!document.querySelector(".ad-showing"),streams,
          playerMessage:document.querySelector(".ytp-error-content-wrap")?.textContent?.trim()||null};
    ''')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zen", default="/Applications/Zen.app/Contents/MacOS/zen")
    parser.add_argument("--video-url", default="https://www.youtube.com/watch?v=aqz-KE-bpKQ")
    parser.add_argument("--physical-interface", default="en0")
    parser.add_argument("--seconds", type=int, default=30, help="Required uninterrupted playback progression")
    parser.add_argument("--report-dir", type=Path, default=ROOT / ".build/playback")
    args = parser.parse_args()
    report = args.report_dir.resolve()
    report.mkdir(parents=True, exist_ok=True)
    result = {"success": False, "videoURL": args.video_url}
    try:
        ts = json.loads(subprocess.check_output(["/usr/local/bin/tailscale", "status", "--json"], text=True))
        if ts.get("BackendState") != "Running" or not ts.get("ExitNodeStatus", {}).get("Online"):
            raise RuntimeError("An online exit node must already be active")
        result["exitNode"] = {k: ts["ExitNodeStatus"].get(k) for k in ["ID", "Online", "TailscaleIPs"]}
        result["systemPublicIP"] = public_ip()
        result["physicalPublicIP"] = public_ip(args.physical_interface)
        if result["systemPublicIP"] == result["physicalPublicIP"]:
            raise RuntimeError("Public IPs do not distinguish the exit and physical paths")
        print("Exit node active; system and physical public IPs differ.", flush=True)
        version = json.loads((ROOT / "extension/manifest.json").read_text())["version"]
        archive = ROOT / "dist" / f"daybreak-{version}-unsigned.xpi"
        with browser(args.zen, report) as (driver, process):
            try:
                driver.command("Addon:Install", {"path": str(archive), "temporary": True})
                driver.command("Marionette:SetContext", {"value": "chrome"})
                popup = driver.script('return WebExtensionPolicy.getByID("daybreak@jittuu.github.io").getURL("popup.html");')
                driver.command("Marionette:SetContext", {"value": "content"})
                driver.command("WebDriver:Navigate", {"url": popup})
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    status = extension_status(driver)
                    if status.get("connected") and status.get("networkAvailable"):
                        break
                    time.sleep(.2)
                if not status.get("connected"):
                    raise RuntimeError("Helper not ready: " + json.dumps(status))
                result["helperInterface"] = status.get("interface")
                if result["helperInterface"] != args.physical_interface:
                    raise RuntimeError("Helper interface differs from the physical-IP baseline interface")
                diagnostics_tab = driver.command("WebDriver:GetWindowHandle")
                driver.command("WebDriver:Navigate", {"url": IP_URL})
                ip = str(ipaddress.ip_address(driver.script("return document.body.innerText;").strip()))
                result["browserPublicIPBefore"] = ip
                if ip != result["systemPublicIP"]:
                    raise RuntimeError("Ordinary browser traffic did not use the exit-node IP")
                print("Ordinary Zen browsing shows the exit-node public IP.", flush=True)

                video_tab = driver.command("WebDriver:NewWindow", {"type": "tab"})["handle"]
                driver.command("WebDriver:SwitchToWindow", {"handle": video_tab})
                driver.command("WebDriver:Navigate", {"url": args.video_url})
                print("YouTube opened; waiting for decoded video frames.", flush=True)
                samples = []
                started = None
                deadline = time.monotonic() + args.seconds + 60
                while time.monotonic() < deadline:
                    driver.script('const v=document.querySelector("video"); if(v){v.muted=true; if(v.paused) v.play().catch(()=>{});}')
                    sample = media_state(driver)
                    samples.append(sample)
                    video = sample.get("video")
                    if sample.get("playerMessage"):
                        raise RuntimeError("YouTube player: " + sample["playerMessage"])
                    if video and not sample["adShowing"] and video["width"] > 0 and video["decodedFrames"] > 0 and not video["paused"]:
                        if started is None:
                            started = video
                        if video["time"] - started["time"] >= args.seconds and video["decodedFrames"] - started["decodedFrames"] >= 30:
                            result["playbackStart"] = started
                            result["playbackEnd"] = video
                            result["streams"] = sample["streams"]
                            break
                    time.sleep(1)
                else:
                    result["lastMediaState"] = samples[-1] if samples else None
                    raise RuntimeError("Video did not advance with decoded frames within the playback deadline")
                result["mediaSamples"] = samples
                helpers = helper_processes(process.pid)
                if len(helpers) != 1:
                    raise RuntimeError("Expected exactly one browser-owned helper")
                raw = subprocess.check_output(["/usr/bin/nettop", "-n", "-m", "tcp", "-p", str(helpers[0]), "-L", "2", "-s", "1", "-x", "-J", "interface,state,bytes_in,bytes_out"], text=True, timeout=8)
                (report / "helper-nettop.csv").write_text(raw)
                result["socketSample"] = raw
                result["verifiedVideoSockets"] = verify_stream_sockets(raw, result["streams"], result["helperInterface"])
                driver.command("WebDriver:SwitchToWindow", {"handle": diagnostics_tab})
                driver.command("WebDriver:Navigate", {"url": IP_URL + "?after=" + str(time.time_ns())})
                result["browserPublicIPDuringPlayback"] = str(ipaddress.ip_address(driver.script("return document.body.innerText;").strip()))
                if result["browserPublicIPDuringPlayback"] != result["systemPublicIP"]:
                    raise RuntimeError("Ordinary browsing changed egress during playback")
                driver.command("WebDriver:SwitchToWindow", {"handle": video_tab})
                result["mediaAfterOrdinaryBrowsing"] = media_state(driver)
                final = result["mediaAfterOrdinaryBrowsing"]["video"]
                if not final or final["paused"] or final["time"] <= result["playbackEnd"]["time"]:
                    raise RuntimeError("Playback did not continue during ordinary browsing")
                driver.script('document.querySelector("video")?.pause();')
                screenshot = driver.command("WebDriver:TakeScreenshot", {})
                (report / "playback.png").write_bytes(base64.b64decode(screenshot))
                driver.command("WebDriver:SwitchToWindow", {"handle": diagnostics_tab})
                driver.command("WebDriver:Navigate", {"url": popup})
                result["extensionAfterPlayback"] = extension_status(driver)
                result["success"] = True
                print("Video advanced with decoded frames; ordinary browsing retained the exit IP.", flush=True)
            except Exception:
                try:
                    result["lastMediaState"] = media_state(driver)
                    screenshot = driver.command("WebDriver:TakeScreenshot", {})
                    (report / "failure.png").write_bytes(base64.b64decode(screenshot))
                except Exception:
                    pass
                raise
    except Exception as error:
        result["error"] = str(error)
        raise
    finally:
        (report / "report.json").write_text(json.dumps(result, indent=2) + "\n")
        print("Evidence: " + str(report), flush=True)


if __name__ == "__main__":
    main()
