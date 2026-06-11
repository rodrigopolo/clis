"""
Cube-face render size per viewer.

Ported from PanoUp/public/upload/main.js (calcPannellumMarzipano, calcKrpano,
calcAvansel). Each formula derives the cube face side length ("maxCubeface")
from the equirectangular image width; the per-viewer Tiler then derives its
own tile-level breakdown from that face size.
"""

import math

FIXED_LIST = [512, 1024, 2048, 4096, 8192, 16384]


def js_round(x: float) -> int:
    """Match JavaScript's Math.round (half rounds toward +Infinity) for x >= 0."""
    return math.floor(x + 0.5)


def nearest_multiple(value: float, step: int) -> int:
    return js_round(value / step) * step


def calc_pannellum_marzipano(width: int) -> int:
    raw = js_round(width / math.pi)
    snapped = nearest_multiple(raw, 512)
    levels = [s for s in FIXED_LIST if s <= snapped]
    return levels[-1] if levels else FIXED_LIST[0]


def calc_krpano(width: int) -> int:
    return js_round(width / math.pi / 128) * 128


def calc_avansel(width: int) -> int:
    return js_round(width / math.pi)


def face_size(viewer: str, width: int) -> int:
    """Return the cube-face render size (px) for the given viewer and equirect width."""
    if viewer in ('pannellum', 'marzipano'):
        return calc_pannellum_marzipano(width)
    if viewer == 'krpano':
        return calc_krpano(width)
    if viewer == 'avansel':
        return calc_avansel(width)
    raise ValueError(f"Unknown viewer: {viewer!r}")
