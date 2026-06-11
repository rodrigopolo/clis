"""
Equirectangular -> cube-face projection.

Ported from krpano.py's equirect_to_face(), which itself mirrors the
coordinate convention used by the WebGL CubeMapper (FACE_BASES) in
PanoUp/public/upload/webgl.js:

    +Z = front   +X = right   +Y = up
"""

import math

import numpy as np
from PIL import Image


def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face using bilinear interpolation.

    Args:
        img_np: (H, W, 3) uint8 source array
        face:   one of 'f', 'b', 'r', 'l', 'u', 'd'
        size:   output face side length in pixels

    Returns:
        PIL Image (RGB, size x size)
    """
    H, W = img_np.shape[:2]

    # UV grids: u from -1 (left) to +1 (right), v from +1 (top) to -1 (bottom)
    u = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    v = np.linspace(1.0, -1.0, size, dtype=np.float32)
    uu, vv = np.meshgrid(u, v)   # shape (size, size), float32
    del u, v

    # 3-D direction vectors for the requested face
    if face == 'f':    # Front  +Z: screen-right -> +X, screen-up -> +Y
        dx, dy, dz = uu, vv, np.ones((size, size), dtype=np.float32)
    elif face == 'b':  # Back   -Z: screen-right -> -X (flipped), screen-up -> +Y
        dx, dy, dz = -uu, vv, np.full((size, size), -1.0, dtype=np.float32)
    elif face == 'r':  # Right  +X: screen-right -> -Z (front = left edge), up -> +Y
        dx, dy, dz = np.ones((size, size), dtype=np.float32), vv, -uu
    elif face == 'l':  # Left   -X: screen-right -> +Z (front = right edge), up -> +Y
        dx, dy, dz = np.full((size, size), -1.0, dtype=np.float32), vv, uu
    elif face == 'u':  # Up     +Y: screen-right -> +X, screen-top -> -Z (back)
        dx, dy, dz = uu, np.ones((size, size), dtype=np.float32), -vv
    elif face == 'd':  # Down   -Y: screen-right -> +X, screen-top -> +Z (front)
        dx, dy, dz = uu, np.full((size, size), -1.0, dtype=np.float32), vv
    else:
        raise ValueError(f"Unknown face identifier: {face!r}")

    del uu, vv

    # Normalise to unit sphere
    norm = np.sqrt(dx * dx + dy * dy + dz * dz)
    dx /= norm
    dy /= norm
    dz /= norm
    del norm

    # Convert to spherical longitude / latitude
    lon = np.arctan2(dx, dz).astype(np.float32)          # in [-pi, pi]
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)  # in [-pi/2, pi/2]
    del dx, dy, dz

    # Map to source-image pixel coordinates
    pi32 = np.float32(math.pi)
    px = (lon / pi32 + np.float32(1.0)) * np.float32(0.5) * np.float32(W - 1)
    py = (np.float32(0.5) - lat / pi32) * np.float32(H - 1)
    del lon, lat

    # Bilinear interpolation
    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    wx = (px - x0.astype(np.float32))   # horizontal fractional weight
    wy = (py - y0.astype(np.float32))   # vertical fractional weight
    del px, py

    # Wrap x (equirectangular is horizontally periodic); clamp y
    x1 = (x0 + 1) % W
    y1 = np.clip(y0 + 1, 0, H - 1)
    x0 = x0 % W
    y0 = np.clip(y0, 0, H - 1)

    # Sample four neighbours (fancy indexing -> copies, float32 for arithmetic)
    c00 = img_np[y0, x0].astype(np.float32)
    c10 = img_np[y0, x1].astype(np.float32)
    c01 = img_np[y1, x0].astype(np.float32)
    c11 = img_np[y1, x1].astype(np.float32)
    del x0, x1, y0, y1

    # Expand weights to broadcast over RGB channels
    wx = wx[:, :, np.newaxis]
    wy = wy[:, :, np.newaxis]
    iwx = np.float32(1.0) - wx
    iwy = np.float32(1.0) - wy

    result = c00 * iwx * iwy + c10 * wx * iwy + c01 * iwx * wy + c11 * wx * wy
    del c00, c10, c01, c11, wx, wy, iwx, iwy

    return Image.fromarray(result.astype(np.uint8))
