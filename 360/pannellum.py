#!/usr/bin/env python3
"""
pannellum.py — Generate Pannellum-compatible multires cube tiles from equirectangular panoramas.

Usage:
    python3 pannellum.py <equirectangular.jpg> [<image2.jpg> ...]

Output:
    {stem}/ directory next to each input image, containing level subdirectories
    with tiles named {side}_{row}_{col}.jpg (0-indexed), plus a JS config snippet
    printed to stdout.

    Directory structure:
        {stem}/
            1/          ← smallest level
                f_0_0.jpg
                b_0_0.jpg
                …
            2/
                f_0_0.jpg  f_0_1.jpg
                …
            N/          ← largest level

    JS snippet (printed to stdout):
        var panorama = {
            "autoLoad": true,
            "type": "multires",
            "preview": "./panos/{stem}/1/f_0_0.jpg",
            …
        }

Dependencies: Pillow, numpy

Memory note: Processing a 25 MP panorama (25000×12500) at maximum quality
requires approximately 6–10 GB of RAM. Smaller panoramas need proportionally less.
"""

import sys
import math
import os
import argparse

import numpy as np
from PIL import Image

# Disable PIL's decompression bomb guard so large panoramas can be opened
Image.MAX_IMAGE_PIXELS = None

# ── Constants ─────────────────────────────────────────────────────────────────
TILE_SIZE   = 512
FACES       = ['f', 'b', 'l', 'r', 'u', 'd']   # Pannellum face order
JPEG_QUALITY = 90

# Pannellum multires levels are built from powers of TILE_SIZE.
# The bash script used these fixed breakpoints:
CUBE_LEVELS = [16384, 8192, 4096, 2048, 1024, 512]


# ── Level-size computation ────────────────────────────────────────────────────

def round_to_closest_divisor(number: int, divisor: int) -> int:
    """Round *number* to the nearest multiple of *divisor*."""
    return ((number + divisor // 2) // divisor) * divisor


def compute_level_sizes(cube_size: int) -> list[int]:
    """
    Return an ascending list of cube-face sizes for each Pannellum multires level.

    Mirrors the bash script logic: snap the raw cube size to the nearest 512,
    then include every entry from CUBE_LEVELS that is ≤ that snapped size.
    The result is sorted ascending (smallest first = level 1).
    """
    snapped = round_to_closest_divisor(cube_size, TILE_SIZE)
    selected = [s for s in CUBE_LEVELS if snapped >= s]
    return sorted(selected)   # ascending: level 1 is smallest


# ── Equirectangular → cube-face projection ───────────────────────────────────

def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face using bilinear interpolation.

    Coordinate system (right-handed):
        +Z = front   +X = right   +Y = up

    Args:
        img_np: (H, W, 3) uint8 source array
        face:   one of 'f', 'b', 'r', 'l', 'u', 'd'
        size:   output face side length in pixels

    Returns:
        PIL Image (RGB, size × size)
    """
    H, W = img_np.shape[:2]

    # UV grids: u ∈ [-1, +1] (left→right), v ∈ [+1, -1] (top→bottom)
    u = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    v = np.linspace(1.0, -1.0, size, dtype=np.float32)
    uu, vv = np.meshgrid(u, v)
    del u, v

    # 3-D direction vectors per face
    if face == 'f':
        dx, dy, dz = uu, vv, np.ones((size, size), dtype=np.float32)
    elif face == 'b':
        dx, dy, dz = -uu, vv, np.full((size, size), -1.0, dtype=np.float32)
    elif face == 'r':
        dx, dy, dz = np.ones((size, size), dtype=np.float32), vv, -uu
    elif face == 'l':
        dx, dy, dz = np.full((size, size), -1.0, dtype=np.float32), vv, uu
    elif face == 'u':
        dx, dy, dz = uu, np.ones((size, size), dtype=np.float32), -vv
    elif face == 'd':
        dx, dy, dz = uu, np.full((size, size), -1.0, dtype=np.float32), vv
    else:
        raise ValueError(f"Unknown face identifier: {face!r}")

    del uu, vv

    # Normalise to unit sphere
    norm = np.sqrt(dx * dx + dy * dy + dz * dz)
    dx /= norm; dy /= norm; dz /= norm
    del norm

    # Spherical coordinates → source pixel coordinates
    pi32 = np.float32(math.pi)
    lon = np.arctan2(dx, dz).astype(np.float32)
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)
    del dx, dy, dz

    px = (lon / pi32 + np.float32(1.0)) * np.float32(0.5) * np.float32(W - 1)
    py = (np.float32(0.5) - lat / pi32) * np.float32(H - 1)
    del lon, lat

    # Bilinear interpolation
    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    wx = (px - x0.astype(np.float32))
    wy = (py - y0.astype(np.float32))
    del px, py

    x1 = (x0 + 1) % W
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
    iwx = np.float32(1.0) - wx
    iwy = np.float32(1.0) - wy

    result = c00 * iwx * iwy + c10 * wx * iwy + c01 * iwx * wy + c11 * wx * wy
    del c00, c10, c01, c11, wx, wy, iwx, iwy

    return Image.fromarray(result.astype(np.uint8))


# ── Tile saving ───────────────────────────────────────────────────────────────

def save_tiles(face_img: Image.Image, face: str, level_size: int,
               level_dir: str) -> None:
    """
    Resize *face_img* to *level_size* and write 512×512 JPEG tiles into *level_dir*.

    Pannellum tile naming convention (0-indexed row and column):
        {face}_{row}_{col}.jpg   e.g.  f_0_0.jpg, f_0_1.jpg, f_1_0.jpg …

    All tiles are exactly TILE_SIZE × TILE_SIZE; Pannellum requires that the cube
    face size be an exact multiple of the tile size (which is guaranteed by how
    CUBE_LEVELS is defined).
    """
    if face_img.width != level_size:
        resized = face_img.resize((level_size, level_size), Image.LANCZOS)
    else:
        resized = face_img

    os.makedirs(level_dir, exist_ok=True)

    n_tiles = level_size // TILE_SIZE   # tiles per axis (always exact)
    for row in range(n_tiles):
        y0 = row * TILE_SIZE
        for col in range(n_tiles):
            x0 = col * TILE_SIZE
            tile = resized.crop((x0, y0, x0 + TILE_SIZE, y0 + TILE_SIZE))
            fname = f"{face}_{row}_{col}.jpg"
            tile.save(os.path.join(level_dir, fname), "JPEG", quality=JPEG_QUALITY)


# ── Main processing ───────────────────────────────────────────────────────────

def process_image(img_path: str) -> bool:
    img_path = os.path.abspath(img_path)
    stem     = os.path.splitext(os.path.basename(img_path))[0]
    out_dir  = os.path.join(os.path.dirname(img_path), stem)

    print(f"\nProcessing: {img_path}", file=sys.stderr)
    print(f"Output:     {out_dir}",   file=sys.stderr)

    # ── Load source ────────────────────────────────────────────────────────
    img = Image.open(img_path).convert('RGB')
    W, H = img.size
    print(f"Source:     {W} × {H} px", file=sys.stderr)

    # ── Derive cube size and levels ────────────────────────────────────────
    # A 2:1 equirectangular maps to a cube face of roughly W/π pixels.
    raw_cube = round(W / math.pi)
    level_sizes = compute_level_sizes(raw_cube)

    if not level_sizes:
        print("ERROR: image is too small to generate any Pannellum level "
              "(equirectangular width must be ≥ ~1608 px).", file=sys.stderr)
        return False

    max_cube  = level_sizes[-1]   # largest level = cubeResolution for Pannellum
    max_level = len(level_sizes)  # level count

    print(f"Cube face:  {raw_cube} px  →  using {max_cube} px (max level)", file=sys.stderr)
    print(f"Levels:     {level_sizes}", file=sys.stderr)

    os.makedirs(out_dir, exist_ok=True)

    # ── Convert PIL image to numpy (single copy in memory) ─────────────────
    img_np = np.array(img)
    img.close()
    del img

    # ── Per-face processing ────────────────────────────────────────────────
    for face in FACES:
        print(f"  [{face}] projecting at {max_cube} px … ",
              end='', flush=True, file=sys.stderr)
        face_img = equirect_to_face(img_np, face, max_cube)
        print("done", file=sys.stderr)

        for level_idx, size in enumerate(level_sizes, start=1):
            n_tiles = size // TILE_SIZE
            print(f"  [{face}] level {level_idx} ({size} px, {n_tiles}×{n_tiles} tiles) … ",
                  end='', flush=True, file=sys.stderr)
            level_dir = os.path.join(out_dir, str(level_idx))
            save_tiles(face_img, face, size, level_dir)
            print("done", file=sys.stderr)

        del face_img

    del img_np

    # ── JS config snippet (stdout) ─────────────────────────────────────────
    print(f"--- JS snippet ---", file=sys.stderr)
    print(f'var panorama = {{')
    print(f'\t"autoLoad": true,')
    print(f'\t"type": "multires",')
    print(f'\t"preview": "./panos/{stem}/1/f_0_0.jpg",')
    print(f'\t"minHfov": 10,')
    print(f'\t"maxHfov": 140,')
    print(f'\t"hfov": 90,')
    print(f'\t"multiResMinHfov": true,')
    print(f'\t"multiRes": {{')
    print(f'\t\t"basePath": "./panos/{stem}/",')
    print(f'\t\t"path": "/%l/%s_%y_%x",')
    print(f'\t\t"fallbackPath": "/fallback/%s",')
    print(f'\t\t"extension": "jpg",')
    print(f'\t\t"tileResolution": {TILE_SIZE},')
    print(f'\t\t"maxLevel": {max_level},')
    print(f'\t\t"cubeResolution": {max_cube}')
    print(f'\t}},')
    print(f'\tdomid: "pano"')
    print(f'}}')
    print(f"------------------", file=sys.stderr)

    print(f"Done → {out_dir}\n", file=sys.stderr)
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='pannellum.py',
        description='Generate Pannellum multires cube tiles from equirectangular panoramas.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Output: {stem}/ directory next to each input image.\n'
            'Large panoramas (≥ 25 MP) may require 8–12 GB of free RAM.'
        ),
    )
    parser.add_argument('images', nargs='+', help='Path(s) to equirectangular JPEG/TIFF')
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