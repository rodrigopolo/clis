# Gaussian Splatting on Mac with FLOSS

## Scripts

Scripts for Antigravity A1 with PyCOLMAP (Faster)
* `Exctract.sh` exctracts sharp equirectangular frames and create the diretory structure for COLMAP.
* `A1PyColmap.py` exctracts the image angles from the equirectangular frames, and runs the PyCOLMAP reconstruction needed for Brush.
* `Brush.sh` selects the best COLMAP sparse model and runs Brush Gaussian Splatting training.

Scripts for Antigravity A1 with COLMAP
* `A1Exctract.sh` extracts sharp frames from the Antigravity A1 drone
* `Colmap.sh` Run COLMAP reconstruction needed for Brush.

Experimental scripts
* `Insta360Exctract.sh` extracts frames from any 360 camera.
* `Insta360PyExctract.sh` extracts per-view subfolders from any 360 camera for use with PyCOLMAP.
* `Insta360PyColmap.py` runs PyCOLMAP reconstruction for Insta360 rig captures using a full RigConfig.

## Gaussian Splatting with the Antigravity A1 using PyCOLMAP

1. Extract sharp frames in equirectangular format and diretory structure creation
```sh
~/clis/GaussianSplatting/Exctract.sh \
--scenedir ~/Desktop/Project \
--fps 3 \
~/Desktop/input.mov
```

2. Run COLMAP reconstruction using PyCOLMAP
```sh
~/clis/GaussianSplatting/A1PyColmap.py \
--scenedir ~/Desktop/Project
```

3. To automatically select best COLMAP sparse model and run Brush Gaussian Splatting training
```sh
~/clis/GaussianSplatting/Brush.sh \
--scenedir ~/Desktop/Project
```

After Brush finishes, you can load your `exports/export_30000.ply` file in https://superspl.at/editor

## Gaussian Splatting with the Insta360 cameras COLMAP

To extract frames from a 360 camera, inspired on Olli Huttunen's [360 camera rig positions and angles](https://youtu.be/N15E_0kZ1UM)

1. Frame extraction
```sh
# High position
~/clis/GaussianSplatting/Insta360Exctract.sh \
--scenedir ~/Desktop/Project \
--elevation high \
--fps 3 \
~/Desktop/high.mov

# Middle position
~/clis/GaussianSplatting/Insta360Exctract.sh \
--scenedir ~/Desktop/Project \
--elevation mid \
--fps 3 \
~/Desktop/mid.mov

# Low position
~/clis/GaussianSplatting/Insta360Exctract.sh \
--scenedir ~/Desktop/Project \
--elevation low \
--fps 3 \
~/Desktop/low.mov
```

2. COLMAP reconstruction
```sh
~/clis/GaussianSplatting/Colmap.sh \
--scenedir ~/Desktop/Project
```

3. To automatically select best COLMAP sparse model and run Brush Gaussian Splatting training
```sh
~/clis/GaussianSplatting/Brush.sh \
--scenedir ~/Desktop/Project
```

## Gaussian Splatting with the Insta360 cameras PyCOLMAP (Experimental)

1. Extract sharp frames into per-view subfolders (run once per camera position)
```sh
~/clis/GaussianSplatting/Insta360PyExctract.sh \
--scenedir ~/Desktop/Project \
--elevation high \
--fps 3 \
~/Desktop/high.mov

~/clis/GaussianSplatting/Insta360PyExctract.sh \
--scenedir ~/Desktop/Project \
--elevation mid \
--fps 3 \
~/Desktop/mid.mov

~/clis/GaussianSplatting/Insta360PyExctract.sh \
--scenedir ~/Desktop/Project \
--elevation low \
--fps 3 \
~/Desktop/low.mov
```

2. Run COLMAP reconstruction using PyCOLMAP
```sh
~/clis/GaussianSplatting/Insta360PyColmap.py \
--scenedir ~/Desktop/Project
```

3. To automatically select best COLMAP sparse model and run Brush Gaussian Splatting training
```sh
~/clis/GaussianSplatting/Brush.sh \
--scenedir ~/Desktop/Project
```

## Dependencies / Tools to install first

### Brush static binary (Simplest option)
```sh
# Create the directory if doesn't exists
mkdir -p ~/.local/bin

# Add the dir to the shell path if doesn't exists
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

# Download and uncompress Brush
curl -L https://github.com/ArthurBrussee/brush/releases/download/v0.3.0/brush-app-aarch64-apple-darwin.tar.xz \
  | tar xJf -

# Move brush to the bin dir
mv brush-app-aarch64-apple-darwin/brush_app ~/.local/bin/brush

# Remove the uncompressed folder
rm -rf brush-app-aarch64-apple-darwin
```

### Homebrew
We need Python, FFmpeg and other command line tools, for that, we first need to install `xcode` and Homebrew
```sh
# Xcode Command Line Tools (compiler, git, etc.)
xcode-select --install

# Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to the system $PATH
echo >> ~/.zprofile
echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv zsh)"
```

### Install the scripts in this repo
```sh
cd && git clone https://github.com/rodrigopolo/clis.git
echo '[[ -d $HOME/clis/bin ]] && export PATH="$HOME/clis/bin:$PATH"' >> ~/.zshrc
```

### FFmpeg, xz and Python
On macOS you'll need to have Python installed, a quick and reliable way to have
Python installed is `pyenv`, a Python version manager that lets you easily
install, switch between, and manage multiple Python versions, `pyenv` needs to
be installed with Homebrew:

```sh
brew install ffmpeg xz pyenv
```

Add `pyenv` and `pip` to the system $PATH
```sh
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(pyenv init - zsh)"' >> ~/.zshrc
```

> **Note:** You'll have to restart your terminal in order to continue with the next steps.

Now that we have `pyenv` installed, we have to install a `Python` version and
make it available systemwide:
```sh
pyenv install 3.12.9
pyenv global 3.12.9
pip install --upgrade pip
```

### Install Sharp frames, PyCOLMAP and dependencies
PyCOLMAP is the official Python bindings for COLMAP, used by `A1PyColmap.py` for photogrammetry reconstruction.
```sh
pip install Pillow scipy sharp-frames pycolmap
```

> **Note:** The Homebrew COLMAP (`brew install colmap`) is not required when using PyCOLMAP, it bundles its own COLMAP binaries.

## Extra notes and Direct commands

### Sharp frames
Extract and select the sharpest frames from videos or directories of images using advanced sharpness scoring algorithms.
```sh
sharp-frames \
  --fps 1 \
  input.mov \
  ./outputdir
```

###  Brush

```sh
# To run Brush Gaussian Splatting training
brush ./my_colmap_project \
  --total-steps 30000 \         # 30k is more than enough
  --max-splats 4000000 \        # Hard cap at 4M splats
  --max-resolution 2048 \       # Downsample input images
  --growth-stop-iter 15000 \    # Stop adding splats
  --sh-degree 3 \               # Lower SH degree = smaller file, less color detail
  --export-every 5000 \         # Just in case
  --export-path ./exports/

# To analyze the result
colmap model_analyzer --path ./sparse/0

# Convert the result to text
colmap model_converter \
  --input_path ./sparse/0 \
  --output_path ./sparse/0_txt \
  --output_type TXT

# To look the frames reference
cat ./sparse/0_txt/images.txt | grep -i jpg | awk '{print $10}'
```

### Compile Brush (Advanced option)

Install Rust
```sh
# Rust (via rustup, NOT via Homebrew)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env
```

```sh
git clone https://github.com/ArthurBrussee/brush.git
cargo test --all
cargo install rerun-cli
cargo run --release
```

> Repo: https://github.com/ArthurBrussee/brush.git

## Other tools

### Blender Photogrammetry Importer Add-on
https://github.com/SBCV/Blender-Addon-Photogrammetry-Importer/releases/tag/v2026.02.16
