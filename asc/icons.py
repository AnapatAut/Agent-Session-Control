"""The dashboard's icons, drawn as PNGs in plain Python (the repo holds no binary files).

The glyph is a switch turned on: a white pill outline with a lime knob, on a blue tile (the same
drawing as web/favicon.svg). Shapes are drawn from their signed distance, so edges are smooth
at any size without scaling down. Plates and sizes follow the installable-app recipe:
  icon-*.png           plain white: Chrome draws it on Android's own launch screen (which cannot
                       be turned off), white on white hides it, so only the page's splash shows.
  icon-maskable-*.png  the tile edge to edge, corners rounded 18% (white only in the corners),
                       glyph at 0.8 of its tile scale. Launchers show about the middle 82% and cut
                       their own shape, so no white frame; Samsung Internet shows it uncut on its
                       launch screen, where the white corners vanish on white.
  splash-512.png       the same tile, so the page's splash starts where Samsung's ends.
  apple-touch-icon.png full bleed (iOS rounds it itself; transparency would turn black).
  favicon-512.png      the tab icon, transparent outside the tile.
Drawing the set takes about 1.5 s, and the dashboard starts again after every idle exit, so each
PNG is kept in ~/.cache/agent-session-control/icons under a name that changes with this file.
"""
import functools
import hashlib
import math
import os
import struct
import zlib

from . import live

BLUE, LIME, WHITE = (0x3d, 0x3d, 0xf5), (0xd7, 0xf3, 0x4f), (0xff, 0xff, 0xff)
# The glyph on a 32-unit grid, as in web/favicon.svg.
PILL = (6.5, 11, 25.5, 21)   # x0, y0, x1, y1 of the outline's centre line
PILL_R, STROKE = 5, 2.4
KNOB = (20.5, 16, 3.2)       # cx, cy, r
# name: (size, glyph scale, tile corner radius as a share of the size, plate; None = transparent)
ICONS = {
    "icon-maskable-192.png": (192, 0.8, 0.18, WHITE),
    "icon-maskable-512.png": (512, 0.8, 0.18, WHITE),
    "splash-512.png": (512, 0.8, 0.18, WHITE),
    "apple-touch-icon.png": (180, 0.97, 0, WHITE),
    "favicon-512.png": (512, 1, 0.25, None),
    "icon-192.png": (192, 0, 0, WHITE),  # glyph 0: plain white
    "icon-512.png": (512, 0, 0, WHITE),
}


def _box(px, py, x0, y0, x1, y1, r):
    """Signed distance from (px, py) to a rectangle with corners rounded r (negative inside)."""
    qx = abs(px - (x0 + x1) / 2) - (x1 - x0) / 2 + r
    qy = abs(py - (y0 + y1) / 2) - (y1 - y0) / 2 + r
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r


def _cover(d):
    """How much of a pixel a shape covers, from the distance of the pixel's centre to its edge."""
    return 0.0 if d >= 0.5 else 1.0 if d <= -0.5 else 0.5 - d


def _over(dst, colour, a):
    if a <= 0:
        return dst
    r, g, b, da = dst
    out = a + da * (1 - a)
    if out <= 0:
        return dst
    mix = lambda c, d: (c * a + d * da * (1 - a)) / out
    return (mix(colour[0], r), mix(colour[1], g), mix(colour[2], b), out)


def pixels(n, glyph, rad, plate):
    """Rows of (r, g, b, a) floats for an n px icon."""
    k = n / 32 * glyph
    f = lambda u: n / 2 + (u - 16) * k
    h = STROKE / 2
    x0, y0, x1, y1 = PILL
    outer = (f(x0 - h), f(y0 - h), f(x1 + h), f(y1 + h), (PILL_R + h) * k)
    inner = (f(x0 + h), f(y0 + h), f(x1 - h), f(y1 - h), (PILL_R - h) * k)
    kx, ky, kr = f(KNOB[0]), f(KNOB[1]), KNOB[2] * k
    corner = n * rad
    base = (plate + (1.0,)) if plate else (0, 0, 0, 0.0)
    rows = []
    for y in range(n):
        py = y + 0.5
        row = []
        for x in range(n):
            px = x + 0.5
            c = base
            if glyph:
                c = _over(c, BLUE, _cover(_box(px, py, 0, 0, n, n, corner)) if corner else 1.0)
                if outer[1] - 1 <= py <= outer[3] + 1 and outer[0] - 1 <= px <= outer[2] + 1:
                    c = _over(c, WHITE, _cover(_box(px, py, *outer)))
                    c = _over(c, BLUE, _cover(_box(px, py, *inner)))
                    c = _over(c, LIME, _cover(math.hypot(px - kx, py - ky) - kr))
            row.append(c)
        rows.append(row)
    return rows


def png(rows, alpha):
    """A PNG of the rows: RGBA when alpha, else RGB."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        for r, g, b, a in row:
            raw += bytes((round(r), round(g), round(b))) + (bytes((round(a * 255),)) if alpha else b"")
    n = len(rows)
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6 if alpha else 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


PNG_SIG = b"\x89PNG\r\n\x1a\n"
# Changes whenever this file does, so a cached icon is never one drawn by an older version.
with open(__file__, "rb") as _f:
    _KEY = hashlib.sha256(_f.read()).hexdigest()[:16]


def cache_path(name):
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "agent-session-control", "icons", f"{_KEY}-{name}")


@functools.lru_cache(maxsize=None)
def icon(name):
    """The PNG bytes of one of ICONS: from the cache when it holds a PNG there, else drawn and
    cached (a cache that cannot be written only costs the drawing)."""
    path = cache_path(name)
    f = live.open_regular(path)
    if f:
        with f:
            data = f.read(1 << 20)
        if data.startswith(PNG_SIG):
            return data
    n, glyph, rad, plate = ICONS[name]
    data = png(pixels(n, glyph, rad, plate), plate is None)
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        # a new file of ours only: never through a link, never one left by a run that crashed
        with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    except OSError:
        pass
    return data
