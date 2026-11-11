#!/usr/bin/env python3
"""Regenerate the checked-in macOS/Windows icons on a Mac; no third-party packages."""
from pathlib import Path
import struct
import subprocess
import tempfile
root = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='barrier-icons-') as temporary:
    p = Path(temporary)
    subprocess.run(['swift', str(root / 'generate.swift'), str(p)], check=True)
    sizes = [16, 32, 64, 128, 256]
    offset = 6 + 16 * len(sizes)
    entries, data = [], []
    for size in sizes:
        png = (p / f'icon-{size}.png').read_bytes()
        entries.append(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0, 1, 32, len(png), offset))
        data.append(png)
        offset += len(png)
    (root / 'BarrierShare.ico').write_bytes(struct.pack('<HHH', 0, 1, len(sizes)) + b''.join(entries + data))
    chunks = []
    for size, kind in [(16, b'icp4'), (32, b'icp5'), (64, b'icp6'), (128, b'ic07'), (256, b'ic08'), (512, b'ic09'), (1024, b'ic10')]:
        png = (p / f'icon-{size}.png').read_bytes()
        chunks.append(kind + struct.pack('>I', len(png) + 8) + png)
    data = b''.join(chunks)
    (root / 'BarrierShare.icns').write_bytes(b'icns' + struct.pack('>I', len(data) + 8) + data)
