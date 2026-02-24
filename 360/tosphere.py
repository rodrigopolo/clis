#!/usr/bin/env python3
"""
tosphere.py — Stitch cube-face images back into an equirectangular TIFF.

Accepts any mix of cube-face files (TIFF or JPEG).  From each given path the
script strips the face suffix (_b, _d, _f, _l, _r, _u) to derive a prefix,
then auto-discovers the remaining five faces in the same directory.  Multiple
files from the same panorama are deduplicated automatically.

Output:
    {prefix}.tif   — equirectangular TIFF, saved next to the input faces

Output dimensions:
    width  = round(face_size × π)      e.g. 6655 → 20907
    height = round(width / 2)          e.g. 20907 → 10454
(Matches the reference krpano tool.  The old toequirectangular.sh gives 20912×10456
because it truncates π×face_size and rounds up to the next multiple of 16.)

Usage:
    python3 tosphere.py IMG_1650_f.tif              # auto-discovers the other 5
    python3 tosphere.py sceneA_f.tif sceneB_f.tif   # two panoramas
    python3 tosphere.py *.tif                        # whole folder

Dependencies: Pillow, numpy
"""

import sys
import math
import os
import argparse

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

# ── Constants ─────────────────────────────────────────────────────────────────

# Lowercase single-letter face keys used throughout
FACES = ['f', 'b', 'r', 'l', 'u', 'd']

# Maps filename suffix → face key
SUFFIX_TO_FACE: dict[str, str] = {
    '_f': 'f', '_b': 'b', '_r': 'r', '_l': 'l', '_u': 'u', '_d': 'd',
}

EXTENSIONS = ['.tif', '.tiff', '.TIF', '.TIFF', '.jpg', '.jpeg', '.JPG', '.JPEG']


# ── Input discovery ───────────────────────────────────────────────────────────

def parse_face_path(path: str) -> tuple[str, str, str] | None:
    """
    Extract (directory, prefix, face_key) from a cube-face file path.
    Returns None if the filename does not end with a recognised face suffix.
    """
    directory = os.path.dirname(os.path.abspath(path))
    stem = os.path.splitext(os.path.basename(path))[0]

    for suffix, face in SUFFIX_TO_FACE.items():
        if stem.endswith(suffix):
            prefix = stem[: -len(suffix)]
            return directory, prefix, face

    return None


def find_all_faces(directory: str, prefix: str) -> dict[str, str]:
    """
    Return a dict mapping face_key → absolute file path for all 6 faces
    found in *directory* with the given *prefix*.  Any supported extension
    is accepted; the first match per face wins.
    """
    found: dict[str, str] = {}
    for suffix, face in SUFFIX_TO_FACE.items():
        for ext in EXTENSIONS:
            candidate = os.path.join(directory, prefix + suffix + ext)
            if os.path.isfile(candidate):
                found[face] = candidate
                break
    return found


def collect_panoramas(paths: list[str]) -> list[tuple[str, str, dict[str, str]]]:
    """
    Given a list of arbitrary file paths (any mix of faces / panoramas),
    return a deduplicated list of (directory, prefix, face_paths) tuples
    where face_paths contains all 6 faces.  Panoramas with missing faces
    are skipped with a warning.
    """
    seen: set[tuple[str, str]] = set()
    panoramas: list[tuple[str, str, dict[str, str]]] = []

    for path in paths:
        parsed = parse_face_path(path)
        if parsed is None:
            print(f"WARNING: {path} has no recognised face suffix (_f/_b/_l/_r/_u/_d) — skipping",
                  file=sys.stderr)
            continue

        directory, prefix, _ = parsed
        key = (directory, prefix)
        if key in seen:
            continue
        seen.add(key)

        face_paths = find_all_faces(directory, prefix)
        missing = [f for f in FACES if f not in face_paths]
        if missing:
            print(f"WARNING: {prefix}: missing faces {missing} — skipping", file=sys.stderr)
            continue

        panoramas.append((directory, prefix, face_paths))

    return panoramas


# ── Inverse projection ────────────────────────────────────────────────────────

def faces_to_equirect(face_imgs: dict[str, np.ndarray],
                      out_w: int, out_h: int) -> np.ndarray:
    """
    Reconstruct an equirectangular image from six cube faces.

    face_imgs: dict mapping face key → (size, size, 3) uint8 numpy array.
               All six faces must be square and the same size.
    out_w, out_h: output dimensions (pixels).

    Returns: (out_h, out_w, 3) uint8 numpy array.

    Coordinate system (right-handed, krpano): +Z=front, +X=right, +Y=up.

    Inverse UV formulas (derived from equirect_to_face direction vectors):
        f : u =  dx/dz,   v =  dy/dz
        b : u =  dx/dz,   v = -dy/dz   (dz < 0)
        r : u = -dz/dx,   v =  dy/dx   (dx > 0)
        l : u = -dz/dx,   v = -dy/dx   (dx < 0)
        u : u =  dx/dy,   v = -dz/dy   (dy > 0)
        d : u = -dx/dy,   v = -dz/dy   (dy < 0)
    UV ∈ [-1, +1]; face pixel = (u+1)/2*(size-1), (1-v)/2*(size-1).
    """
    face_size = next(iter(face_imgs.values())).shape[0]

    # ── Longitude / latitude grids for every output pixel ─────────────────
    cols = np.arange(out_w, dtype=np.float32)
    rows = np.arange(out_h, dtype=np.float32)
    col_grid, row_grid = np.meshgrid(cols, rows)   # (out_h, out_w)
    del cols, rows

    lon = (col_grid / np.float32(out_w - 1) * np.float32(2.0) - np.float32(1.0)) * np.float32(math.pi)
    lat = (np.float32(0.5) - row_grid / np.float32(out_h - 1)) * np.float32(math.pi)
    del col_grid, row_grid

    # ── 3-D unit direction vector ──────────────────────────────────────────
    cos_lat = np.cos(lat).astype(np.float32)
    dx = (cos_lat * np.sin(lon)).astype(np.float32)
    dy = np.sin(lat).astype(np.float32)
    dz = (cos_lat * np.cos(lon)).astype(np.float32)
    del lon, lat, cos_lat

    # ── Face assignment by dominant axis ──────────────────────────────────
    abs_dx = np.abs(dx)
    abs_dy = np.abs(dy)
    abs_dz = np.abs(dz)

    x_dom = (abs_dx >= abs_dy) & (abs_dx >= abs_dz)
    y_dom = ~x_dom & (abs_dy >= abs_dz)
    z_dom = ~x_dom & ~y_dom

    # 0=f 1=b 2=r 3=l 4=u 5=d
    face_idx = np.zeros((out_h, out_w), dtype=np.int8)
    face_idx[z_dom & (dz < 0)] = 1   # b
    face_idx[x_dom & (dx > 0)] = 2   # r
    face_idx[x_dom & (dx < 0)] = 3   # l
    face_idx[y_dom & (dy > 0)] = 4   # u
    face_idx[y_dom & (dy < 0)] = 5   # d
    del abs_dx, abs_dy, abs_dz, x_dom, y_dom, z_dom

    # ── UV coordinate arrays (filled per face) ─────────────────────────────
    uv_u = np.empty((out_h, out_w), dtype=np.float32)
    uv_v = np.empty((out_h, out_w), dtype=np.float32)

    # Front (0): u = dx/dz,  v = dy/dz   (dz > 0)
    m = face_idx == 0
    uv_u[m] = dx[m] / dz[m];   uv_v[m] = dy[m] / dz[m]

    # Back (1): u = dx/dz,  v = -dy/dz  (dz < 0)
    m = face_idx == 1
    uv_u[m] = dx[m] / dz[m];   uv_v[m] = -dy[m] / dz[m]

    # Right (2): u = -dz/dx, v = dy/dx  (dx > 0)
    m = face_idx == 2
    uv_u[m] = -dz[m] / dx[m];  uv_v[m] = dy[m] / dx[m]

    # Left (3): u = -dz/dx, v = -dy/dx  (dx < 0)
    m = face_idx == 3
    uv_u[m] = -dz[m] / dx[m];  uv_v[m] = -dy[m] / dx[m]

    # Up (4): u = dx/dy,  v = -dz/dy    (dy > 0)
    m = face_idx == 4
    uv_u[m] = dx[m] / dy[m];   uv_v[m] = -dz[m] / dy[m]

    # Down (5): u = -dx/dy, v = -dz/dy  (dy < 0)
    m = face_idx == 5
    uv_u[m] = -dx[m] / dy[m];  uv_v[m] = -dz[m] / dy[m]

    del dx, dy, dz, m

    # UV → face pixel coordinates
    fs_f32 = np.float32(face_size - 1)
    px = (uv_u + np.float32(1.0)) * np.float32(0.5) * fs_f32   # column in face
    py = (np.float32(1.0) - uv_v) * np.float32(0.5) * fs_f32   # row in face
    del uv_u, uv_v

    # ── Sample from each face ──────────────────────────────────────────────
    result = np.zeros((out_h, out_w, 3), dtype=np.uint8)

    face_list = [('f', 0), ('b', 1), ('r', 2), ('l', 3), ('u', 4), ('d', 5)]
    for face_key, fi in face_list:
        mask = face_idx == fi
        if not np.any(mask):
            continue

        face_np = face_imgs[face_key]
        px_m = px[mask]
        py_m = py[mask]

        x0 = np.floor(px_m).astype(np.int32)
        y0 = np.floor(py_m).astype(np.int32)
        wx = (px_m - x0.astype(np.float32))
        wy = (py_m - y0.astype(np.float32))

        # Clamp (cube faces don't wrap)
        x1 = np.clip(x0 + 1, 0, face_size - 1)
        y1 = np.clip(y0 + 1, 0, face_size - 1)
        x0 = np.clip(x0, 0, face_size - 1)
        y0 = np.clip(y0, 0, face_size - 1)

        c00 = face_np[y0, x0].astype(np.float32)
        c10 = face_np[y0, x1].astype(np.float32)
        c01 = face_np[y1, x0].astype(np.float32)
        c11 = face_np[y1, x1].astype(np.float32)
        del x0, x1, y0, y1

        wx = wx[:, np.newaxis]
        wy = wy[:, np.newaxis]
        sampled = (c00 * (1.0 - wx) * (1.0 - wy)
                   + c10 * wx * (1.0 - wy)
                   + c01 * (1.0 - wx) * wy
                   + c11 * wx * wy).astype(np.uint8)
        del c00, c10, c01, c11, wx, wy

        result[mask] = sampled

    del face_idx, px, py
    return result


# ── Main processing ───────────────────────────────────────────────────────────

def process_panorama(directory: str, prefix: str,
                     face_paths: dict[str, str]) -> bool:
    out_path = os.path.join(directory, f"{prefix}.tif")
    print(f"\nStitching: {prefix}")
    print(f"Output:    {out_path}")

    # Load all six faces
    face_imgs: dict[str, np.ndarray] = {}
    face_size: int | None = None

    for face in FACES:
        path = face_paths[face]
        print(f"  Loading [{face}] {os.path.basename(path)} … ", end='', flush=True)
        img = Image.open(path).convert('RGB')
        w, h = img.size
        if w != h:
            print(f"\nERROR: face '{face}' is not square ({w}×{h})", file=sys.stderr)
            return False
        if face_size is None:
            face_size = w
        elif w != face_size:
            print(f"\nERROR: face '{face}' size {w} differs from expected {face_size}",
                  file=sys.stderr)
            return False
        face_imgs[face] = np.array(img)
        img.close()
        print("done")

    out_w = round(face_size * math.pi)
    out_h = round(out_w / 2)
    print(f"  Face size:   {face_size} × {face_size} px")
    print(f"  Output size: {out_w} × {out_h} px")
    print(f"  Projecting … ", end='', flush=True)

    result_np = faces_to_equirect(face_imgs, out_w, out_h)
    del face_imgs
    print("done")

    print(f"  Saving … ", end='', flush=True)
    Image.fromarray(result_np).save(out_path, format='TIFF')
    del result_np
    print("done")

    print(f"Done → {out_path}\n")
    return True


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        prog='tosphere.py',
        description='Stitch cube-face images into an equirectangular TIFF.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            'Face suffixes recognised: _f _b _l _r _u _d\n'
            'Supported formats: TIFF (.tif/.tiff) and JPEG (.jpg/.jpeg)\n'
            'Passing any one face is enough — the other five are auto-discovered.'
        ),
    )
    parser.add_argument('faces', nargs='+', help='Path(s) to cube-face image(s)')
    args = parser.parse_args()

    panoramas = collect_panoramas(args.faces)
    if not panoramas:
        print("ERROR: no valid panorama sets found.", file=sys.stderr)
        sys.exit(1)

    failed = 0
    for directory, prefix, face_paths in panoramas:
        try:
            if not process_panorama(directory, prefix, face_paths):
                failed += 1
        except Exception as exc:
            print(f"ERROR stitching {prefix}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            failed += 1

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
