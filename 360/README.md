# 360° Panorama Scripts

## Python Panorama Scripts

A collection of self-contained Python scripts for working with equirectangular panorama
images and krpano-compatible multires cube tiles, no external tile-cutting tools required.

| Script           | Purpose                                                    |
|------------------|------------------------------------------------------------|
| `tocubemap.py`   | Equirectangular → six cube-face TIFFs                      |
| `tosphere.py`    | Six cube-face TIFFs → equirectangular TIFF                 |
| `tilecreator.py` | Equirectangular → krpano multires cube tiles + XML snippet |

---

## `tocubemap.py` — Equirectangular → cube-face TIFFs

Converts one or more equirectangular panoramas into six lossless TIFF cube-face images.
Useful as an intermediate step when you need individual face files for retouching,
HDR processing, or ingestion into other tools before tiling.

### Usage

```
python3 tocubemap.py <panorama.jpg> [<panorama2.jpg> ...]
```

```sh
# Single image
python3 tocubemap.py panorama.jpg

# Whole folder
python3 tocubemap.py panos/*.jpg
```

### Output

Six TIFF files are written **next to the input image**, one per cube face:

```
panorama_f.tif   ← front  (+Z)
panorama_b.tif   ← back   (-Z)
panorama_l.tif   ← left   (-X)
panorama_r.tif   ← right  (+X)
panorama_u.tif   ← up     (+Y)
panorama_d.tif   ← down   (-Y)
```

---

## `tosphere.py` — Cube-face TIFFs → equirectangular TIFF

Stitches six cube-face images (TIFF or JPEG) back into a single equirectangular TIFF.
Accepts any mix of face files — passing just one face is enough, the remaining five are
auto-discovered in the same directory by their `_f/_b/_l/_r/_u/_d` suffixes.

### Usage

```
python3 tosphere.py <any_face_file> [<face2> ...]
```

```sh
# Auto-discover all six faces from one
python3 tosphere.py panorama_f.tif

# Two separate panoramas in one call
python3 tosphere.py sceneA_f.tif sceneB_f.tif

# Whole folder (duplicates are deduplicated automatically)
python3 tosphere.py *.tif
```

### Input

Face files must follow the naming convention `{prefix}_{face}.{ext}` where face is one
of `f`, `b`, `l`, `r`, `u`, `d`. Supported formats: `.tif`, `.tiff`, `.jpg`, `.jpeg`
(any capitalisation). All six faces must be square and the same size.

### Output

One TIFF per panorama, written next to the input faces:

```
panorama.tif   ← equirectangular, saved next to the _f/_b/… files
```

Output dimensions match the krpano reference tool:

```
width  = round(face_size × π)     e.g. 6655 → 20907
height = round(width / 2)         e.g. 20907 → 10454
```

### Typical workflow

```
tocubemap.py  →  retouch faces  →  tosphere.py  →  tilecreator.py
equirect.jpg     *_f/b/l/r/u/d      equirect.tif     {stem}.tiles/
```

---

## `tilecreator.py` — Equirectangular → multires cube tiles

Converts one or more equirectangular panoramas into krpano-compatible multires cube tiles
and prints a ready-to-paste `<scene>` XML block for `tour.xml`.

### Usage

```
python3 tilecreator.py <equirectangular_image> [<image2> ...]
```

Process one image:

```sh
python3 tilecreator.py panorama.jpg
```

Process a whole folder:

```sh
python3 tilecreator.py panos/*.jpg
```

### Output

For each input image `{stem}.jpg`, a `{stem}.tiles/` directory is created **next to the input file**:

```
panorama.tiles/
├── preview.jpg          ← 256 × 1536: six 256×256 face thumbnails stacked vertically
├── thumb.jpg            ← 240 × 240: front face thumbnail (used by the tour skin)
├── f/                   ← front
│   ├── l1/              ← level 1 (smallest, e.g. 1024 px)
│   │   ├── 01/
│   │   │   ├── l1_f_01_01.jpg
│   │   │   └── l1_f_01_02.jpg
│   │   └── 02/ …
│   ├── l2/ l3/ l4/      ← larger levels (2048, 4096, 8192 px)
├── b/ l/ r/ u/ d/       ← back, left, right, up, down (same structure)
```

At the end of each run the script prints a ready-to-paste `<scene>` XML block for `tour.xml`.

### GPS coordinates

The script automatically reads GPS metadata from the source image's EXIF and populates
the `lat`, `lng`, and `alt` attributes in the XML output.

**Extraction order:**

1. **Pillow GPS IFD** — reads tag `0x8825` from the raw file before EXIF is stripped
   by the RGB conversion. Converts DMS tuples to decimal degrees and applies N/S/E/W sign.
2. **exiftool fallback** — if Pillow finds no GPS data and `exiftool` is on `PATH`,
   runs `exiftool -j -n` which returns numeric decimal degrees directly.
3. **Warning** — if neither method succeeds, a warning is printed to stderr and the
   attributes are left empty in the XML.

Example XML output with GPS data present:

```xml
<scene name="scene_panorama" title="panorama" onstart=""
       thumburl="panos/panorama.tiles/thumb.jpg"
       lat="14.594595" lng="-90.517725" alt="0.00" heading="0.0">
```

### Integrating with tour.xml

After running the script, copy the printed XML snippet into the `<krpano>` block of
your `tour.xml`. A complete minimal example:

```xml
<krpano version="1.23" title="Virtual Tour">
    <include url="skin/vtourskin.xml" />

    <scene name="scene_panorama"
           title="panorama"
           thumburl="panos/panorama.tiles/thumb.jpg"
           lat="14.594595" lng="-90.517725" alt="0.00" heading="0.0">

        <control bouncinglimits="calc:image.cube ? true : false" />
        <view hlookat="0.0" vlookat="0.0" fovtype="MFOV" fov="120"
              maxpixelzoom="2.0" fovmin="70" fovmax="140" limitview="auto" />
        <preview url="panos/panorama.tiles/preview.jpg" />

        <image>
            <cube url="panos/panorama.tiles/%s/l%l/%0v/l%l_%s_%0v_%0h.jpg"
                  multires="512,1024,2048,4096,8192" />
        </image>
    </scene>
</krpano>
```
---

## Requirements

#### Python
On macOS you'll need to have Python installed, a quick and reliable way to have
Python installed is `pyenv`, a Python version manager that lets you easily
install, switch between, and manage multiple Python versions, `pyenv` needs to
be installed with Homebrew:

```sh
brew install pyenv
```

After installing `pyenv` it will show some commands to add `pyenv` to the shell:
```sh
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(pyenv init - zsh)"' >> ~/.zshrc
```

These commands adds this to the `.zshrc` file the `pyenv` initialization, this
could vary from system to system:
```
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"
```

Now that we have `pyenv` installed, we have to install a `Python` version and
make it available systemwide:
```sh
pyenv install 3.13.3
pyenv global 3.13.3
pip install --upgrade pip
```

### Python libraries

| Dependency                              | Version             | Install              |
|-----------------------------------------|---------------------|----------------------|
| Python                                  | ≥ 3.10              |                      |
| [Pillow](https://pillow.readthedocs.io) | any recent          | `pip install Pillow` |
| [NumPy](https://numpy.org)              | any recent          | `pip install numpy`  |

Both libraries ship with most scientific Python distributions (Anaconda, miniforge, etc.).

```sh
pip install Pillow numpy
```

### Optional: exiftool (GPS fallback)

`tilecreator.py` extracts GPS coordinates from EXIF using Pillow as the primary method.
If Pillow cannot read the GPS IFD (e.g. some camera formats), it falls back to
[`exiftool`](https://exiftool.org) automatically if it is on your `PATH`.

| Platform        | Install                                                              |
|-----------------|----------------------------------------------------------------------|
| macOS           | `brew install exiftool`                                              |
| Ubuntu / Debian | `sudo apt install libimage-exiftool-perl`                            |
| Windows         | Download from [exiftool.org](https://exiftool.org) and add to `PATH` |

`exiftool` is entirely optional — if absent and Pillow also finds no GPS data, the
`lat`/`lng`/`alt` attributes in the XML output are left empty (identical to pre-GPS
behaviour) and a warning is printed to stderr.

---

### Memory requirements

All projection work is done in-memory with NumPy float32 arrays. Peak RAM usage
scales with the cube-face size, not the source image size.

| Max level            | Approx. peak RAM |
|----------------------|------------------|
| 1 024 px (1 level)   |          ~0.3 GB |
| 2 048 px (2 levels)  |          ~0.8 GB |
| 4 096 px (3 levels)  |            ~2 GB |
| 8 192 px (4 levels)  |            ~8 GB |
| 16 384 px (5 levels) |           ~30 GB |

The script processes one face at a time and frees intermediate arrays explicitly,
so the figures above are per-face peaks, not cumulative across all six faces.

### Performance

Projection time is dominated by NumPy's vectorised coordinate and interpolation
math. Rough benchmarks on an Apple M-series CPU:

| Input.          | Levels | Time   |
|-----------------|--------|--------|
|   7 200 × 3 600 |      2 |  ~15 s |
|  12 900 × 6 450 |      3 |  ~45 s |
| 25 736 × 12 868 |      4 | ~3 min |

## Bash scripts

* [Convert `tif` to cubemap using `tocubemap.sh`](#tocubemapsh).
* [Convert from cubemap to equirectangular with `toequirectangular.sh`](#toequirectangularsh).
* [Add the 360° panorama metadata with `add360metadata.sh`](#add360metadatash).
* [Set the geolcation with `setlocation`](#geolocation).
* [Convert to `jpg` with `tojpg.sh`](#convert-to-jpg).
* [Convert to `jpg` considering Facebook's max size with `tofacebookjpg.sh`](#convert-to-maximum-allowed-dimensions-for-facebook).
* [Publish on the web with Pannellum](#publish).
* [Dependencies](#dependencies)

A collection of scripts to handle 360° panoramas in batch with ExifTool,
ImageMagick and Hugin's `nona`, and `verdandi` CLIs.

## Installing dependencies and scripts

### Hugin
To install Hugin, **download it using the `curl` command** to avoid the
headaches macOS provide when downloading something from the internet, open the
image and drag the files to the Applications folder.

Hugin for Apple Silicon / ARM64
```sh
cd ~/Desktop
curl -L --progress-bar -O https://bitbucket.org/Dannephoto/hugin/downloads/Hugin-2024.0.1_arm64.dmg
open Hugin-2024.0.1_arm64.dmg
```

Hugin for Intel
```sh
cd ~/Desktop
curl -L --progress-bar -O https://bitbucket.org/Dannephoto/hugin/downloads/Hugin-2023.0.0_Intel.dmg
open Hugin-2023.0.0_Intel.dmg
```

### Homebrew
You'll need to install Homebrew, the free and open-source software package
management system for macOS, installations instrucctions are available in the
official Homebrew site: https://brew.sh

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### Other dependencies
For this scripts to work, we need to install `exiftool` which makes the scripts
able to read image information, and `imagemagick` for image manipulation:
```sh
brew install exiftool imagemagick
```

### Any of the scripts available here
To install any of the scripts, you can either clone the repo, or download each
script using curl and give it execution permissions, most of the scripts will
check for dependencies and show the usage if no arguments are provided.

Cloning the repo and running a script:
```sh
cd
git clone https://github.com/rodrigopolo/clis.git
cd clis/360
./toequirectangular.sh
```

Download just one script, and running it:
```sh
cd ~/Desktop
curl -O https://raw.githubusercontent.com/rodrigopolo/clis/refs/heads/main/360/toequirectangular.sh
chmod +x toequirectangular.sh
./toequirectangular.sh
```

## Scripts

### `tocubemap.sh`

To convert an equirectangular panorama `tif` image to 6 separated cube
faces.
```sh
./tocubemap.sh Pano.tif
```

It will produce the following files for each cube face in the same directory
where the input file is, using the file name as a prefix:
```
Pano_Back.tif
Pano_Down.tif
Pano_Front.tif
Pano_Left.tif
Pano_Right.tif
Pano_Up.tif
```

### `toequirectangular.sh`

To convert 6 separated `tif` image cube faces into an equirectangular panorama,
you can call it by setting just one cube face. The script will look for the file
name prefix, then look for the `_Back`, `_Down`, `_Front`, `_Left`, `_Right`
and `_Up` files, and the output file would have the `_equirectangular` suffix:
```sh
./toequirectangular.sh Pano_Front.tif
```

Result:
```
Panorama_equirectangular.tif
```

You can also call it by setting all the cube faces:
```sh
./toequirectangular.sh \
Pano_Back.tif \
Pano_Down.tif \
Pano_Front.tif \
Pano_Left.tif \
Pano_Right.tif \
Pano_Up.tif
```

### `add360metadata.sh`
Using `exiftool`, adds the necessary metadata to the `tif` file to be
interpreted as a 360° panorama. It overwrites the original file:
```sh
./add360metadata.sh Panorama.tif
```

### Geolocation
To set the geolocation of the `tif` file, you can look for the location in
Google Maps, then right-click on the place and select the decimal latitude
and longitude. It will be copied to the clipboard. Then, using the `setlocation`
tool provided in this repo's `bin` directory, call the command, paste the
location, and set the path to the `tif` file:
```sh
setlocation 14.596657575332861, -90.52320360681493 Panorama.tif
```

### Convert to JPG
```sh
./tojpg.sh Panorama.tif
```

### Convert to maximum allowed dimensions for Facebook
```sh
./tofacebookjpg.sh Panorama.tif
```

### Publish
To create the HTML and a multi-resolution cubemap for Pannellum, a lightweight,
free, and open source panorama viewer for the web:
```sh
./topannellum.sh Panorama.tif
```

#### Stitching and merging by rows or lines
The `ptogrid_rows.sh` and `ptogrid.sh` are experimental scripts to deal with
huge panoramas, by exporting `pto` files cropping by rows or lines. Options are
shown when executing the script without any argument.
```sh
./ptogrid.sh panorama.pto
./ptogrid_rows.sh panorama.pto
```

### More about dependencies
* About `exiftool`: https://formulae.brew.sh/formula/exiftool
* About ImageMagick: https://imagemagick.org
* About `pyenv`: https://github.com/pyenv/pyenv
* About `libvips`: https://github.com/libvips/libvips
* Homebrew: https://brew.sh
* Hugin app from Dannephoto repo: https://bitbucket.org/Dannephoto/hugin/downloads/