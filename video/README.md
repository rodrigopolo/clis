# Video Encoding Scripts

* `encoding_test.sh`: Tests different presets and CRF values, capturing performance metrics.
* `analyze_quality.sh`: Analyzes encoded videos against the original using VMAF, SSIM, PSNR, and MS-SSIM.
* `hevc.sh`: For video encoding to HEVC/H.265, run it with the `-h` flag to see options.


### `hevc.sh`
This script is a wrapper for `FFmpeg` that performs many tasks quite easily.

* If installed, it uses `ffpb` instead `FFmpeg` to display a progress bar.
* Handles multiple files at once.
* Manages multiple audio tracks automatically, capable of handling videos without audio and with multiple mono, stereo, 5.1, 7.1, etc. tracks, encoding everything to AAC.
* Performs actions after encoding: It checks if the encoded file's duration matches the original; if it does, it can rename, tag with a macOS color, or delete the original file.
* Offers an option to resize multiple videos to a maximum width and height, handling vertical videos with the same specifications.
* Copies file attributes from the original video file to the newly encoded file (file dates, permissions, macOS comments, and color tags).
* Provides a simple way to handle rotation and flipping, with options: `right`, `left`, `upside-down`, `horizontal`, and `vertical`.
* Supports quiet or verbose output, ideal for reviewing the encoding settings.
* Checks for dependencies and reports any missing installations.


Check all available options by typing:
```sh
./hevc.sh -h
```

To display a progress bar instead of the typical `FFmpeg` output, first install Python, instructions in the `READM` of this repo, then, install `ffpb`:
```sh
pip install --user ffpb
```
