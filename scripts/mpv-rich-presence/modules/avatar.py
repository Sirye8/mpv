# SPDX-License-Identifier: AGPL-3.0-or-later
"""Decode one AniList avatar to the raw format used by mpv overlays."""

import ctypes
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit
import urllib.request


def player_path(pid):
    if os.name != "nt":
        return os.readlink(f"/proc/{pid}/exe")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.restype = ctypes.c_void_p
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        raise OSError("Could not open mpv.")
    try:
        path = ctypes.create_unicode_buffer(32768)
        size = ctypes.c_ulong(len(path))
        if not kernel.QueryFullProcessImageNameW(ctypes.c_void_p(handle), 0, path, ctypes.byref(size)):
            raise OSError("Could not find mpv.")
        return path.value
    finally:
        kernel.CloseHandle(ctypes.c_void_p(handle))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def main(address, pid):
    parsed = urlsplit(address)
    if parsed.scheme != "https" or parsed.netloc != "s4.anilist.co":
        raise ValueError("Unexpected AniList avatar host.")
    request = urllib.request.Request(address, headers={
        "User-Agent": "mpv-rich-presence (+https://github.com/Sirye8/mpv-rich-presence)",
    })
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=6) as response:
        data = response.read(512 * 1024 + 1)
    if len(data) > 512 * 1024 or not data.startswith((b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"GIF8", b"RIFF")):
        raise ValueError("Unsupported avatar.")
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "avatar"
        source.write_bytes(data)
        output = source.with_suffix(".bgra")
        subprocess.run(
            [player_path(int(pid)), "--no-config", "--load-scripts=no", "--no-audio",
             "--no-terminal", "--frames=1", "--vf=scale=64:64,format=bgra", "--of=rawvideo",
             "--ovc=rawvideo", f"--o={output}", "--", str(source)],
            timeout=8, check=True,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
        pixels = bytearray(output.read_bytes())
    if len(pixels) != 64 * 64 * 4:
        raise ValueError("Unexpected avatar dimensions.")
    for y in range(64):
        for x in range(64):
            if (x - 31.5)**2 + (y - 31.5)**2 > 31.5**2:
                offset = (y * 64 + x) * 4
                pixels[offset:offset + 4] = b"\0" * 4
    sys.stdout.buffer.write(pixels)


if __name__ == "__main__":
    main(*sys.argv[1:])
