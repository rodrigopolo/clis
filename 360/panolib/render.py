"""
HTML/XML rendering and offline asset bundling.

Templates use string.Template ${VAR} placeholders, the same convention as
Templates/Pannellum.template. Layout (paths, viewer config keys) is based on
the reference outputs in /Users/rpolo/Desktop/dev/complete/<viewer>/.
"""

import html
import json
import os
import shutil
import sys
from string import Template

PACKAGE_DIR = os.path.dirname(os.path.abspath(__file__))
TEMPLATES_DIR = os.path.join(PACKAGE_DIR, 'templates')
ASSETS_DIR = os.path.join(PACKAGE_DIR, 'assets')

# krpano is licensed software and is not bundled; the user must drop their
# own copy of the library into this folder name inside each output directory.
KRPANO_DIR = 'krpano.1.23.3'

# Small (~KB), redistributable per-viewer assets bundled with this tool.
VIEWER_ASSETS = {
    'pannellum': {'dir': 'pannellum.2.5.7', 'files': ['style.css']},
    'marzipano': {'dir': 'marzipano.0.10.2', 'files': ['style.css', 'main.js']},
    'avansel': {'dir': 'avansel.0.0.17', 'files': ['style.css', 'main.js']},
    'krpano': {'dir': KRPANO_DIR, 'files': []},
}


def _esc(value: str) -> str:
    return html.escape(str(value), quote=True)


def _load_template(name: str) -> Template:
    with open(os.path.join(TEMPLATES_DIR, name), 'r', encoding='utf-8') as f:
        return Template(f.read())


def _write(path: str, content: str) -> None:
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)


def render(viewer: str, out_dir: str, ctx: dict) -> None:
    """Render index.html (and tour.xml for krpano) into out_dir."""
    multires = ctx['multires']
    common = {
        'TITLE': _esc(ctx['title']),
        'DESCRIPTION': _esc(ctx['description']),
        'OG_URL': _esc(ctx['og_url']),
    }

    if viewer == 'pannellum':
        html_out = _load_template('pannellum.html.tpl').substitute(
            **common,
            TILE_RESOLUTION=multires['tileResolution'],
            MAX_LEVEL=multires['maxLevel'],
            CUBE_RESOLUTION=multires['cubeResolution'],
        )
        _write(os.path.join(out_dir, 'index.html'), html_out)

    elif viewer in ('marzipano', 'avansel'):
        template_name = f'{viewer}.html.tpl'
        html_out = _load_template(template_name).substitute(
            **common,
            PANO_TILES=json.dumps(multires['panoTiles'], separators=(',', ':')),
        )
        _write(os.path.join(out_dir, 'index.html'), html_out)

    elif viewer == 'krpano':
        html_out = _load_template('krpano.html.tpl').substitute(
            **common,
            KRPANO_DIR=KRPANO_DIR,
        )
        _write(os.path.join(out_dir, 'index.html'), html_out)

        xml_out = _load_template('krpano_tour.xml.tpl').substitute(
            TITLE=_esc(ctx['title']),
            LAT=ctx['lat'],
            LNG=ctx['lng'],
            PANO_TILES=multires['panoTiles'],
        )
        _write(os.path.join(out_dir, 'tour.xml'), xml_out)

    else:
        raise ValueError(f"Unknown viewer: {viewer!r}")


def copy_assets(viewer: str, out_dir: str) -> None:
    """Copy bundled offline viewer assets into out_dir/<lib_dir>/."""
    info = VIEWER_ASSETS[viewer]
    lib_dir = os.path.join(out_dir, info['dir'])

    if info['files']:
        os.makedirs(lib_dir, exist_ok=True)
        for fname in info['files']:
            shutil.copy2(os.path.join(ASSETS_DIR, info['dir'], fname),
                          os.path.join(lib_dir, fname))
    else:
        print(f"NOTE: krpano is licensed software and is not bundled. "
              f"Copy your krpano installation (style.css, tour.js, skin/, plugins/, ...) "
              f"into '{lib_dir}' for the viewer to work.", file=sys.stderr)
