#!/usr/bin/env python3
"""Check that the distributable XPI exactly contains the extension source."""
import json
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]


def verify_package():
    extension = json.loads((ROOT / "extension/manifest.json").read_text())
    archive = ROOT / "dist" / f"daybreak-{extension['version']}-unsigned.xpi"
    with ZipFile(archive) as package:
        assert package.testzip() is None, "Corrupt extension archive"
        packaged = json.loads(package.read("manifest.json"))
        assert packaged == extension, "Packaged manifest does not match source"
        entries = {entry.relative_to(ROOT / "extension").as_posix(): entry
                   for entry in (ROOT / "extension").rglob("*")
                   if entry.is_file() and not entry.name.startswith(".")}
        assert set(package.namelist()) == set(entries), "Package has missing or unexpected files"
        for name, source in entries.items():
            assert package.read(name) == source.read_bytes(), f"Stale package entry: {name}"
    return extension


if __name__ == "__main__":
    verify_package()
    print("Extension package matches its manifest and all current source files.")
