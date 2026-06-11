"""
Multires tile generators, one per viewer.

Ported from PanoUp/app/classes/{TilerBase,PannellumTiler,MarzipanoTiler,
AvanselTiler,KrpanoTiler}.php. The PHP classes operate on Imagick/GD handles
loaded from {face}.jpg files on disk; here each tiler operates directly on an
in-memory PIL Image for the cube face that was just rendered, so a face never
needs to be written to disk before being tiled.

Each tiler exposes:
    compute_level_sizes(face_width: int) -> None
    process_face(face_img: PIL.Image, face: str, tiles_dir: str) -> None
    finalize(tiles_dir: str, thumbs: dict[str, PIL.Image]) -> dict

`thumbs` is a dict of 256x256 PIL Images, one per face letter, used by
generate_preview() (Marzipano, Krpano).
"""

import math
import os

from PIL import Image

JPEG_QUALITY = 90
PREVIEW_FACE_SIZE = 256
PREVIEW_FACE_ORDER = ['l', 'f', 'r', 'b', 'u', 'd']


def js_round(x: float) -> int:
    """Match JavaScript's Math.round / PHP's round (half away from zero) for x >= 0."""
    return math.floor(x + 0.5)


def round_to_nearest(number: int, divisor: int) -> int:
    return js_round(number / divisor) * divisor


def _save_jpeg(img: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, 'JPEG', quality=JPEG_QUALITY)


def _resize_if_needed(src: Image.Image, size: int) -> Image.Image:
    if src.width != size:
        return src.resize((size, size), Image.LANCZOS)
    return src


def _write_tile_grid(resized: Image.Image, level_size: int, tile_size: int, path_fn) -> None:
    """Crop `resized` (level_size x level_size) into a grid of <= tile_size tiles.

    Edge tiles smaller than tile_size are produced when level_size is not an
    exact multiple of tile_size. path_fn(row, col) -> destination path
    (row/col are 0-based).
    """
    n_full = level_size // tile_size
    n_total = n_full + (1 if level_size % tile_size else 0)
    for row in range(n_total):
        y0 = row * tile_size
        h = min(tile_size, level_size - y0)
        for col in range(n_total):
            x0 = col * tile_size
            w = min(tile_size, level_size - x0)
            tile = resized.crop((x0, y0, x0 + w, y0 + h))
            _save_jpeg(tile, path_fn(row, col))


# ── Derived images (shared across tilers, mirrors TilerBase.php) ────────────

def generate_og_image(front_face_img: Image.Image, out_dir: str) -> None:
    """og_image.jpg (1200x630): center 40:21 crop of the front face, scaled."""
    w = front_face_img.width
    crop_h = js_round(w * 21 / 40)
    y = (w - crop_h) // 2
    cropped = front_face_img.crop((0, y, w, y + crop_h))
    resized = cropped.resize((1200, 630), Image.LANCZOS)
    _save_jpeg(resized, os.path.join(out_dir, 'og_image.jpg'))


def generate_preview(thumbs: dict, out_dir: str) -> None:
    """preview.jpg (256x1536): vertical strip of all 6 faces, order l,f,r,b,u,d."""
    preview = Image.new('RGB', (PREVIEW_FACE_SIZE, PREVIEW_FACE_SIZE * 6))
    for i, face in enumerate(PREVIEW_FACE_ORDER):
        preview.paste(thumbs[face], (0, i * PREVIEW_FACE_SIZE))
    _save_jpeg(preview, os.path.join(out_dir, 'preview.jpg'))


def generate_thumb(front_face_img: Image.Image, out_dir: str) -> None:
    """thumb.jpg (240x240) resized directly from the full-resolution front face."""
    thumb = front_face_img.resize((240, 240), Image.LANCZOS)
    _save_jpeg(thumb, os.path.join(out_dir, 'thumb.jpg'))


# ── Pannellum ────────────────────────────────────────────────────────────────

class PannellumTiler:
    """Output: {tiles_dir}/{level}/{face}_{row}_{col}.jpg, 0-indexed, 512px tiles."""

    TILE_SIZE = 512
    CUBE_LEVELS = [16384, 8192, 4096, 2048, 1024, 512]
    GENERATES_PREVIEW = False
    GENERATES_THUMB = False

    def __init__(self):
        self.level_sizes: list[int] = []

    def compute_level_sizes(self, face_width: int) -> None:
        snapped = round_to_nearest(face_width, self.TILE_SIZE)
        self.level_sizes = sorted(s for s in self.CUBE_LEVELS if snapped >= s)

    def process_face(self, face_img: Image.Image, face: str, tiles_dir: str) -> None:
        if not self.level_sizes:
            self.compute_level_sizes(face_img.width)

        for idx, size in enumerate(self.level_sizes):
            li = idx + 1
            resized = _resize_if_needed(face_img, size)

            def _path(row, col, li=li, face=face):
                return os.path.join(tiles_dir, str(li), f"{face}_{row}_{col}.jpg")

            _write_tile_grid(resized, size, self.TILE_SIZE, _path)

    def finalize(self, tiles_dir: str, thumbs: dict) -> dict:
        cube_resolution = self.level_sizes[-1] if self.level_sizes else 0
        return {
            'cubeResolution': cube_resolution,
            'maxLevel': len(self.level_sizes),
            'tileResolution': self.TILE_SIZE,
            'panoTiles': None,
        }


# ── Marzipano ────────────────────────────────────────────────────────────────

class MarzipanoTiler:
    """Output: {tiles_dir}/{level}/{face}_{row}_{col}.jpg, 1-indexed, 512px tiles."""

    TILE_SIZE = 512
    PREVIEW_SIZE = 256
    CUBE_CANDIDATES = [16384, 8192, 4096, 2048, 1024, 512]
    GENERATES_PREVIEW = True
    GENERATES_THUMB = False

    def __init__(self):
        self.level_sizes: list[int] = []

    def compute_level_sizes(self, face_width: int) -> None:
        snapped = round_to_nearest(face_width, self.TILE_SIZE)
        sizes = [s for s in self.CUBE_CANDIDATES if s <= snapped]
        if self.TILE_SIZE not in sizes:
            sizes.append(self.TILE_SIZE)
        self.level_sizes = sorted(sizes)

    def process_face(self, face_img: Image.Image, face: str, tiles_dir: str) -> None:
        if not self.level_sizes:
            self.compute_level_sizes(face_img.width)

        for idx, size in enumerate(self.level_sizes):
            li = idx + 1
            resized = _resize_if_needed(face_img, size)

            def _path(row, col, li=li, face=face):
                return os.path.join(tiles_dir, str(li), f"{face}_{row + 1}_{col + 1}.jpg")

            _write_tile_grid(resized, size, self.TILE_SIZE, _path)

    def finalize(self, tiles_dir: str, thumbs: dict) -> dict:
        cube_resolution = self.level_sizes[-1] if self.level_sizes else 0
        pano_tiles = [{'tileSize': self.PREVIEW_SIZE, 'size': self.PREVIEW_SIZE, 'fallbackOnly': True}]
        for size in self.level_sizes:
            pano_tiles.append({'tileSize': self.TILE_SIZE, 'size': size})

        generate_preview(thumbs, tiles_dir)

        return {
            'cubeResolution': cube_resolution,
            'maxLevel': len(self.level_sizes),
            'tileResolution': self.TILE_SIZE,
            'panoTiles': pano_tiles,
        }


# ── Avansel ──────────────────────────────────────────────────────────────────

class AvanselTiler:
    """Output: {tiles_dir}/1/.. = fallback (single, possibly < 512px tile),
    {tiles_dir}/2../{N+1}/.. = tiled levels at 512px, 0-indexed, edge tiles allowed."""

    TILE_SIZE = 512
    GENERATES_PREVIEW = False
    GENERATES_THUMB = False

    def __init__(self):
        self.fallback_size = 0
        self.tiled_sizes: list[int] = []

    def compute_level_sizes(self, face_width: int) -> None:
        tiled = []
        s = face_width
        while s > self.TILE_SIZE:
            tiled.append(s)
            s = (s + 1) // 2  # ceil(s / 2)
        tiled.sort()

        base = tiled[0] if tiled else face_width
        self.fallback_size = min((base + 1) // 2, self.TILE_SIZE)
        self.tiled_sizes = tiled

    def process_face(self, face_img: Image.Image, face: str, tiles_dir: str) -> None:
        if not self.tiled_sizes and self.fallback_size == 0:
            self.compute_level_sizes(face_img.width)

        # Dir 1: fallback - one (possibly non-512) tile covers the whole face
        self._write_level(face_img, face, 1, self.fallback_size, self.fallback_size, tiles_dir)

        # Dirs 2..N: tiled levels, ascending
        for i, size in enumerate(self.tiled_sizes):
            self._write_level(face_img, face, i + 2, size, self.TILE_SIZE, tiles_dir)

    def _write_level(self, face_img, face, dir_idx, level_size, tile_size, tiles_dir) -> None:
        resized = _resize_if_needed(face_img, level_size)

        def _path(row, col, dir_idx=dir_idx, face=face):
            return os.path.join(tiles_dir, str(dir_idx), f"{face}_{row}_{col}.jpg")

        _write_tile_grid(resized, level_size, tile_size, _path)

    def finalize(self, tiles_dir: str, thumbs: dict) -> dict:
        cube_resolution = self.tiled_sizes[-1] if self.tiled_sizes else self.fallback_size
        pano_tiles = [{'tileSize': self.fallback_size, 'size': self.fallback_size, 'fallback': True}]
        for size in self.tiled_sizes:
            pano_tiles.append({'tileSize': self.TILE_SIZE, 'size': size})

        return {
            'cubeResolution': cube_resolution,
            'maxLevel': 1 + len(self.tiled_sizes),
            'tileResolution': self.TILE_SIZE,
            'panoTiles': pano_tiles,
        }


# ── Krpano ───────────────────────────────────────────────────────────────────

class KrpanoTiler:
    """Output: {tiles_dir}/{face}/l{level}/{row:02d}/l{level}_{face}_{row:02d}_{col:02d}.jpg,
    1-indexed with 2-digit zero-padding, 512px tiles, edge tiles allowed."""

    TILE_SIZE = 512
    GENERATES_PREVIEW = True
    GENERATES_THUMB = True

    def __init__(self):
        self.level_sizes: list[int] = []

    def compute_level_sizes(self, face_width: int) -> None:
        max_level = js_round(face_width / 128) * 128
        levels = []
        current = max_level
        while current > self.TILE_SIZE:
            levels.append(current)
            current = (current // 256) * 128  # halve, floor to nearest 128
        self.level_sizes = sorted(levels)

    def process_face(self, face_img: Image.Image, face: str, tiles_dir: str) -> None:
        if not self.level_sizes:
            self.compute_level_sizes(face_img.width)

        for idx, size in enumerate(self.level_sizes):
            li = idx + 1
            resized = _resize_if_needed(face_img, size)

            def _path(row, col, li=li, face=face):
                row_str = f"{row + 1:02d}"
                col_str = f"{col + 1:02d}"
                return os.path.join(tiles_dir, face, f"l{li}", row_str,
                                     f"l{li}_{face}_{row_str}_{col_str}.jpg")

            _write_tile_grid(resized, size, self.TILE_SIZE, _path)

    def finalize(self, tiles_dir: str, thumbs: dict) -> dict:
        cube_resolution = self.level_sizes[-1] if self.level_sizes else 0
        pano_tiles = ','.join(str(s) for s in [self.TILE_SIZE] + self.level_sizes)

        generate_preview(thumbs, tiles_dir)

        return {
            'cubeResolution': cube_resolution,
            'maxLevel': len(self.level_sizes),
            'tileResolution': self.TILE_SIZE,
            'panoTiles': pano_tiles,
        }


VIEWER_TILERS = {
    'pannellum': PannellumTiler,
    'marzipano': MarzipanoTiler,
    'avansel': AvanselTiler,
    'krpano': KrpanoTiler,
}
