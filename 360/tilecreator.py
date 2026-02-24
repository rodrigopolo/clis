#!/usr/bin/env python3
"""
tilecreator.py — Generate krpano-compatible multires cube tiles from equirectangular panoramas.

Usage:
    python3 tilecreator.py <equirectangular.jpg> [<image2.jpg> ...]

Output:
    {stem}.tiles/ directory next to each input image, containing:
      preview.jpg, thumb.jpg, and f/b/l/r/u/d tile directories.

Dependencies: Pillow, numpy (both standard in scientific Python environments)

Memory note: Processing a 25 MP panorama (25000×12500) at maximum quality
requires approximately 6–10 GB of RAM. Smaller panoramas need proportionally less.
"""

import sys
import math
import os
import argparse
import json
import shutil
import subprocess

import numpy as np
from PIL import Image

# Disable PIL's decompression bomb guard so large panoramas can be opened
Image.MAX_IMAGE_PIXELS = None

# ── Constants ────────────────────────────────────────────────────────────────
TILE_SIZE = 512                              # px; also the first value in multires attr
FACES = ['f', 'b', 'r', 'l', 'u', 'd']
PREVIEW_FACE_ORDER = ['l', 'f', 'r', 'b', 'u', 'd']  # krpano cube-strip order
PREVIEW_FACE_SIZE = 256                      # each face in preview.jpg
JPEG_QUALITY = 90


# ── Level-size computation ────────────────────────────────────────────────────

def compute_level_sizes(width: int) -> list[int]:
    """
    Return ascending list of cube-face sizes for each multires level.

    Matches the level-generation behaviour of the krpano tool exactly:

    1. Max level  = round(width / π / 128) × 128
       (cube face size, rounded to the nearest 128)

    2. Each smaller level halves the previous one and floors to the nearest 128:
           next = (current // 256) × 128

    3. A level is included only when its size > TILE_SIZE (512 px).

    This naturally produces non-power-of-two sizes for cube faces that are not
    a multiple of 1024.  Example for a 20906 px wide panorama:
        cubeface ≈ 6656  →  levels: 768, 1664, 3328, 6656
    """
    max_level = round(width / math.pi / 128) * 128
    levels = []
    current = max_level
    while current > TILE_SIZE:
        levels.append(current)
        current = (current // 256) * 128   # halve, then floor to nearest 128
    return sorted(levels)


# ── Equirectangular → cube-face projection ───────────────────────────────────

def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face using bilinear interpolation.

    Coordinate system (right-handed, krpano convention):
        +Z = front   +X = right   +Y = up

    Args:
        img_np: (H, W, 3) uint8 source array
        face:   one of 'f', 'b', 'r', 'l', 'u', 'd'
        size:   output face side length in pixels

    Returns:
        PIL Image (RGB, size × size)
    """
    H, W = img_np.shape[:2]

    # UV grids: u from -1 (left) to +1 (right), v from +1 (top) to -1 (bottom)
    u = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    v = np.linspace(1.0, -1.0, size, dtype=np.float32)
    uu, vv = np.meshgrid(u, v)   # shape (size, size), float32
    del u, v

    # 3-D direction vectors for the requested face
    # (Unary minus on an ndarray creates a new array, so uu/vv may be aliased
    #  into dx/dy/dz but that is safe — we del them all before normalization.)
    if face == 'f':    # Front  +Z: screen-right → +X, screen-up → +Y
        dx, dy, dz = uu, vv, np.ones((size, size), dtype=np.float32)
    elif face == 'b':  # Back   -Z: screen-right → -X (flipped), screen-up → +Y
        dx, dy, dz = -uu, vv, np.full((size, size), -1.0, dtype=np.float32)
    elif face == 'r':  # Right  +X: screen-right → -Z (front = left edge), up → +Y
        dx, dy, dz = np.ones((size, size), dtype=np.float32), vv, -uu
    elif face == 'l':  # Left   -X: screen-right → +Z (front = right edge), up → +Y
        dx, dy, dz = np.full((size, size), -1.0, dtype=np.float32), vv, uu
    elif face == 'u':  # Up     +Y: screen-right → +X, screen-top → -Z (back)
        dx, dy, dz = uu, np.ones((size, size), dtype=np.float32), -vv
    elif face == 'd':  # Down   -Y: screen-right → +X, screen-top → +Z (front)
        dx, dy, dz = uu, np.full((size, size), -1.0, dtype=np.float32), vv
    else:
        raise ValueError(f"Unknown face identifier: {face!r}")

    del uu, vv  # free original grids (data lives on via dx/dy/dz if aliased)

    # Normalise to unit sphere
    norm = np.sqrt(dx * dx + dy * dy + dz * dz)
    dx /= norm
    dy /= norm
    dz /= norm
    del norm

    # Convert to spherical longitude / latitude
    lon = np.arctan2(dx, dz).astype(np.float32)          # ∈ [-π, π]
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)  # ∈ [-π/2, π/2]
    del dx, dy, dz

    # Map to source-image pixel coordinates
    pi32 = np.float32(math.pi)
    px = (lon / pi32 + np.float32(1.0)) * np.float32(0.5) * np.float32(W - 1)
    py = (np.float32(0.5) - lat / pi32) * np.float32(H - 1)
    del lon, lat

    # Bilinear interpolation ─────────────────────────────────────────────────
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

    # Sample four neighbours (fancy indexing → copies, float32 for arithmetic)
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


# ── Tile saving ───────────────────────────────────────────────────────────────

def save_tiles(face_img: Image.Image, face: str, level_idx: int,
               level_size: int, out_dir: str) -> None:
    """Resize face_img to level_size and write 512×512 JPEG tiles."""
    if face_img.width != level_size:
        resized = face_img.resize((level_size, level_size), Image.LANCZOS)
    else:
        resized = face_img

    n = level_size // TILE_SIZE   # tiles per row / column
    for row in range(n):
        row_dir = os.path.join(out_dir, face, f"l{level_idx}", f"{row + 1:02d}")
        os.makedirs(row_dir, exist_ok=True)
        for col in range(n):
            tile = resized.crop((col * TILE_SIZE, row * TILE_SIZE,
                                 (col + 1) * TILE_SIZE, (row + 1) * TILE_SIZE))
            fname = f"l{level_idx}_{face}_{row + 1:02d}_{col + 1:02d}.jpg"
            tile.save(os.path.join(row_dir, fname), "JPEG", quality=JPEG_QUALITY)


# ── GPS extraction ────────────────────────────────────────────────────────────

def get_gps_coordinates(image_path: str) -> tuple[str, str, str]:
    """
    Extract GPS lat, lng, alt from EXIF. Returns formatted strings or "" if absent.
    Primary: Pillow GPS IFD. Fallback: exiftool subprocess.
    """
    lat_str, lng_str, alt_str = "", "", ""

    # ── Primary: Pillow EXIF GPS IFD (tag 34853 = 0x8825) ────────────────
    try:
        with Image.open(image_path) as _img:
            gps_ifd = _img.getexif().get_ifd(34853)

        if gps_ifd:
            def _dms_to_decimal(dms_tuple) -> float:
                d, m, s = (float(v) for v in dms_tuple)
                return d + m / 60.0 + s / 3600.0

            lat_dms = gps_ifd.get(2)   # GPSLatitude
            lat_ref = gps_ifd.get(1)   # GPSLatitudeRef  ('N'/'S')
            lng_dms = gps_ifd.get(4)   # GPSLongitude
            lng_ref = gps_ifd.get(3)   # GPSLongitudeRef ('E'/'W')
            alt_val = gps_ifd.get(6)   # GPSAltitude
            alt_ref = gps_ifd.get(5)   # GPSAltitudeRef  (0=above, 1=below)

            if lat_dms and lat_ref and lng_dms and lng_ref:
                lat = _dms_to_decimal(lat_dms)
                lng = _dms_to_decimal(lng_dms)
                if str(lat_ref).upper().strip() == 'S':
                    lat = -lat
                if str(lng_ref).upper().strip() == 'W':
                    lng = -lng
                lat_str = f"{lat:.8f}"
                lng_str = f"{lng:.8f}"

            if alt_val is not None:
                alt = float(alt_val)
                if alt_ref and int(alt_ref) == 1:
                    alt = -alt
                alt_str = f"{alt:.2f}"

    except Exception:
        pass  # malformed EXIF or unsupported format — fall through

    if lat_str and lng_str:
        return lat_str, lng_str, alt_str

    # ── Fallback: exiftool ─────────────────────────────────────────────────
    exiftool_bin = shutil.which("exiftool")
    if exiftool_bin:
        try:
            result = subprocess.run(
                [exiftool_bin, "-j", "-n", image_path],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode == 0 and result.stdout.strip():
                data = json.loads(result.stdout)
                if data:
                    rec = data[0]
                    et_lat = rec.get("GPSLatitude")
                    et_lng = rec.get("GPSLongitude")
                    et_alt = rec.get("GPSAltitude")
                    if et_lat is not None and et_lng is not None:
                        lat_str = f"{float(et_lat):.8f}"
                        lng_str = f"{float(et_lng):.8f}"
                    if et_alt is not None:
                        alt_str = f"{float(et_alt):.2f}"
        except Exception:
            pass  # exiftool failed or timed out

    # ── Warning if still empty ─────────────────────────────────────────────
    if not lat_str or not lng_str:
        print(f"Warning: No GPS data found for {os.path.basename(image_path)}",
              file=sys.stderr)

    return lat_str, lng_str, alt_str


# ── Main processing ───────────────────────────────────────────────────────────

def process_image(img_path: str) -> bool:
    img_path = os.path.abspath(img_path)
    stem = os.path.splitext(os.path.basename(img_path))[0]
    out_dir = os.path.join(os.path.dirname(img_path), f"{stem}.tiles")

    print(f"\nProcessing: {img_path}")
    print(f"Output:     {out_dir}")

    # ── Load source ────────────────────────────────────────────────────────
    img = Image.open(img_path).convert('RGB')
    W, H = img.size
    print(f"Source:     {W} × {H} px")

    # ── Compute levels ─────────────────────────────────────────────────────
    level_sizes = compute_level_sizes(W)
    if not level_sizes:
        print("ERROR: image is too small to generate tiles "
              "(need equirectangular width ≥ ~2011 px).", file=sys.stderr)
        return False

    max_size = level_sizes[-1]
    print(f"Cube face:  {W / math.pi:.0f} px  →  max level {max_size} px")
    print(f"Levels:     {level_sizes}")

    os.makedirs(out_dir, exist_ok=True)

    # ── Convert PIL image to numpy (keep a single copy in memory) ──────────
    img_np = np.array(img)
    img.close()
    del img

    # ── Per-face processing ────────────────────────────────────────────────
    preview_thumbs: dict[str, Image.Image] = {}  # 256×256 per face for preview

    for face in FACES:
        print(f"  [{face}] projecting at {max_size} px … ", end='', flush=True)
        face_img = equirect_to_face(img_np, face, max_size)
        print("done")

        for li, size in enumerate(level_sizes, start=1):
            n = size // TILE_SIZE
            print(f"  [{face}] l{li} ({size} px, {n}×{n} tiles) … ", end='', flush=True)
            save_tiles(face_img, face, li, size, out_dir)
            print("done")

        # Keep a 256×256 thumbnail for preview.jpg
        preview_thumbs[face] = face_img.resize(
            (PREVIEW_FACE_SIZE, PREVIEW_FACE_SIZE), Image.LANCZOS)
        del face_img

    del img_np

    # ── preview.jpg: 256×1536 vertical strip, order l f r b u d ───────────
    print("  Generating preview.jpg … ", end='', flush=True)
    preview = Image.new('RGB', (PREVIEW_FACE_SIZE, PREVIEW_FACE_SIZE * 6))
    for i, face in enumerate(PREVIEW_FACE_ORDER):
        preview.paste(preview_thumbs[face], (0, i * PREVIEW_FACE_SIZE))
    preview.save(os.path.join(out_dir, 'preview.jpg'), 'JPEG', quality=JPEG_QUALITY)
    print("done")

    # ── thumb.jpg: 240×240, front face ─────────────────────────────────────
    print("  Generating thumb.jpg … ", end='', flush=True)
    thumb = preview_thumbs['f'].resize((240, 240), Image.LANCZOS)
    thumb.save(os.path.join(out_dir, 'thumb.jpg'), 'JPEG', quality=JPEG_QUALITY)
    print("done")

    del preview_thumbs

    # ── Extract GPS coordinates ─────────────────────────────────────────────
    lat, lng, alt = get_gps_coordinates(img_path)

    # ── XML snippet ─────────────────────────────────────────────────────────
    multires = f"512,{','.join(str(s) for s in level_sizes)}"
    scene_name = f"scene_{stem.lower().replace(' ', '_').replace('-', '_')}"
    print(f"""
--- XML snippet (paste into tour.xml) ---
<scene name="{scene_name}" title="{stem}" onstart="" thumburl="panos/{stem}.tiles/thumb.jpg" lat="{lat}" lng="{lng}" alt="{alt}" heading="0.0">
\t<control bouncinglimits="calc:image.cube ? true : false" />
\t<view hlookat="0.0" vlookat="0.0" fovtype="MFOV" fov="120" maxpixelzoom="2.0" fovmin="70" fovmax="140" limitview="auto" />
\t<preview url="panos/{stem}.tiles/preview.jpg" />
\t<image>
\t\t<cube url="panos/{stem}.tiles/%s/l%l/%0v/l%l_%s_%0v_%0h.jpg" multires="{multires}" />
\t</image>
</scene>
-----------------------------------------""")

    print(f"Done → {out_dir}\n")
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='tilecreator.py',
        description='Generate krpano multires cube tiles from equirectangular panoramas.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Output: {stem}.tiles/ directory next to each input image.\n'
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
