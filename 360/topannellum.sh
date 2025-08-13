#!/usr/bin/env bash

# Copyright (c) 2024 Rodrigo Polo
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

# Side names and cube dimensions (immutable arrays)
readonly sides=("Left" "Front" "Right" "Back" "Up" "Down")
readonly sides_short=("l" "f" "r" "b" "u" "d")
readonly cubes=(16384 8192 4096 2048 1024 512)

# Divisor calc
round_to_closest_divisor() {
    local number=$1
    local divisor=$2

    # Ensure both inputs are valid
    if [[ -z "$number" || -z "$divisor" || "$divisor" -eq 0 ]]; then
        echo "Error: Invalid input. Usage: round_to_closest_divisor <number> <divisor>"
        return 1
    fi

    # Calculate the rounded value
    local half_divisor=$(echo "$divisor / 2" | bc)
    local rounded=$(echo "scale=0; (($number + $half_divisor) / $divisor) * $divisor" | bc)

    echo "$rounded"
}

# Script description and usage
usage() {
    echo "Usage: $(basename "$0") <input_equirectangular_image>" >&2
    exit 1
}

# Logging function
log() {
    echo -e "[$(date '+%H:%M:%S')] $*" >&2
}

# Error handling function
error() {
    echo "[ERROR] $*" >&2
    exit 1
}

# Trap to clean up temporary files in case of script interruption
cleanup() {
    local prefix=$1
    log "Cleaning up temporary files..."
    for side in "${sides[@]}"; do
        [[ -f "${prefix}_${side}.tif" ]] && rm "${prefix}_${side}.tif"
    done
}

# Global Cubeset
declare -a globalCubeset

# Function to calculate mosaic size
get_mosaic_size() {
    local -r imageDim=$(round_to_closest_divisor $1 512)
    globalCubeset=()  # Reset the array
    for size in "${cubes[@]}"; do
        if [[ $imageDim -ge $size ]]; then
            globalCubeset+=( "$size" )
        fi
    done
}

# Resolve symlinks and get real path of files
get_real_path() {
    local target_file="$1"

    # Check if file exists
    if [[ ! -e "$target_file" ]]; then
        echo "Error: File $target_file does not exist." >&2
        return 1
    fi

    # Remove any trailing slashes from the target file name
    target_file="${target_file%/}"

    local physical_dir
    local physical_file

    # Start from the directory of the target file
    cd "$(dirname "$target_file")" || { echo "Failed to change directory to $(dirname "$target_file")" >&2; return 1; }
    target_file=$(basename "$target_file")

    # Follow symbolic links
    while [[ -L "$target_file" ]]; do
        target_file=$(readlink "$target_file")
        cd "$(dirname "$target_file")" || { echo "Failed to change directory to $(dirname "$target_file")" >&2; return 1; }
        target_file=$(basename "$target_file")
    done

    # Get the fully resolved physical path
    physical_dir=$(pwd -P)
    physical_file="$physical_dir/$target_file"

    echo "$physical_file"
}

# Create set of mosaic tiles
create_set() {
    local level=$1
    local size=$2
    local root=$3
    local levelpath="${root}/${level}"
    local square=$((size / 512))

    # Validate inputs
    [[ -z $level || -z $size || -z $root ]] && error "Invalid arguments to create_set"

    # Create set directory
    log "Creating level ${level} for \"${size}x${size}\" cube."
    mkdir -p "$levelpath"

    # Process each side of the cube
    for i in "${!sides[@]}"; do
        local input="${prefix}_${sides[i]}.tif"
        local resized="${levelpath}/${sides_short[i]}.tif"
        local mosaic="${levelpath}/${sides_short[i]}"

        # Validate input file exists
        [[ ! -f $input ]] && error "Input file ${input} does not exist"

        # Resize
        log "Resizing and creating \"${sides[i]}\" face to \"${size}x${size}\" for level ${level}"
        magick "$input" -resize "${size}x${size}" "$resized"

        # Create mosaic
        #log "Creating mosaic for \"${sides[i]}\" face for level ${level}"
        magick "$resized" -crop 512x512 +repage +adjoin -quality 90 "${mosaic}%d.jpg"

        # Remove resized face
        rm "$resized"

        # Rename files with row and column
        for ((row=0; row<square; row++)); do
            for ((col=0; col<square; col++)); do
                local item=$(((row) * square + col))
                mv "${mosaic}${item}.jpg" "${mosaic}_${row}_${col}.jpg"
            done
        done
    done

    echo "Mosaic set for level ${level} created successfully"
}

# Main script execution
main() {
    # Get real path of input file
    local input_file
    input_file=$(get_real_path "$1")

    # Get the directory of the current script
    local script_dir
    script_dir="$(dirname "$(readlink -f "$0")")"

    # Get directory and prefix
    local dir prefix bname
    dir=$(dirname "$input_file")
    prefix="${input_file%.*}"
    bname=$(basename "$prefix")

    # Create output directory
    log "Creating \"${prefix}\" directory"
    mkdir -p "$prefix"

    # Set trap for cleanup
    trap "cleanup \"${prefix}\"" EXIT

    # Convert to cubemap
    log "Converting to cubemap"
    "$script_dir/kubi.sh" "$input_file"

    # Get cube dimensions
    local cubesize
    cubesize=$(exiftool -T -ImageWidth "${prefix}_${sides[0]}.tif")

    # Calculate mosaic sizes
    get_mosaic_size "$cubesize"

    # Create each cube set
    local levelcounter=0
    for ((i=${#globalCubeset[@]}-1; i>=0; i--)); do
        ((levelcounter++))
        echo $(create_set "$levelcounter" "${globalCubeset[i]}" "$prefix")
    done

    log "Applying template"
    templateTitle=$(basename "$prefix")
    templateCubeResolution="${globalCubeset[0]}"
    templateLevels=${#globalCubeset[@]}

    cat "$script_dir/Templates/Pannellum.template" | \
    sed 's:${TITLE}:'$templateTitle':' | \
    sed 's:${CUBERES}:'$templateCubeResolution':' | \
    sed 's:${MAXLEVEL}:'$templateLevels':' > "${prefix}/index.html"

    # Copying template assets
    cp -r "$script_dir/Templates/pannellum_assets" "${prefix}"

    log "Creating zip file"
    cd "$dir"
    # Zip without macos fot files
    zip \
    -r "${bname}.zip" \
    ${bname} \
    -x "${bname}/.*"

    # Manually delete the temporary directory
    cleanup "${prefix}"

    # Disable the trap to prevent it from running on script exit or interruption
    trap - EXIT

    log "Processing complete"
}

# Modifying the internal field separator
IFS=$'\t\n'

# Validate input
if [[ $# -lt 1 ]]; then
    usage
fi

for f in $@; do
    main "$f"
done




