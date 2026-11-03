#!/usr/bin/env python3
"""Package the generated artwork as a modern PNG-backed macOS ICNS file.

Only deterministic resizing is performed. The logo's composition and alpha are
not retouched. Requires macOS sips; no third-party Python packages are needed.
"""
from pathlib import Path
import struct
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent
    source = root / "Backdrop-AppIcon.png"
    entries = [
        (b"icp4", 16), (b"icp5", 32), (b"icp6", 64),
        (b"ic07", 128), (b"ic08", 256), (b"ic09", 512),
        (b"ic10", 1024), (b"ic11", 32), (b"ic12", 64),
        (b"ic13", 256), (b"ic14", 512),
    ]
    with tempfile.TemporaryDirectory(prefix="backdrop-icon-") as folder:
        chunks = []
        resized = {}
        for kind, size in entries:
            if size not in resized:
                output = Path(folder) / f"{size}.png"
                subprocess.run(
                    ["/usr/bin/sips", "-z", str(size), str(size),
                     str(source), "--out", str(output)],
                    check=True, stdout=subprocess.DEVNULL,
                )
                resized[size] = output.read_bytes()
            data = resized[size]
            chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
        payload = b"".join(chunks)
        destination = root / "Backdrop.icns"
        destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
        print(destination)


if __name__ == "__main__":
    main()
