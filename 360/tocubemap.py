#!/usr/bin/env python3
"""
tocubemap.py — Convert equirectangular panoramas to cube-face TIFFs.

For each input image the script produces six lossless TIFF files:
    {stem}_f.tif   front  (+Z)
    {stem}_b.tif   back   (-Z)
    {stem}_l.tif   left   (-X)
    {stem}_r.tif   right  (+X)
    {stem}_u.tif   up     (+Y)
    {stem}_d.tif   down   (-Y)

Output files are written next to the input image.

Usage:
    python3 tocubemap.py <panorama.jpg> [<panorama2.jpg> ...]

Dependencies: Pillow, numpy

Memory note: each face is generated independently to limit peak RAM.
A 25 MP panorama (25 000 × 12 500) produces ~8 GB of intermediate arrays
per face at maximum quality — close to what tilecreator.py requires.
"""

import sys
import math
import os
import argparse

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None   # allow very large panoramas

FACES = ['f', 'b', 'r', 'l', 'u', 'd']


# ── Projection ────────────────────────────────────────────────────────────────

def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face (bilinear interpolation).

    Coordinate system (right-handed, krpano convention):
        +Z = front   +X = right   +Y = up

    Args:
        img_np: (H, W, 3) uint8 source array
        face:   'f', 'b', 'r', 'l', 'u', or 'd'
        size:   output face side length in pixels

    Returns:
        PIL Image (RGB, size × size)
    """
    H, W = img_np.shape[:2]

    # UV grids: u ∈ [-1, +1] left→right, v ∈ [+1, -1] top→bottom
    u = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    v = np.linspace(1.0, -1.0, size, dtype=np.float32)
    uu, vv = np.meshgrid(u, v)
    del u, v

    # 3-D direction vectors per face
    if face == 'f':    # Front  +Z
        dx, dy, dz = uu, vv, np.ones((size, size), dtype=np.float32)
    elif face == 'b':  # Back   -Z
        dx, dy, dz = -uu, vv, np.full((size, size), -1.0, dtype=np.float32)
    elif face == 'r':  # Right  +X
        dx, dy, dz = np.ones((size, size), dtype=np.float32), vv, -uu
    elif face == 'l':  # Left   -X
        dx, dy, dz = np.full((size, size), -1.0, dtype=np.float32), vv, uu
    elif face == 'u':  # Up     +Y
        dx, dy, dz = uu, np.ones((size, size), dtype=np.float32), -vv
    elif face == 'd':  # Down   -Y
        dx, dy, dz = uu, np.full((size, size), -1.0, dtype=np.float32), vv
    else:
        raise ValueError(f"Unknown face: {face!r}")

    del uu, vv

    # Normalise
    norm = np.sqrt(dx * dx + dy * dy + dz * dz)
    dx /= norm; dy /= norm; dz /= norm
    del norm

    # Spherical coordinates
    lon = np.arctan2(dx, dz).astype(np.float32)                  # [-π, π]
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)   # [-π/2, π/2]
    del dx, dy, dz

    # Source pixel coordinates
    pi32 = np.float32(math.pi)
    px = (lon / pi32 + np.float32(1.0)) * np.float32(0.5) * np.float32(W - 1)
    py = (np.float32(0.5) - lat / pi32) * np.float32(H - 1)
    del lon, lat

    # Bilinear interpolation
    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    wx = (px - x0.astype(np.float32))
    wy = (py - y0.astype(np.float32))
    del px, py

    x1 = (x0 + 1) % W          # wrap horizontally
    y1 = np.clip(y0 + 1, 0, H - 1)
    x0 = x0 % W
    y0 = np.clip(y0, 0, H - 1)

    c00 = img_np[y0, x0].astype(np.float32)
    c10 = img_np[y0, x1].astype(np.float32)
    c01 = img_np[y1, x0].astype(np.float32)
    c11 = img_np[y1, x1].astype(np.float32)
    del x0, x1, y0, y1

    wx = wx[:, :, np.newaxis]
    wy = wy[:, :, np.newaxis]
    result = (c00 * (1.0 - wx) * (1.0 - wy)
              + c10 * wx * (1.0 - wy)
              + c01 * (1.0 - wx) * wy
              + c11 * wx * wy)
    del c00, c10, c01, c11, wx, wy

    return Image.fromarray(result.astype(np.uint8))


# ── Main processing ───────────────────────────────────────────────────────────

def process_image(img_path: str) -> bool:
    img_path = os.path.abspath(img_path)
    stem = os.path.splitext(os.path.basename(img_path))[0]
    out_dir = os.path.dirname(img_path)

    print(f"\nProcessing: {img_path}")

    img = Image.open(img_path).convert('RGB')
    W, H = img.size
    face_size = round(W / math.pi)
    print(f"Source:     {W} × {H} px")
    print(f"Face size:  {face_size} × {face_size} px")

    img_np = np.array(img)
    img.close()
    del img

    for face in FACES:
        out_path = os.path.join(out_dir, f"{stem}_{face}.tif")
        print(f"  [{face}] → {os.path.basename(out_path)} … ", end='', flush=True)
        face_img = equirect_to_face(img_np, face, face_size)
        face_img.save(out_path, format='TIFF')
        del face_img
        print("done")

    del img_np
    print(f"Done: {stem}_{{f,b,l,r,u,d}}.tif\n")
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='tocubemap.py',
        description='Convert equirectangular panoramas to six cube-face TIFFs.',
        epilog='Output files are written next to each input image.',
    )
    parser.add_argument('images', nargs='+', help='Equirectangular image path(s)')
    args = parser.parse_args()

    failed = 0
    for path in args.images:
        if not os.path.isfile(path):
            print(f"ERROR: file not found: {path}", file=sys.stderr)
            failed += 1
            continue
        try:
            if not process_image(path):
                failed += 1
        except Exception as exc:
            print(f"ERROR processing {path}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            failed += 1

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
