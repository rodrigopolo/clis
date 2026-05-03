# Rodrigo Polo's CLIs

Multiple command line utilities and scripts for the daily use.

* [Local Bin](./bin)
* [360](./360)

## Dependencies

### Homebrew
You'll need to install Homebrew, the free and open-source software package
management system for macOS, installations instrucctions are available in the
official Homebrew site: https://brew.sh

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

## CLIs Installation
Cloning the repo into your home folder
```sh
cd
git clone https://github.com/rodrigopolo/clis.git
```

Add the `~/clis/bin` to the shell
```sh
echo '[[ -d $HOME/clis/bin ]] && export PATH="$HOME/clis/bin:$PATH"' >> ~/.zshrc
```

Execute scripts in the `360` directory
```sh
~/clis/360/toequirectangular.sh
```

Update the scripts
```sh
cd ~/clis
git pull
```

### For the scripts in the `bin` folder

Install the following brew formulas
```sh
brew install wget mediainfo exiftool ffmpeg yt-dlp aria2
```

### Python
Python is required for the `srt` `Kubi.sh` scripts

A quick and reliable way to have Python installed is `pyenv`, a Python version
manager that lets you easily install, switch between, and manage multiple Python
versions, `pyenv` needs to be installed with Homebrew:

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

# fixa1instadate

Fixes EXIF date metadata and renames image files from the **Insta360 X5** and 
**Antigravity A1** 360 cameras. Handles both originals (`.insp`, `.dng`) and
stitched outputs (`.dng`, `.jpg`).

## The problem

Stitching software (Antigravity Studio, Insta360 Studio) overwrites `ModifyDate`
with the stitching timestamp, and some files (`.insp`, stitched `.jpg`) ship
with no date metadata at all. The original capture time is always encoded in the
filename.

## Usage

```
fixa1instadate [--offset OFFSET] [--dry-run] <file> [<file> ...]
```

| Option      | Default  | Description                                                 |
|-------------|----------|-------------------------------------------------------------|
| `--offset`  | `-06:00` | Timezone offset written into EXIF (e.g. `-05:00`, `+02:00`) |
| `--dry-run` | off      | Print what would happen without modifying any files         |

**Examples**

```bash
# Preview changes for all A1 files
fixa1instadate --dry-run *.dng *.jpg

# Fix files using a different timezone
fixa1instadate --offset -05:00 *.dng *.insp

# Fix everything at once
fixa1instadate *.dng *.jpg
```

## What it does

For each file, the script runs three steps in order:

### 1. Camera validation

Reads `Make` and `Model` from EXIF and verifies the file comes from a known 360
camera. Files from unrecognized cameras are skipped with a warning.

| Make (contains) | Model (contains) | Camera                        |
|-----------------|------------------|-------------------------------|
| `Yingling`      | `Antigravity`    | Antigravity A1                |
| `Arashi`        | `Insta360`       | Insta360 X5 / Insta360 Camera |

### 2. Date extraction

Checks sources in this priority order, using the first match:

1. **`DateTimeOriginal`** — set by camera firmware at capture time
2. **`CreateDate`** — also firmware-set
3. **Filename** — `IMG_YYYYMMDD_HHMMSS_NNN.ext` pattern, encoded at capture
4. **`ModifyDate`** — only if no filename match exists (unreliable: stitching software overwrites it)

The filename fallback is preferred over `ModifyDate` because stitching software
corrupts `ModifyDate` with the processing timestamp, while the filename always
reflects the original capture moment.

### 3. EXIF write

Sets the following fields (matching the approach used in `setpicdate.py`):

- `DateTimeOriginal`, `CreateDate`, `ModifyDate`
- `FileModifyDate`
- `OffsetTime`, `OffsetTimeOriginal`, `OffsetTimeDigitized`
- `IPTC:DigitalCreationDate`, `IPTC:TimeCreated`, `IPTC:DigitalCreationTime`
- `XMP:DateCreated`

### 4. Rename

Renames the file to a sortable, human-readable format:

```
IMG_20260501_161337_005.dng  ->  2026-05-01 16.13.37 IMG_005.dng
IMG_20260429_194801_00_017.jpg  ->  2026-04-29 19.48.03 IMG_017.jpg
```

The numeric suffix is the last group of digits in the original filename,
zero-padded to 3 digits.

## Supported files

`.dng` `.jpg` `.jpeg` `.insp`

## Requirements

- Python 3.10+
- [`exiftool`](https://exiftool.org/) available in `$PATH`
