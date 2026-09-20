#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
ICONSET_PATH="$iconset" OUTPUT_PATH="$PWD/Assets/AppIcon.icns" python3 - <<'PY'
from pathlib import Path
import os
import struct

iconset = Path(os.environ["ICONSET_PATH"])
chunks = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png"),
]
body = b""
for kind, filename in chunks:
    data = (iconset / filename).read_bytes()
    body += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
output = b"icns" + struct.pack(">I", len(body) + 8) + body
Path(os.environ["OUTPUT_PATH"]).write_bytes(output)
PY
