# 360° Panorama Scripts

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

#### Alternative to `tocubemap.sh`
A faster alternative for `tocubemap.sh` is `kubi`, a cubemap generator based on
`libvips`. In fact, it is 4.9x faster than Hugin's `nona`, but lacks the
possibility to do the process in reverse, and doesn't calculate the output image
size automatically.

To install `kubi` on macOS you'll need to have Python installed, a quick and
reliable way to have Python installed is `pyenv`, a Python version manager that
lets you easily install, switch between, and manage multiple Python versions,
`pyenv` needs to be installed with Homebrew:

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
pyenv install 3.10.4
pyenv global 3.10.4
```

Once we have Python and `pip` installed, we install Kubi:
```sh
pip install git+https://github.com/indus/kubi.git
```

Kubi requires `libvips`, an Image processing library that can be installed with
Homebrew
```sh
brew install vips
```

To produce the same results as with `tocubemap.sh`:
```sh
kubi -s 6848 -f Right Left Up Down Front Back Panorama.tif Panorama
```

Here is a wrapper to make Kubi work as `tocubemap.sh`
```sh
./kubi.sh Panorama.tif
```

And to install the wrapper
```sh
curl -O https://raw.githubusercontent.com/rodrigopolo/clis/refs/heads/main/360/kubi.sh
chmod +x kubi.sh
```

### More about dependencies
* About `exiftool`: https://formulae.brew.sh/formula/exiftool
* About ImageMagick: https://imagemagick.org
* About `kubi`: https://github.com/indus/kubi
* About `pyenv`: https://github.com/pyenv/pyenv
* About `libvips`: https://github.com/libvips/libvips
* Homebrew: https://brew.sh
* Hugin app from Dannephoto repo: https://bitbucket.org/Dannephoto/hugin/downloads/
