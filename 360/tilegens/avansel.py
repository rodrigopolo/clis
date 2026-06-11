#!/usr/bin/env python3
"""
avansel.py — Generate Avansel-compatible multires cube tiles
                         from equirectangular panoramas.

Usage:
    python3 avansel.py <equirectangular.jpg> [<image2.jpg> ...]

Output:
    {stem}/ directory next to each input image, containing:
      - preview.jpg  (256×256 front-face thumbnail)
      - {level}/     one directory per level, 1-indexed, smallest→largest
          {face}_{row}_{col}.jpg   (e.g. f_0_0.jpg, f_1_2.jpg)

    Directory layout (matches Avansel.sh bash reference):
      Dir 1  → fallback level (single tile per face, small resolution)
      Dir 2  → smallest tiled level
      …
      Dir N  → largest tiled level (highest detail)

    Avansel receives l=0 for fallback, l=1 for the first tiled level, etc.
    The standard parseInt(l)+1 in the JS callback maps these to the
    1-indexed directory names on disk.

Filename convention (from Avansel.sh reference):
    {level}/{face}_{row}_{col}.jpg
    face in {l,f,r,b,u,d}, row/col 0-indexed, no zero-padding.

JS callback:  (s, l, x, y) => `.../${parseInt(l)+1}/${s}_${y}_${x}.jpg`

Dependencies: Pillow, numpy

Memory note: A 25 MP panorama (25000x12500) requires ~6-10 GB of RAM.
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

Image.MAX_IMAGE_PIXELS = None   # allow very large panoramas

# -- Constants -----------------------------------------------------------------
TILE_SIZE    = 512
FACES        = ['l', 'f', 'r', 'b', 'u', 'd']   # matches Avansel.sh sides_short order
JPEG_QUALITY = 90
PREVIEW_SIZE = 256   # front-face preview thumbnail


# -- Level-size computation ----------------------------------------------------

def compute_level_sizes(width: int, fallback_size: int = 0) -> tuple[int, list[int]]:
    """
    Return (fallback_size, [tiled_level_sizes]) for an equirectangular of the
    given pixel width.

    Strategy:
      - max cube-face size  = round(width / pi)
      - tiled levels: halve from max until size <= TILE_SIZE; sorted ascending
      - fallback: smallest tiled level halved once more, capped at TILE_SIZE
    """
    max_face = round(width / math.pi)

    tiled: list[int] = []
    s = max_face
    while s > TILE_SIZE:
        tiled.append(s)
        s = (s + 1) // 2

    tiled.sort()   # ascending: smallest to largest

    if not fallback_size:
        base = tiled[0] if tiled else max_face
        fallback_size = min((base + 1) // 2, TILE_SIZE)

    return fallback_size, tiled


def build_params(fallback_size: int, tiled_sizes: list[int]) -> list[dict]:
    """
    Build the Avansel params array.
    Index 0 = fallback (l=0 in callback -> dir 1 on disk).
    Index 1..N = tiled levels ascending (l=1..N in callback -> dirs 2..N+1).
    """
    params = [{"tileSize": fallback_size, "size": fallback_size, "fallback": True}]
    for s in tiled_sizes:
        params.append({"tileSize": TILE_SIZE, "size": s})
    return params


# -- Equirectangular -> cube-face projection ------------------------------------

def equirect_to_face(img_np: np.ndarray, face: str, size: int) -> Image.Image:
    """
    Project an equirectangular image onto one cube face (bilinear interpolation).

    Standard right-handed coordinate system (same as tocubemap.py / nona):
        +Z = front   +X = right   +Y = up

    Face directions:
        f  -> looks toward +Z, screen-right = +X
        b  -> looks toward -Z, screen-right = -X
        r  -> looks toward +X, screen-right = -Z
        l  -> looks toward -X, screen-right = +Z
        u  -> looks toward +Y, screen-right = +X, screen-up = -Z
        d  -> looks toward -Y, screen-right = +X, screen-up = +Z
    """
    H, W = img_np.shape[:2]

    u = np.linspace(-1.0, 1.0, size, dtype=np.float32)
    v = np.linspace(1.0, -1.0, size, dtype=np.float32)
    uu, vv = np.meshgrid(u, v)
    del u, v

    if   face == 'f':
        dx, dy, dz = uu,  vv,  np.ones ((size, size), dtype=np.float32)
    elif face == 'b':
        dx, dy, dz = -uu, vv,  np.full ((size, size), -1.0, dtype=np.float32)
    elif face == 'r':
        dx, dy, dz = np.ones ((size, size), dtype=np.float32), vv, -uu
    elif face == 'l':
        dx, dy, dz = np.full ((size, size), -1.0, dtype=np.float32), vv,  uu
    elif face == 'u':
        dx, dy, dz = uu,  np.ones ((size, size), dtype=np.float32), -vv
    elif face == 'd':
        dx, dy, dz = uu,  np.full ((size, size), -1.0, dtype=np.float32), vv
    else:
        raise ValueError(f"Unknown face: {face!r}")

    del uu, vv

    norm = np.sqrt(dx*dx + dy*dy + dz*dz)
    dx /= norm;  dy /= norm;  dz /= norm
    del norm

    pi32 = np.float32(math.pi)
    lon = np.arctan2(dx, dz).astype(np.float32)
    lat = np.arcsin(np.clip(dy, -1.0, 1.0)).astype(np.float32)
    del dx, dy, dz

    px = (lon / pi32 + np.float32(1.0)) * np.float32(0.5) * np.float32(W - 1)
    py = (np.float32(0.5) - lat / pi32) * np.float32(H - 1)
    del lon, lat

    x0 = np.floor(px).astype(np.int32)
    y0 = np.floor(py).astype(np.int32)
    wx = px - x0.astype(np.float32)
    wy = py - y0.astype(np.float32)
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

    wx = wx[:, :, np.newaxis];  wy = wy[:, :, np.newaxis]
    iwx = np.float32(1.0) - wx;  iwy = np.float32(1.0) - wy

    result = c00*iwx*iwy + c10*wx*iwy + c01*iwx*wy + c11*wx*wy
    del c00, c10, c01, c11, wx, wy, iwx, iwy

    return Image.fromarray(result.astype(np.uint8))


# -- Tile saving ---------------------------------------------------------------

def save_level_tiles(face_img: Image.Image, face: str,
                     dir_idx: int, level_size: int,
                     tile_size: int, out_dir: str) -> None:
    """
    Resize face_img to level_size x level_size and write JPEG tiles.

    Output path: {out_dir}/{dir_idx}/{face}_{row}_{col}.jpg
    Matches Avansel.sh naming: mv "${mosaic}${item}.jpg" "${mosaic}_${row}_${col}.jpg"
    dir_idx is 1-based (dir 1 = fallback, dir 2+ = tiled levels ascending).
    row and col are 0-indexed, no zero-padding.
    """
    if face_img.width != level_size:
        resized = face_img.resize((level_size, level_size), Image.LANCZOS)
    else:
        resized = face_img

    level_dir = os.path.join(out_dir, str(dir_idx))
    os.makedirs(level_dir, exist_ok=True)

    n_full  = level_size // tile_size
    n_total = n_full + (1 if level_size % tile_size else 0)

    for row in range(n_total):
        y0 = row * tile_size
        y1 = min(y0 + tile_size, level_size)
        for col in range(n_total):
            x0 = col * tile_size
            x1 = min(x0 + tile_size, level_size)
            tile  = resized.crop((x0, y0, x1, y1))
            fname = f"{face}_{row}_{col}.jpg"   # e.g. f_0_0.jpg, l_1_2.jpg
            tile.save(os.path.join(level_dir, fname), "JPEG", quality=JPEG_QUALITY)


# -- GPS extraction ------------------------------------------------------------

def get_gps_coordinates(image_path: str) -> tuple[str, str, str]:
    lat_str, lng_str, alt_str = "", "", ""

    try:
        with Image.open(image_path) as _img:
            gps_ifd = _img.getexif().get_ifd(34853)

        if gps_ifd:
            def _dms(dms_tuple) -> float:
                d, m, s = (float(v) for v in dms_tuple)
                return d + m / 60.0 + s / 3600.0

            lat_dms = gps_ifd.get(2);  lat_ref = gps_ifd.get(1)
            lng_dms = gps_ifd.get(4);  lng_ref = gps_ifd.get(3)
            alt_val = gps_ifd.get(6);  alt_ref = gps_ifd.get(5)

            if lat_dms and lat_ref and lng_dms and lng_ref:
                lat = _dms(lat_dms);  lng = _dms(lng_dms)
                if str(lat_ref).upper().strip() == 'S': lat = -lat
                if str(lng_ref).upper().strip() == 'W': lng = -lng
                lat_str = f"{lat:.8f}";  lng_str = f"{lng:.8f}"

            if alt_val is not None:
                alt = float(alt_val)
                if alt_ref and int(alt_ref) == 1: alt = -alt
                alt_str = f"{alt:.2f}"
    except Exception:
        pass

    if lat_str and lng_str:
        return lat_str, lng_str, alt_str

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
                    et_lat = rec.get("GPSLatitude");  et_lng = rec.get("GPSLongitude")
                    et_alt = rec.get("GPSAltitude")
                    if et_lat is not None and et_lng is not None:
                        lat_str = f"{float(et_lat):.8f}"
                        lng_str = f"{float(et_lng):.8f}"
                    if et_alt is not None:
                        alt_str = f"{float(et_alt):.2f}"
        except Exception:
            pass

    if not lat_str or not lng_str:
        print(f"Warning: No GPS data found for {os.path.basename(image_path)}",
              file=sys.stderr)

    return lat_str, lng_str, alt_str


# -- JS snippet generation -----------------------------------------------------

def js_params_str(params: list[dict]) -> str:
    lines = ["const params = ["]
    for p in params:
        parts = [f"tileSize: {p['tileSize']}", f"size: {p['size']}"]
        if p.get("fallback"):
            parts.append("fallback: true")
        lines.append("    { " + ", ".join(parts) + " },")
    lines.append("]")
    return "\n".join(lines)


def js_snippet(stem: str, params: list[dict], base_path: str) -> str:
    """
    Emit a ready-to-use JavaScript snippet.

    Directories on disk are 1-indexed (dir 1 = fallback, dir 2+ = tiled).
    Avansel passes l=0 for fallback, l=1 for first tiled level, etc.
    parseInt(l)+1 correctly maps callback level -> directory name on disk.

    Filename: {face}_{row}_{col}.jpg -> in callback: ${s}_${y}_${x}.jpg
    """
    params_js = js_params_str(params)
    path = base_path.rstrip("/")
    return (
        f"{params_js}\n"
        f"\n"
        f"new Avansel(container)\n"
        f"    .multires(params, () => (s, l, x, y) => {{\n"
        f"        l = parseInt(l) + 1\n"
        f"        return `{path}/{stem}/${{l}}/${{s}}_${{y}}_${{x}}.jpg`\n"
        f"    }}).start()"
    )


# -- Main processing -----------------------------------------------------------

def process_image(img_path: str, base_path: str, fallback_override: int) -> bool:
    img_path = os.path.abspath(img_path)
    stem     = os.path.splitext(os.path.basename(img_path))[0]
    out_dir  = os.path.join(os.path.dirname(img_path), f"{stem}")

    print(f"\nProcessing: {img_path}", file=sys.stderr)
    print(f"Output:     {out_dir}",    file=sys.stderr)

    img = Image.open(img_path).convert('RGB')
    W, H = img.size
    print(f"Source:     {W} x {H} px", file=sys.stderr)

    fallback_size, tiled_sizes = compute_level_sizes(W, fallback_override)
    if not tiled_sizes and not fallback_size:
        print("ERROR: image too small to generate tiles.", file=sys.stderr)
        return False

    params = build_params(fallback_size, tiled_sizes)

    print(f"Cube face:  ~{round(W / math.pi)} px", file=sys.stderr)
    print(f"Dir 1:      fallback {fallback_size} px (1x1 tile per face)", file=sys.stderr)
    for i, s in enumerate(tiled_sizes):
        n = math.ceil(s / TILE_SIZE)
        print(f"Dir {i+2}:      {s} px ({n}x{n} tiles per face)", file=sys.stderr)

    os.makedirs(out_dir, exist_ok=True)

    img_np = np.array(img)
    img.close();  del img

    max_face_size = tiled_sizes[-1] if tiled_sizes else fallback_size

    for face in FACES:
        print(f"  [{face}] projecting at {max_face_size} px ... ",
              end='', flush=True, file=sys.stderr)
        face_img = equirect_to_face(img_np, face, max_face_size)
        print("done", file=sys.stderr)

        # Dir 1: fallback - single tile per face
        print(f"  [{face}] dir 1/ fallback ({fallback_size} px) ... ",
              end='', flush=True, file=sys.stderr)
        save_level_tiles(face_img, face, dir_idx=1,
                         level_size=fallback_size, tile_size=fallback_size,
                         out_dir=out_dir)
        print("done", file=sys.stderr)

        # Dirs 2..N: tiled levels, smallest to largest
        for i, size in enumerate(tiled_sizes):
            dir_idx = i + 2
            n_tiles = math.ceil(size / TILE_SIZE)
            print(f"  [{face}] dir {dir_idx}/ ({size} px, {n_tiles}x{n_tiles} tiles) ... ",
                  end='', flush=True, file=sys.stderr)
            save_level_tiles(face_img, face, dir_idx=dir_idx,
                             level_size=size, tile_size=TILE_SIZE,
                             out_dir=out_dir)
            print("done", file=sys.stderr)

        del face_img

    del img_np

    # -- preview.jpg: front face at PREVIEW_SIZE -------------------------------
    print("  Generating preview.jpg ... ", end='', flush=True, file=sys.stderr)
    img_small = Image.open(img_path).convert('RGB')
    img_small_np = np.array(img_small);  img_small.close();  del img_small
    preview = equirect_to_face(img_small_np, 'f', PREVIEW_SIZE)
    del img_small_np
    preview.save(os.path.join(out_dir, 'preview.jpg'), 'JPEG', quality=JPEG_QUALITY)
    del preview
    print("done", file=sys.stderr)

    # -- GPS -------------------------------------------------------------------
    get_gps_coordinates(img_path)   # warns to stderr if absent

    # -- JS snippet ------------------------------------------------------------
    print("\n--- JavaScript snippet ---", file=sys.stderr)
    print(js_snippet(stem, params, base_path))
    print("--------------------------", file=sys.stderr)

    print(f"\nDone -> {out_dir}\n", file=sys.stderr)
    return True


# -- CLI -----------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='avansel.py',
        description='Generate Avansel multires cube tiles from equirectangular panoramas.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Output: {stem}/ directory next to each input image.\n'
            'Large panoramas (>= 25 MP) may require 8-12 GB of free RAM.\n\n'
            'Filename: {dir}/{face}_{row}_{col}.jpg  (1-indexed dirs, 0-indexed row/col)\n'
            'JS:       parseInt(l)+1 maps callback level -> directory number'
        ),
    )
    parser.add_argument('images', nargs='+',
                        help='Path(s) to equirectangular JPEG/TIFF')
    parser.add_argument('--base-path', default='',
                        help='Base URL prefix for the JS snippet (e.g. /assets/panos)')
    parser.add_argument('--fallback-size', type=int, default=0,
                        help='Override the fallback tile size in px (default: auto)')
    args = parser.parse_args()

    failed = 0
    for path in args.images:
        if not os.path.isfile(path):
            print(f"ERROR: file not found: {path}", file=sys.stderr)
            failed += 1
            continue
        try:
            if not process_image(path, args.base_path, args.fallback_size):
                failed += 1
        except Exception as exc:
            print(f"ERROR processing {path}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            failed += 1

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()