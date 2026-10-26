#!/usr/bin/env python3
"""Check the real release installer and XPI together using a disposable prefix.

No browser registration is written to the user's Library and no internet is needed.
"""
import json
from pathlib import Path
import subprocess
import tempfile

from native_integration import response
from package_smoke import verify_package

ROOT = Path(__file__).resolve().parents[1]


def main():
    extension = verify_package()
    extension_id = extension["browser_specific_settings"]["gecko"]["id"]
    with tempfile.TemporaryDirectory(prefix="daybreak-distribution-") as temporary:
        destination = Path(temporary) / "Application Support" / "Daybreak"
        manifests = Path(temporary) / "NativeMessagingHosts"
        subprocess.run(["bash", str(ROOT / "scripts/install-helper.sh"),
                        "--destination", str(destination), "--manifest-root", str(manifests)], check=True, cwd=ROOT)
        registration = json.loads((manifests / "app.daybreak.helper.json").read_text())
        binary = Path(registration["path"])
        assert binary.is_file() and binary.parent == destination, "Installed helper path is invalid"
        assert registration["allowed_extensions"] == [extension_id], "Native and extension identities differ"
        assert registration["type"] == "stdio", "Native host must use stdio"
        actual = subprocess.check_output([str(binary), "--version"], text=True).strip()
        assert actual == extension["version"], "Helper and add-on versions differ"

        # Start the actual installed release executable via the generated manifest.
        process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, bufsize=0)
        try:
            message = response(process)
            assert message["type"] == "ready", "Installed native host did not become ready"
            assert message["proxy"]["host"] == "127.0.0.1", "Installed listener must remain on loopback"
            assert message["version"] == extension["version"], "Native protocol version report differs"
            process.stdin.close()
            assert process.wait(timeout=3) == 0, "Installed helper did not exit on browser EOF"
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()
    print("Release installation, native startup/shutdown, and extension package passed.")


if __name__ == "__main__":
    main()
