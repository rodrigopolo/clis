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

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Global variables for tool paths
NONA_PATH=""
EXIFTOOL_PATH=""
DOWN_FILE=""
FILE_OUTPUT=""

# Command line options
VERBOSE=0
SIZE_W=0
SIZE_H=0

# Function to show usage
usage() {
    cat << EOF >&2
Usage:
  $(basename "$0") [OPTIONS] Prefix_Down.tif

OPTIONS:
    -v, --verbose       Enable verbose output.
    -s, --size          Modify the output size. (Ex: 4096x2048)
    -h, --help          Show this help message

The script converts a single Down cubemap face to an equirectangular projection.

Supported naming patterns:
  - With underscore: Prefix_Down.tif
  - Without underscore: PrefixDown.tif

The Down face must be a square image.
Output will be named: Prefix_equirectangular_down.extension

EOF
}

# Verbose logging function
log() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "[$(date '+%H:%M:%S')] $*" >&2
    fi
}

# Error logging function
error() {
    echo "[ERROR] $*" >&2
}

# Function to find tool in common locations
find_tool() {
    local tool_name="$1"
    local tool_path=""
    
    # Common locations to check
    local common_paths=(
        "/usr/bin/${tool_name}"
        "/usr/local/bin/${tool_name}"
        "$HOME/.local/bin/${tool_name}"
        "/opt/homebrew/bin/${tool_name}"
        "/Applications/Hugin/tools_mac/${tool_name}"
    )
    
    # First check if it's in PATH
    if command -v "$tool_name" >/dev/null 2>&1; then
        tool_path=$(command -v "$tool_name")
        log "Found $tool_name in PATH: $tool_path"
        echo "$tool_path"
        return 0
    fi
    
    # Then check common installation paths
    for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
            log "Found $tool_name at: $path"
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Function to check required tools
check_dependencies() {
    local missing_tools=()
    local tools=("nona" "exiftool")

    for tool in "${tools[@]}"; do
        if ! find_tool "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Installation suggestions:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                "exiftool")
                    echo -e  "  - Install ExifTool:\n    brew install exiftool" >&2
                    ;;
                "nona")
                    echo -e  "  - Install Hugin:\n    https://github.com/rodrigopolo/clis/tree/main/360#dependencies" >&2
                    ;;
            esac
        done
        return 1
    fi
    
    log "All dependencies found"
    return 0
}

# Rounds to nearest 1024 or 16
smart_round() {
    local input="$1"
    
    # Convert to integer (truncate decimals)
    local num=$(echo "$input" | cut -d'.' -f1)
    
    # Find the next multiple of 16
    local remainder_16=$((num % 16))
    local next_16
    if [ $remainder_16 -eq 0 ]; then
        next_16=$num
    else
        next_16=$((num + 16 - remainder_16))
    fi
    
    # Find the closest multiple of 1024 (could be up or down)
    local remainder_1024=$((num % 1024))
    local lower_1024=$((num - remainder_1024))
    local upper_1024=$((lower_1024 + 1024))
    
    # Determine which 1024 multiple is closer
    local dist_to_lower=$remainder_1024
    local dist_to_upper=$((1024 - remainder_1024))
    
    local closest_1024
    if [ $dist_to_lower -le $dist_to_upper ]; then
        closest_1024=$lower_1024
    else
        closest_1024=$upper_1024
    fi
    
    # Calculate distances
    local dist_to_16=$((next_16 - num))
    local dist_to_1024
    if [ $closest_1024 -ge $num ]; then
        dist_to_1024=$((closest_1024 - num))
    else
        dist_to_1024=$((num - closest_1024))
    fi
    
    # Choose with relaxed threshold favoring 1024 multiples
    local threshold=$((dist_to_16 * 3))
    
    if [ $dist_to_1024 -le $threshold ]; then
        echo $closest_1024
    else
        echo $next_16
    fi
}

# Function to validate image files
validate_image_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        error "File does not exist: $file"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        error "File is not readable: $file"
        return 1
    fi
    
    # Check if it's a valid image file
    if ! exiftool -q -q "$file" >/dev/null 2>&1; then
        error "File is not a valid image: $file"
        return 1
    fi
    
    return 0
}

# Function to get image dimensions with error handling
get_image_width() {
    local file="$1"
    local width
    
    width=$(exiftool -s -s -s -ImageWidth "$file" 2>/dev/null)
    
    if [[ -z "$width" || ! "$width" =~ ^[0-9]+$ ]]; then
        error "Could not determine width of image: $file"
        return 1
    fi
    
    echo "$width"
}

# Function to verify Down face is square
verify_down_face() {
    local file="$1"
    local width height
    
    log "Verifying Down face dimensions..."
    
    width=$(get_image_width "$file")
    height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null)
    
    if [[ -z "$width" || -z "$height" ]]; then
        error "Could not determine dimensions of image: $file"
        return 1
    fi
    
    # Check if image is square (required for cubemap faces)
    if [[ "$width" -ne "$height" ]]; then
        error "Down face must be square. $file is ${width}x${height}"
        return 1
    fi
    
    log "Down face dimensions verified: ${width}x${width}"
    echo "$width"
}

# Function to extract prefix from Down face filename
extract_prefix() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    if [[ "$basename" == *"_Down."* ]]; then
        # Extract everything before _Down.extension
        echo "${basename%%_Down.*}"
        return 0
    elif [[ "$basename" == *"Down."* && "$basename" != "Down."* ]]; then
        # Handle case without underscore (e.g., PrefixDown.tif)
        echo "${basename%%Down.*}"
        return 0
    fi
    
    error "Could not extract prefix from filename: $filename"
    error "Filename must contain 'Down' (e.g., Prefix_Down.tif or PrefixDown.tif)"
    return 1
}

# Function to build output path
build_output_path() {
    local down_file="$1"
    local prefix extension directory
    
    local input_full_path input_dir input_base input_ext
    
    input_full_path=$(realpath "$down_file")
    input_dir=$(dirname "$input_full_path")
    input_base=$(basename "$input_full_path")
    input_ext="${input_base##*.}"
    
    # Extract prefix
    prefix=$(extract_prefix "$down_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    log "Detected prefix: '$prefix'"
    log "Detected extension: '$input_ext'"
    log "Base directory: '$input_dir'"
    
    # Generate output filename
    FILE_OUTPUT="${input_dir}/${prefix}_equirectangular_down.${input_ext}"
    log "Output file: $FILE_OUTPUT"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -s|--size)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Size option requires a value"
                    exit 1
                fi
                dim="$2"

                # Check if the size matches the pattern NUMBERxNUMBER
                if [[ ! $dim =~ ^[0-9]+x[0-9]+$ ]]; then
                    echo "Error: size must be in the format NUMBERxNUMBER (e.g., 4096x2048)"
                    exit 1
                fi

                # Extract the two numbers
                SIZE_W=${dim%x*}
                SIZE_H=${dim#*x}

                # Check if height is half of width
                expected_height=$((SIZE_W / 2))
                if [ "$SIZE_H" -ne "$expected_height" ]; then
                    echo "Error: height ($SIZE_H) must be half of width ($SIZE_W), expected $expected_height."
                    exit 1
                fi
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                # This should be the Down face file
                if [[ -n "$DOWN_FILE" ]]; then
                    error "Only one Down face file can be specified"
                    usage
                    exit 1
                fi
                DOWN_FILE="$1"
                shift
                ;;
        esac
    done
}

# Create .PTO file for Down face only
create_pto_file() {
    local width=$1 height=$2 tile_width=$3 hugin_file=$4
    
    # Write .pto file with only the Down face
    cat > "${hugin_file}" << EOF
p f2 w${width} h${height} v360  k0 E0 R0 n"TIFF_m c:LZW r:CROP"
m i0

i w${tile_width} h${tile_width} f0 v90 Ra0 Rb0 Rc0 Rd0 Re0 Eev0 Er1 Eb1 r0 p-90 y0 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a0 b0 c0 d0 e0 g0 t0 Va1 Vb0 Vc0 Vd0 Vx0 Vy0  Vm5 n"${DOWN_FILE}"

v Ra0
v Rb0
v Rc0
v Rd0
v Re0
v Vb0
v Vc0
v Vd0
v
EOF

    # Check if file was created successfully
    if [ $? -eq 0 ] && [ -f "$hugin_file" ]; then
        log "Successfully created $hugin_file"
        return 0
    else
        error "Failed to create $hugin_file"
        return 1
    fi
}

# Main execution
main() {
    local tile_width output_dir hugin_file pi_times_width pi width height
    
    # Parse command line arguments
    parse_args "$@"

    # Validate input
    if [[ -z "$DOWN_FILE" ]]; then
        usage
        error "No Down face file specified"
        exit 1
    fi

    # Build output path
    if ! build_output_path "$DOWN_FILE"; then
        exit 1
    fi

    # Check dependencies
    echo "Checking required dependencies..." >&2
    if ! check_dependencies; then
        exit 1
    fi

    # Get tool paths
    NONA_PATH=$(find_tool "nona")
    EXIFTOOL_PATH=$(find_tool "exiftool")

    # Create a temporary directory
    TEMP_DIR=$(mktemp -d)  
    log "Created temporary directory: $TEMP_DIR"

    # Ensure the directory is deleted when the script exits
    trap 'log "Cleaning up temporary directory: $TEMP_DIR"; rm -rf "$TEMP_DIR"' EXIT

    hugin_file="${TEMP_DIR}/pano.pto"

    echo "Validating Down face file..." >&2
    if ! validate_image_file "$DOWN_FILE"; then
        exit 1
    fi

    # Verify Down face dimensions and get tile width
    tile_width=$(verify_down_face "$DOWN_FILE")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    log "Down face size: ${tile_width}x${tile_width}"

    # Check if output directory is writable
    output_dir=$(dirname "$FILE_OUTPUT")
    if [[ ! -w "$output_dir" ]]; then
        error "Output directory is not writable: $output_dir"
        exit 1
    fi

    # Get the dimensions
    if [ "$SIZE_W" -gt 0 ]; then
        # If the size is defined in the arguments
        width=${SIZE_W}
        log "Size from arguments."
    else
        # Calculate
        log "Calculating output dimensions..."
        if ! pi=$(echo "scale=10; 4*a(1)" | bc -l); then
            error "Failed to calculate pi"
            exit 1
        fi

        # Calculate width using pi * tile_width
        pi_times_width=$(echo "scale=2; $pi * $tile_width" | bc -l)
        if [[ -z "$pi_times_width" ]]; then
            error "Failed to calculate pi * tile_width"
            exit 1
        fi

        width=$(smart_round "$pi_times_width")
        if [[ $? -ne 0 || -z "$width" ]]; then
            error "Failed to calculate output width"
            exit 1
        fi
    fi

    height=$(echo "scale=0; $width / 2" | bc -l)
    if [[ -z "$height" ]]; then
        error "Failed to calculate output height"
        exit 1
    fi

    log "Output dimensions: ${width}x${height}"

    log "Creating Hugin project file for Down face..."
    create_pto_file $width $height $tile_width $hugin_file

    # Change to temp directory for processing
    cd "${TEMP_DIR}" || { error "Failed to change to temp directory"; exit 1; }

    # Process the Down face
    log "Processing Down face with nona..."
    if ! "$NONA_PATH" -v -z LZW -r ldr -m TIFF_m -o Pano "${hugin_file}"; then
        error "nona failed to process Down face"
        exit 1
    fi

    mv "Pano0000.tif" "${FILE_OUTPUT}"

    # Verify output file was created
    if [[ ! -f "$FILE_OUTPUT" ]]; then
        error "Output file was not created: $FILE_OUTPUT"
        exit 1
    fi

    log "Conversion completed successfully!"
    echo "Output file: $FILE_OUTPUT"

    log "Cleaning up temporary directory: $TEMP_DIR"
    rm -rf "$TEMP_DIR"

    # Disable the trap to prevent it from running on script exit or interruption
    trap - EXIT
}

# Run main function with all arguments
main "$@"