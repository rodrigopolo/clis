#!/usr/bin/env bash

# Copyright (c) 2025 Rodrigo Polo
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

#!/bin/bash

# Exit on undefined variables
set -u

# Modifying the internal field separator
IFS=$'\t\n'

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to find nona executable
find_nona() {
    local tool_name="nona"
    local nona_paths=(
        "/Applications/Hugin/tools_mac/${tool_name}"
        "/opt/homebrew/bin/${tool_name}"
        "$HOME/.local/bin/${tool_name}"
        "/usr/local/bin/${tool_name}"
        "/usr/bin/${tool_name}"
    )
    
    for path in "${nona_paths[@]}"; do
        if command_exists "$path" || [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Check required dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for exiftool
    if ! command_exists "exiftool"; then
        missing_deps+=("exiftool")
    fi
    
    # Check for bc
    if ! command_exists "bc"; then
        missing_deps+=("bc")
    fi
    
    # Check for nona
    if ! NONA_PATH=$(find_nona); then
        missing_deps+=("nona (Hugin/PTBatcherGUI)")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install the missing tools and try again." >&2
        exit 1
    fi
    
    echo "Using nona at: $NONA_PATH"
}

# Check if the script has received an argument
if [[ "$#" -lt 1 ]]; then
    echo "Usage: $(basename "$0") <pano1.tif> <pano2.tif>..." >&2
    echo "Converts equirectangular panoramic images to cube face images." >&2
    exit 1
fi

# Check dependencies before proceeding
check_dependencies

# Divisor calc
round_to_closest_divisor() {
    local number=$1
    local divisor=$2

    # Ensure both inputs are valid
    if [[ -z "$number" || -z "$divisor" || "$divisor" -eq 0 ]]; then
        echo "Error: Invalid input. Usage: round_to_closest_divisor <number> <divisor>" >&2
        return 1
    fi

    # Calculate the rounded value using integer arithmetic when possible
    local half_divisor=$(echo "$divisor / 2" | bc)
    local rounded=$(echo "scale=0; (($number + $half_divisor) / $divisor) * $divisor" | bc)

    echo "$rounded"
}

# PI calculation
readonly PI=$(echo "scale=10; 4*a(1)" | bc -l)

# Arrays - reordered to match typical cube face conventions
readonly SIDE=("Down" "Up" "Back" "Front" "Left" "Right")
readonly R=("-88.244968578448" "26.9094996026837" "0" "0" "0" "0")
readonly P=("90" "-90" "0" "0" "0" "0")
readonly Y=("-88.244968578448" "-26.9094996026837" "180" "-1.14499968532687e-13" "89.9999999999999" "-90.0000000000001")

# Function to create PTO file and process cube face
create_pto() {
    local input_file="$1"
    local width="$2"
    local height="$3"
    local cubeface_size="$4"
    local orientation="$5"
    local r="$6"
    local p="$7"
    local y="$8"

    # Set the prefix based on the input filename
    local prefix="${input_file%.*}"
    local output="${prefix}_${orientation}.tif"

    echo "Creating \"${output}\""

    # Create a temporary directory
    local temp_dir
    if ! temp_dir=$(mktemp -d); then
        echo "Error: Cannot create temporary directory. Skipping $orientation..." >&2
        return 1
    fi

    # Set trap to clean up the temporary directory on exit
    trap 'rm -rf "$temp_dir"' EXIT

    # Create PTO file content
    local header="p f0 w${cubeface_size} h${cubeface_size} v90  k0 E0 R0 n\"TIFF_m c:LZW r:CROP\"\nm i0\n"
    local footer="v Ra0\nv Rb0\nv Rc0\nv Rd0\nv Re0\nv Vb0\nv Vc0\nv Vd0\nv\n"
    local image_line="i w${width} h${height} f4 v360 Ra0 Rb0 Rc0 Rd0 Re0 Eev0 Er1 Eb1 r${r} p${p} y${y} TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a0 b0 c0 d0 e0 g0 t0 Va1 Vb0 Vc0 Vd0 Vx0 Vy0  Vm5 n\"${input_file}\"\n"
    
    echo -e "${header}${image_line}${footer}" > "${temp_dir}/${orientation}.pto"

    # Run nona
    if ! "$NONA_PATH" -v -o "$output" -m TIFF -z LZW "${temp_dir}/${orientation}.pto" 2>/dev/null; then
        echo "Error: nona processing failed for ${orientation} face. Skipping..." >&2
        return 1
    fi

    # Manually delete the temporary directory
    rm -rf "$temp_dir"
    
    # Disable the trap to prevent it from running on script exit or interruption
    trap - EXIT

    return 0
}

# Process each input file
for input_file in "$@"; do
    echo "Processing: $input_file"

    # Check if the file exists and is readable
    if [[ ! -f "$input_file" ]]; then
        echo "Error: File $input_file does not exist. Skipping..." >&2
        continue
    fi

    if [[ ! -r "$input_file" ]]; then
        echo "Error: File $input_file is not readable. Skipping..." >&2
        continue
    fi

    # Extract dimensions and validate
    if ! height=$(exiftool -s -s -s -ImageHeight "$input_file" 2>/dev/null); then
        echo "Error: Could not extract image height from $input_file. Skipping..." >&2
        continue
    fi

    if ! width=$(exiftool -s -s -s -ImageWidth "$input_file" 2>/dev/null); then
        echo "Error: Could not extract image width from $input_file. Skipping..." >&2
        continue
    fi

    # Validate dimensions are numeric
    if ! [[ "$height" =~ ^[0-9]+$ ]] || ! [[ "$width" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid image dimensions for $input_file (width: $width, height: $height). Skipping..." >&2
        continue
    fi

    # Calculate cube face size
    if ! cubeface_size=$(round_to_closest_divisor "$(echo "scale=10; ($width / $PI)" | bc)" 16); then
        echo "Error: Could not calculate cube face size for $input_file. Skipping..." >&2
        continue
    fi

    echo "Image dimensions: ${width}x${height}, Cube face size: ${cubeface_size}"

    # Process each cube face
    success_count=0
    for i in "${!SIDE[@]}"; do
        if create_pto "$input_file" "$width" "$height" "$cubeface_size" "${SIDE[i]}" "${R[i]}" "${P[i]}" "${Y[i]}"; then
            ((success_count++))
        fi
    done

    if [[ $success_count -eq ${#SIDE[@]} ]]; then
        echo "Successfully processed all faces for $input_file"
    else
        echo "Warning: Only $success_count out of ${#SIDE[@]} faces processed successfully for $input_file" >&2
    fi
    
    echo "---"
done

echo "Processing complete."