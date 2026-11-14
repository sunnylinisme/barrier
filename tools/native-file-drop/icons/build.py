#!/usr/bin/env python3
"""Regenerate the checked-in macOS/Windows icons on a Mac; no third-party packages."""
from pathlib import Path
import shutil
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
    # Let macOS encode small icons correctly instead of interpreting PNG bytes as pixels.
    iconset = p / 'BarrierShare.iconset'
    iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            suffix = '@2x' if scale == 2 else ''
            shutil.copyfile(p / f'icon-{size * scale}.png',
                            iconset / f'icon_{size}x{size}{suffix}.png')
    subprocess.run(['iconutil', '-c', 'icns', '-o', str(root / 'BarrierShare.icns'),
                    str(iconset)], check=True)
