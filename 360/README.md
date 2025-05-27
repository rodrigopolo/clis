# 360° Panorama Scripts

* Convert `tif` to cubemap using `tocubemap.sh`.
* Convert from cubemap to equirectangular with `toequirectangular.sh`.
* Set the geolcation with `setlocation`.
* Add the 360° panorama metadata with `add360metadata.sh`.
* Convert to `jpg` with `tojpg.sh`.
* Convert to `jpg` considering Facebook's max size with `tofacebookjpg.sh`.

A collection of scripts to handle 360° panoramas in batch with ExifTool,
ImageMagick and Hugin's `nona`, and `verdandi` CLIs.Check dependencies at the
end.

## `tocubemap.sh`

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

## `toequirectangular.sh`

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

## `add360metadata.sh`
Using `exiftool`, adds the necessary metadata to the `tif` file to be
interpreted as a 360° panorama. It overwrites the original file:
```sh
./add360metadata.sh Panorama.tif
```

## Geolocation
To set the geolocation of the `tif` file, you can look for the location in
Google Maps, then right-click on the place and select the decimal latitude
and longitude. It will be copied to the clipboard. Then, using the `setlocation`
tool provided in this repo's `bin` directory, call the command, paste the
location, and set the path to the `tif` file:
```sh
setlocation 14.596657575332861, -90.52320360681493 Panorama.tif
```

## Convert to JPG
```sh
./tojpg.sh Panorama.tif
```

## Convert to maximum allowed dimensions for Facebook
```sh
./tofacebookjpg.sh Panorama.tif
```

### Alternative to `tocubemap.sh`
A faster alternative is `kubi`, a cubemap generator based on `libvips`. In fact,
it is 4.9x faster than Hugin's `nona`, but lacks the possibility to do the
process in reverse, and doesn't calculate the output image size automatically.
To install on macOS with `conda`:

```sh
brew install vips
pip uninstall pyvips # Just in case
conda install conda-forge::pyvips
```

And to produce the same results as with `tocubemap.sh`:
```sh
kubi -s 6848 -f Right Left Up Down Front Back Panorama.tif Panorama
```
[More about `kubi`](https://github.com/indus/kubi)

## Dependencies
* [Hugin](https://bitbucket.org/Dannephoto/hugin/downloads/) app, download and
  install manually from Dannephoto repo.
* [Homebrew](https://brew.sh/), The Missing Package Manager for macOS.
* Arbitrary precision numeric processing language 
  [`bc`](https://formulae.brew.sh/formula/bc), install using Homebrew.
* Perl lib for reading and writing EXIF metadata
  [`exiftool`](https://formulae.brew.sh/formula/exiftool), install using
  Homebrew.

Installing brew dependencies:
```sh
brew install exiftool imagemagick bc
```