#!/bin/bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_root="${HOME}/Library/Application Support/Daybreak"
manifest_root="${HOME}/Library/Application Support/Mozilla/NativeMessagingHosts"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --destination) install_root="$2"; shift 2 ;;
    --manifest-root) manifest_root="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$project_root"
swift build -c release --disable-sandbox
binary_dir="$(swift build -c release --disable-sandbox --show-bin-path)"
mkdir -p "$install_root" "$manifest_root"
install -m 755 "$binary_dir/daybreak-helper" "$install_root/daybreak-helper.new"
mv -f "$install_root/daybreak-helper.new" "$install_root/daybreak-helper"

python3 - "$install_root/daybreak-helper" "$manifest_root/app.daybreak.helper.json" <<'PY'
import json, os, sys
binary, destination = sys.argv[1:]
document = {
    "name": "app.daybreak.helper", "description": "Daybreak physical-interface proxy",
    "path": os.path.abspath(binary), "type": "stdio",
    "allowed_extensions": ["daybreak@jittuu.github.io"]
}
temporary = destination + ".new"
with open(temporary, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
os.replace(temporary, destination)
PY

echo "Helper installed: $install_root/daybreak-helper"
echo "Native manifest: $manifest_root/app.daybreak.helper.json"
echo "Load extension/manifest.json as a temporary add-on in Zen's about:debugging page."
