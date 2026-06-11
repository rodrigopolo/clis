#!/usr/bin/env python3
"""
pano2web.py - Convert equirectangular panoramas into viewer-ready static sites.

For each input image, projects the equirectangular source to a cube map one
face at a time (memory-conscious, mirroring the per-face approach of
krpano.py and the WebGL CubeMapper in PanoUp/public/upload/webgl.js), tiles
each face immediately for the selected viewer's multires format, and writes
a self-contained index.html (+ tour.xml for krpano) at the root of the output
directory.

Usage:
    python3 pano2web.py [--viewer {pannellum,marzipano,avansel,krpano}] image.jpg [image2.tif ...]

Output (next to each source image):
    {stem}/
        index.html          (+ tour.xml for krpano)
        og_image.jpg
        tiles/              multires cube tiles, preview.jpg/thumb.jpg (viewer-dependent)
        <viewer assets>/    bundled offline viewer assets (krpano library not bundled)

Dependencies: Pillow, numpy.
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

from panolib.cubemap import equirect_to_face
from panolib.viewer_calc import face_size
from panolib.tilers import VIEWER_TILERS, PREVIEW_FACE_SIZE, generate_og_image, generate_thumb
from panolib.gps import get_gps_coordinates
from panolib.render import render, copy_assets

# Disable PIL's decompression bomb guard so large panoramas can be opened
Image.MAX_IMAGE_PIXELS = None

FACES = ['f', 'b', 'r', 'l', 'u', 'd']
DEFAULT_VIEWER = 'pannellum'


def derive_title(stem: str) -> str:
    title = stem.replace('_', ' ').replace('-', ' ').strip()
    return title or stem


def process_image(path: str, viewer: str) -> None:
    abs_path = os.path.abspath(path)
    stem = os.path.splitext(os.path.basename(abs_path))[0]
    out_dir = os.path.join(os.path.dirname(abs_path), stem)
    tiles_dir = os.path.join(out_dir, 'tiles')

    print(f"\nProcessing: {abs_path}", file=sys.stderr)
    print(f"Output:     {out_dir}", file=sys.stderr)

    img = Image.open(abs_path).convert('RGB')
    W, H = img.size
    print(f"Source:     {W} x {H} px", file=sys.stderr)

    tiler = VIEWER_TILERS[viewer]()
    size = face_size(viewer, W)
    tiler.compute_level_sizes(size)
    if hasattr(tiler, 'level_sizes') and not tiler.level_sizes:
        raise ValueError(
            f"Equirectangular width {W}px is too small for --viewer {viewer} "
            f"(cube face size {size}px yields no tile levels)."
        )
    print(f"Cube face:  {size} px", file=sys.stderr)

    os.makedirs(tiles_dir, exist_ok=True)

    img_np = np.array(img)
    img.close()
    del img

    thumbs: dict[str, Image.Image] = {}  # 256x256 per face, used for preview.jpg

    for face in FACES:
        print(f"  [{face}] projecting at {size} px ... ", end='', flush=True, file=sys.stderr)
        face_img = equirect_to_face(img_np, face, size)
        print("done", file=sys.stderr)

        print(f"  [{face}] tiling ... ", end='', flush=True, file=sys.stderr)
        tiler.process_face(face_img, face, tiles_dir)
        print("done", file=sys.stderr)

        if face == 'f':
            generate_og_image(face_img, out_dir)
            if tiler.GENERATES_THUMB:
                generate_thumb(face_img, tiles_dir)

        thumbs[face] = face_img.resize((PREVIEW_FACE_SIZE, PREVIEW_FACE_SIZE), Image.LANCZOS)
        del face_img

    del img_np

    multires = tiler.finalize(tiles_dir, thumbs)
    del thumbs

    if viewer == 'krpano':
        lat, lng, _alt = get_gps_coordinates(abs_path)
    else:
        lat, lng = '', ''

    render(viewer, out_dir, {
        'title': derive_title(stem),
        'description': '',
        'og_url': 'FILL THIS WITH THE URL',
        'multires': multires,
        'lat': lat,
        'lng': lng,
    })
    copy_assets(viewer, out_dir)

    print(f"Done -> {out_dir}\n", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog='pano2web.py',
        description="Convert equirectangular panoramas into viewer-ready static sites "
                     "(cubemap + multires tiles + index.html).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Output: {stem}/ directory next to each input image, with tiles/ "
               "inside it and index.html (+ tour.xml for krpano) at its root.",
    )
    parser.add_argument(
        '--viewer', choices=sorted(VIEWER_TILERS.keys()), default=DEFAULT_VIEWER,
        help=f"Target viewer (default: {DEFAULT_VIEWER})",
    )
    parser.add_argument('images', nargs='+', help='Path(s) to equirectangular JPEG/TIFF/etc.')
    args = parser.parse_args()

    failed = 0
    for path in args.images:
        if not os.path.isfile(path):
            print(f"ERROR: file not found: {path}", file=sys.stderr)
            failed += 1
            continue
        try:
            process_image(path, args.viewer)
        except Exception as exc:
            print(f"ERROR processing {path}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()
            failed += 1

    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
