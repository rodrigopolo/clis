#!/usr/bin/env python3
"""
marzipano.py — Generate Marzipano-compatible multires cube tiles from equirectangular panoramas.

Usage:
    python3 marzipano.py <equirectangular.jpg> [<image2.jpg> ...]

Output:
    {stem}/ directory next to each input image, containing:
      preview.jpg and face tile directories (l/ f/ r/ b/ u/ d/).
    JS snippet printed to stdout for inclusion in a Marzipano scene config.

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
TILE_SIZE       = 512                              # px; Marzipano standard tile size
PREVIEW_SIZE    = 256                              # preview face size in px
FACES           = ['f', 'b', 'l', 'r', 'u', 'd']  # Marzipano face order
PREVIEW_ORDER   = ['l', 'f', 'r', 'b', 'u', 'd']  # vertical strip order for preview
JPEG_QUALITY    = 90

# Marzipano candidate levels (must be multiples of TILE_SIZE)
CUBE_CANDIDATES = [16384, 8192, 4096, 2048, 1024, 512]


# ── Level-size computation ────────────────────────────────────────────────────

def round_to_closest_divisor(number: int, divisor: int) -> int:
    """Round *number* to the nearest multiple of *divisor*."""
    return ((number + divisor // 2) // divisor) * divisor


def compute_level_sizes(width: int) -> list[int]:
    """
    Return ascending list of cube-face sizes for each Marzipano multires level.

    Strategy:
      1. Derive the natural cube-face size: round(W / π).
      2. Snap that to the nearest 512.
      3. Include every candidate size (16384 → 512) that is ≤ that snapped cube size.

    Using W/π instead of W ensures the max level matches actual image detail,
    keeping RAM proportional to real content rather than raw pixel width.
    """
    raw_cube = round(width / math.pi)
    snapped  = round_to_closest_divisor(raw_cube, TILE_SIZE)
    sizes    = [s for s in CUBE_CANDIDATES if s <= snapped]
    if TILE_SIZE not in sizes:
        sizes.append(TILE_SIZE)
    return sorted(sizes)


# ── Equirectangular → cube-face projection ───────────────────────────────────

def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face using bilinear interpolation.

    Coordinate system (right-handed, standard convention):
        +Z = front   +X = right   +Y = up

    Args:
        img_np: (H, W, 3) uint8 source array
        face:   one of 'f', 'b', 'r', 'l', 'u', 'd'
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

    ones  = np.ones((size, size),  dtype=np.float32)
    minus = np.full((size, size), -1.0, dtype=np.float32)

    if face == 'f':    # Front  +Z
        dx, dy, dz = uu,    vv,    ones.copy()
    elif face == 'b':  # Back   -Z
        dx, dy, dz = -uu,   vv,    minus.copy()
    elif face == 'r':  # Right  +X
        dx, dy, dz = ones.copy(),  vv,    -uu
    elif face == 'l':  # Left   -X
        dx, dy, dz = minus.copy(), vv,    uu
    elif face == 'u':  # Up     +Y
        dx, dy, dz = uu,    ones.copy(),  -vv
    elif face == 'd':  # Down   -Y
        dx, dy, dz = uu,    minus.copy(), vv
    else:
        raise ValueError(f"Unknown face: {face!r}")

    del uu, vv, ones, minus

    # Normalise to unit sphere
    norm = np.sqrt(dx * dx + dy * dy + dz * dz)
    dx /= norm; dy /= norm; dz /= norm
    del norm

    # Spherical coordinates → source-image pixel coordinates
    lon = np.arctan2(dx, dz).astype(np.float32)
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)
    del dx, dy, dz

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

def save_tiles(face_img: Image.Image, face: str, level_idx: int,
               level_size: int, out_dir: str) -> None:
    """
    Resize face_img to level_size and write JPEG tiles.

    Marzipano tile naming convention (flat layout):
        {out_dir}/{level_idx}/{face}_{row}_{col}.jpg
    where row and col are 1-based integers.
    """
    if face_img.width != level_size:
        resized = face_img.resize((level_size, level_size), Image.LANCZOS)
    else:
        resized = face_img

    n_tiles = level_size // TILE_SIZE   # Marzipano levels are always multiples of TILE_SIZE

    level_dir = os.path.join(out_dir, str(level_idx))
    os.makedirs(level_dir, exist_ok=True)

    for row in range(1, n_tiles + 1):
        for col in range(1, n_tiles + 1):
            x0 = (col - 1) * TILE_SIZE
            y0 = (row - 1) * TILE_SIZE
            tile = resized.crop((x0, y0, x0 + TILE_SIZE, y0 + TILE_SIZE))
            tile.save(os.path.join(level_dir, f"{face}_{row}_{col}.jpg"),
                      "JPEG", quality=JPEG_QUALITY)


# ── JS snippet ────────────────────────────────────────────────────────────────

def build_js_snippet(stem: str, level_sizes: list[int]) -> str:
    """
    Return the Marzipano JS panorama config object for this image.

    The first (smallest) level is always emitted with fallbackOnly: true.
    All subsequent levels use the standard tileSize of 512.
    """
    lines = [
        f'var panorama = {{',
        f'\tprefix: "./panos/{stem}/",',
        f'\tdomid: "pano",',
        f'\ttiles: [',
    ]
    for i, size in enumerate(level_sizes):
        fallback = ', fallbackOnly: true' if i == 0 else ''
        lines.append(f'\t\t{{tileSize: {TILE_SIZE}, size: {size}{fallback}}},')
    lines += ['\t],', '}']
    return '\n'.join(lines)


# ── Main processing ───────────────────────────────────────────────────────────

def process_image(img_path: str) -> bool:
    img_path = os.path.abspath(img_path)
    stem     = os.path.splitext(os.path.basename(img_path))[0]
    out_dir  = os.path.join(os.path.dirname(img_path), stem)

    print(f"\nProcessing: {img_path}", file=sys.stderr)
    print(f"Output:     {out_dir}",   file=sys.stderr)

    # ── Load source ────────────────────────────────────────────────────────
    img  = Image.open(img_path).convert('RGB')
    W, H = img.size
    print(f"Source:     {W} × {H} px", file=sys.stderr)

    # ── Compute levels ─────────────────────────────────────────────────────
    level_sizes = compute_level_sizes(W)
    print(f"Levels:     {level_sizes}", file=sys.stderr)

    os.makedirs(out_dir, exist_ok=True)

    # ── Convert PIL image to numpy once ────────────────────────────────────
    img_np = np.array(img)
    img.close()
    del img

    # ── Per-face processing ────────────────────────────────────────────────
    max_size = level_sizes[-1]
    preview_thumbs: dict[str, Image.Image] = {}

    for face in FACES:
        print(f"  [{face}] projecting at {max_size} px … ", end='', flush=True, file=sys.stderr)
        face_img = equirect_to_face(img_np, face, max_size)
        print("done", file=sys.stderr)

        for li, size in enumerate(level_sizes, start=1):
            n_tiles = size // TILE_SIZE
            print(f"  [{face}] level {li} ({size} px, {n_tiles}×{n_tiles} tiles) … ",
                  end='', flush=True, file=sys.stderr)
            save_tiles(face_img, face, li, size, out_dir)
            print("done", file=sys.stderr)

        preview_thumbs[face] = face_img.resize((PREVIEW_SIZE, PREVIEW_SIZE), Image.LANCZOS)
        del face_img

    del img_np

    # ── preview.jpg: vertical strip, order l f r b u d ────────────────────
    print("  Generating preview.jpg … ", end='', flush=True, file=sys.stderr)
    preview = Image.new('RGB', (PREVIEW_SIZE, PREVIEW_SIZE * 6))
    for i, face in enumerate(PREVIEW_ORDER):
        preview.paste(preview_thumbs[face], (0, i * PREVIEW_SIZE))
    preview.save(os.path.join(out_dir, 'preview.jpg'), 'JPEG', quality=JPEG_QUALITY)
    print("done", file=sys.stderr)

    del preview_thumbs

    # ── JS snippet → stdout ────────────────────────────────────────────────
    print("--- JS snippet ---", file=sys.stderr)
    print(build_js_snippet(stem, level_sizes))
    print("-" * 17, file=sys.stderr)

    print(f"Done → {out_dir}\n", file=sys.stderr)
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='marzipano.py',
        description='Generate Marzipano multires cube tiles from equirectangular panoramas.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Output: {stem}/ directory next to each input image.\n'
            'Large panoramas (≥ 25 MP) may require 8–12 GB of free RAM.'
        ),
    )
    parser.add_argument('images', nargs='+', help='Path(s) to equirectangular JPEG/TIFF/PNG')
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