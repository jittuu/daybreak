#!/usr/bin/env python3
"""Create an unsigned development XPI using only the Python standard library."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import json

root = Path(__file__).resolve().parents[1]
version = json.loads((root / "extension/manifest.json").read_text())["version"]
destination = root / "dist" / f"daybreak-{version}-unsigned.xpi"
destination.parent.mkdir(exist_ok=True)
with ZipFile(destination, "w", ZIP_DEFLATED) as archive:
    for source in sorted((root / "extension").rglob("*")):
        if source.is_file() and not source.name.startswith("."):
            archive.write(source, source.relative_to(root / "extension"))
print(destination)
