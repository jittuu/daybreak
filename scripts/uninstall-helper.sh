#!/bin/bash
set -euo pipefail
rm -f "${HOME}/Library/Application Support/Mozilla/NativeMessagingHosts/app.daybreak.helper.json"
rm -f "${HOME}/Library/Application Support/Daybreak/daybreak-helper"
rmdir "${HOME}/Library/Application Support/Daybreak" 2>/dev/null || true
echo "Helper registration removed. Remove the Daybreak add-on from Zen to finish."
