#!/bin/bash
# Byg FS25_TrafficLights.zip fra mod-mappen. Brug: ./build.sh [--install]
# --install lægger zip'en atomisk i mods-mappen (cp .tmp + mv), men kun når spillet ikke kører.
set -euo pipefail
cd "$(dirname "$0")"
bash tests/run_all.sh >/dev/null || { echo "tests fejler - bygger ikke"; exit 1; }
rm -f FS25_TrafficLights.zip
(cd FS25_TrafficLights && zip -qr ../FS25_TrafficLights.zip . -x '*.png' -x '.remember/*')
echo "bygget: $(unzip -p FS25_TrafficLights.zip modDesc.xml | grep -o '<version>[^<]*')"
if [ "${1:-}" = "--install" ]; then
    if pgrep -f '[F]armingSimulator2025Game' >/dev/null; then echo "spillet kører - installerer ikke"; exit 2; fi
    MODS="$HOME/.local/share/Steam/steamapps/compatdata/2300320/pfx/drive_c/users/steamuser/Documents/My Games/FarmingSimulator2025/mods"
    cp FS25_TrafficLights.zip "$MODS/FS25_TrafficLights.zip.tmp"
    mv "$MODS/FS25_TrafficLights.zip.tmp" "$MODS/FS25_TrafficLights.zip"
    echo "installeret $(date +%H:%M)"
fi
