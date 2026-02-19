#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $(basename "$0") <video1> [video2] ..."
  exit 1
fi

for file in "$@"; do
  if [[ ! -f "$file" ]]; then
    echo "Skipping: '$file' (not found)"
    continue
  fi

  echo "Processing: '$file'"
  exiftool \
    -XMP-GSpherical:Spherical=true \
    -XMP-GSpherical:Stitched=true \
    -XMP-GSpherical:ProjectionType=equirectangular \
    -XMP-GSpherical:StereoMode=mono \
    -XMP-GSpherical:SourceCount=2 \
    -XMP-GSpherical:StitchingSoftware="Insta360" \
    -overwrite_original \
    "$file" && echo "Done: '$file'" || echo "Failed: '$file'"
done

