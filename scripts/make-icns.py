#!/usr/bin/env python3
"""Pack the generated PNG icon sizes into an ICNS file without external modules."""

from pathlib import Path
import struct
import sys


iconset = Path(sys.argv[1])
destination = Path(sys.argv[2])
sizes = (
    (b"ic04", "icon_16x16.png"),
    (b"ic05", "icon_32x32.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
    (b"ic11", "icon_16x16@2x.png"),
    (b"ic12", "icon_32x32@2x.png"),
    (b"ic13", "icon_128x128@2x.png"),
    (b"ic14", "icon_256x256@2x.png"),
)
chunks = []
for kind, filename in sizes:
    image = (iconset / filename).read_bytes()
    if not image.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"Not a PNG: {filename}")
    chunks.append(kind + struct.pack(">I", len(image) + 8) + image)
payload = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
