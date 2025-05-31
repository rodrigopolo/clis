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

# Configuration
readonly CUBE_FACES=("Back" "Down" "Front" "Left" "Right" "Up")
FACE_PATHS=()

# Global variables for tool paths
NONA_PATH=""
VERDANDI_PATH=""
EXIFTOOL_PATH=""
FILES=()
FILE_OUTPUT=""
FILE_ORIGINAL=""

# Command line options
VERBOSE=0
YAW_180=0
SIZE_W=0
SIZE_H=0

# Function to show usage
usage() {
    echo -e "Usage:\n" \
        "  $0 [OPTIONS] Prefix_Back.tif\n\n" \
        "  $0 [OPTIONS] \ \n" \
        "     Prefix_Back.tif  \ \n" \
        "     Prefix_Down.tif  \ \n" \
        "     Prefix_Front.tif \ \n" \
        "     Prefix_Left.tif  \ \n" \
        "     Prefix_Right.tif \ \n" \
        "     Prefix_Up.tif\n\n" \
        "OPTIONS:\n" \
        "    -v, --verbose       Enable verbose output.\n" \
        "    -f, --flip-top      Top fliped 180 degrees.\n" \
        "    -s, --size          Modify the ouput size. (Ej: 4096x2048)\n" \
        "    -h, --help          Show this help message\n\n" \
        "The script can work in two modes:\n" \
        "  1. Single file mode: Provide any one cubemap face file\n" \
        "     - Script will auto-detect the prefix and find all other faces\n" \
        "     - Output will be named: Prefix_equirectangular.extension\n\n" \
        "  2. Multiple file mode: Provide all 6 cubemap face files\n" \
        "     - All files must share the same prefix and extension\n\n" \
        "Supported naming patterns:\n" \
        "  - With underscore: Prefix_Back.tif, Prefix_Front.tif, etc.\n" \
        "  - Without underscore: PrefixBack.tif, PrefixFront.tif, etc.\n\n" \
        "Required face names: Back, Down, Front, Left, Right, Up\n" \
        "All cubemap faces must be square images with identical dimensions.\n"
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
    local tools=("pano_modify" "hugin_executor" "magick")

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
                "nona"|"verdandi")
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
    # If 1024 multiple is within 3x the distance of the 16 multiple, prefer 1024
    local threshold=$((dist_to_16 * 3))  # 3x the distance to 16-multiple
    
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

# Function to find the original equirectangular file width
find_original() {
    local base_path="$1"
    local extensions=("tif" "TIF" "tiff" "TIFF")
    local ext path or_width

    for ext in "${extensions[@]}"; do
        path="${base_path}.${ext}"
        if [ -f "$path" ]; then
            if ! or_width=$(get_image_width "$path"); then
                return 1
            fi
            echo ${or_width}
            return 0
        fi
    done
    return 1
}

# Function to verify all cubemap faces have the same dimensions
verify_cubemap_dimensions() {
    local files=("$@")
    local reference_width
    local reference_height
    
    log "Verifying cubemap face dimensions..."
    
    # Get dimensions from first file as reference
    reference_width=$(get_image_width "${files[0]}")
    reference_height=$(exiftool -s -s -s -ImageHeight "${files[0]}" 2>/dev/null)
    
    if [[ -z "$reference_width" || -z "$reference_height" ]]; then
        error "Could not determine dimensions of reference image: ${files[0]}"
        return 1
    fi
    
    # Check if image is square (required for cubemap faces)
    if [[ "$reference_width" -ne "$reference_height" ]]; then
        error "Cubemap faces must be square. ${files[0]} is ${reference_width}x${reference_height}"
        return 1
    fi
    
    # Check all other files
    for file in "${files[@]:1}"; do
        local width height
        width=$(get_image_width "$file")
        height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null)
        
        if [[ "$width" != "$reference_width" || "$height" != "$reference_height" ]]; then
            error "Dimension mismatch: $file (${width}x${height}) vs reference (${reference_width}x${reference_height})"
            return 1
        fi
    done
    
    log "All cubemap faces have matching dimensions: ${reference_width}x${reference_height}"
    echo "$reference_width"
}

# Function to extract prefix from filename
extract_prefix() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    for pattern in "${CUBE_FACES[@]}"; do
        if [[ "$basename" == *"_${pattern}."* ]]; then
            # Extract everything before _Pattern.extension
            echo "${basename%%_${pattern}.*}"
            return 0
        elif [[ "$basename" == *"${pattern}."* && "$basename" != "${pattern}."* ]]; then
            # Handle case without underscore (e.g., PrefixBack.tif)
            echo "${basename%%${pattern}.*}"
            return 0
        fi
    done
    
    error "Could not extract prefix from filename: $filename"
    error "Filename must contain one of: Back, Down, Front, Left, Right, Up"
    return 1
}

# Function to build cubemap file paths
build_cubemap_paths() {
    local first_file="$1"
    local prefix extension directory index

    local input_full_path input_dir input_base input_ext input_name input_next

    input_full_path=$(realpath "$first_file")  # /path/to/file/Prefix_Back.tif
    input_dir=$(dirname "$input_full_path")    # /path/to/file
    input_base=$(basename "$input_full_path")  # Prefix_Back.tif
    input_ext="${input_base##*.}"              # tif
    input_name="${input_base%*.$input_ext}"    # Prefix_Back
    input_next="${input_dir}/${input_name}"    # /path/to/file/Prefix_Back

    # Extract components from first file
    prefix=$(extract_prefix "$first_file")    # Prefix
    if [[ $? -ne 0 ]]; then
        return 1
    fi

    FILE_ORIGINAL="${input_dir}/${prefix}"

    log "Detected prefix: '$prefix'"
    log "Detected extension: '$input_ext'"
    log "Base directory: '$input_dir'"
    
    # Build paths for all faces
    local separator
    
    # Determine separator (underscore or none) based on original filename
    if [[ "$input_base" == *"_"* ]]; then
        separator="_"
    else
        separator=""
    fi

    log "Generated file paths:"
    # Set global variables
    index=0
    for face in "${CUBE_FACES[@]}"; do
        FACE_PATHS[index]="${input_dir}/${prefix}${separator}${face}.${input_ext}"
        log "  ${face}: ${FACE_PATHS[index]}"
        ((index++))
    done

    # Generate output filename
    FILE_OUTPUT="${input_dir}/${prefix}_equirectangular.${input_ext}"
    log "  Output: $FILE_OUTPUT"
}

# Parse command line arguments
parse_args() {
    local files=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -f|--flip-top)
                YAW_180=1
                shift
                ;;
            -s|--size)
                if [[ -z "${2:-}" ]]; then
                    error "Size option requires a value"
                    usage
                    exit 1
                fi
                dim="$2"

                # Check if the size matches the pattern NUMBERxNUMBER
                if [[ ! $dim =~ ^[0-9]+x[0-9]+$ ]]; then
                    echo "Error: size must be in the format NUMBERxNUMBER (e.g., 4096x2048)"
                    exit 1
                fi

                # Extract the two numbers using parameter expansion or cut
                SIZE_W=${dim%x*}  # Get everything before 'x'
                SIZE_H=${dim#*x} # Get everything after 'x'

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
                # Collect remaining arguments as files
                files+=("$1")
                shift
                ;;
        esac
    done
    
    # Set the FILES array globally (handle empty array safely)
    if [[ ${#files[@]} -gt 0 ]]; then
        FILES=("${files[@]}")
    else
        FILES=()
    fi
}

# Create .PTO file
create_pto_file() {
    local width=$1 height=$2 tile_width=$3 udrot=$4 hugin_file=$5 index

    index=0
    for face in "${CUBE_FACES[@]}"; do
        declare "face_${face}"="${FACE_PATHS[index]}"
        ((index++))
    done

    # Write .pto file
    cat > "${hugin_file}" << EOF
p f2 w${width} h${height} v360  k0 E0 R0 n"TIFF_m c:LZW r:CROP"
m i0

i w${tile_width} h${tile_width} f0 v90 Ra0 Rb0 Rc0 Rd0 Re0 Eev0 Er1 Eb1 r0 p0 y180 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a0 b0 c0 d0 e0 g0 t0 Va1 Vb0 Vc0 Vd0 Vx0 Vy0  Vm5 n"${face_Back}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y0 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_Front}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p-90 y${udrot} TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_Down}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y-90 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_Left}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y90 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_Right}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p90 y${udrot} TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_Up}"

v Ra0
v Rb0
v Rc0
v Rd0
v Re0
v Vb0
v Vc0
v Vd0
v Eev1
v r1
v p1
v y1
v Eev2
v r2
v p2
v y2
v Eev3
v r3
v p3
v y3
v Eev4
v r4
v p4
v y4
v Eev5
v r5
v p5
v y5
v
EOF

    # Check if file was created successfully
    if [ $? -eq 0 ] && [ -f "$hugin_file" ]; then
        echo "Successfully created $hugin_file" >&2
        return 0
    else
        echo "Error: Failed to create $hugin_file" >&2
        return 1
    fi
}

# Main execution
main() {
    local tile_width output_dir hugin_file pi_times_width pi width height
    
    # Parse command line arguments (modifies global variables directly)
    parse_args "$@"

    # Validate input
    if [[ ${#FILES[@]} -lt 1 ]]; then
        error "No input files specified"
        usage
        exit 1
    elif [[ ${#FILES[@]} -gt 6 ]]; then
        error "Invalid number of arguments: ${#FILES[@]}"
        error "Provide either 1 file (auto-detect mode) or all 6 cubemap faces"
        usage
        exit 1
    else
       log "Detecting all faces from prefix"
       if ! build_cubemap_paths "${FILES[0]}"; then
           exit 1
       fi
    fi

    # Check dependencies
    echo "Checking required dependencies..." >&2
    if ! check_dependencies; then
        exit 1
    fi

    # Get tool paths
    NONA_PATH=$(find_tool "nona")
    VERDANDI_PATH=$(find_tool "verdandi")
    EXIFTOOL_PATH=$(find_tool "exiftool")

    # Create a temporary directory
    TEMP_DIR=$(mktemp -d)
    log "Created temporary directory: $TEMP_DIR"

    # Ensure the directory is deleted when the script exits (success or failure)
    trap 'log "Cleaning up temporary directory: $TEMP_DIR"; rm -rf "$TEMP_DIR"' EXIT

    hugin_file="${TEMP_DIR}/pano.pto"

    echo "Validating input files..." >&2
    for file in "${FACE_PATHS[@]}"; do
        if ! validate_image_file "$file"; then
            exit 1
        fi
    done

    # Verify cubemap dimensions and get tile width
    tile_width=$(verify_cubemap_dimensions "${FACE_PATHS[@]}")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    log "Cubemap face size: ${tile_width}x${tile_width}"

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
    elif SIZE_W=$(find_original "${FILE_ORIGINAL}"); then
        # From the original file
        width=${SIZE_W}
        log "Size from original file."
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

    # 180 degree rotation in case of a Facebook pano
    if [[ $YAW_180 -eq 1 ]]; then
        udrot=180
        log "Fliping panorama orientation (180° yaw)"
    else
        udrot=0
    fi

    log "Creating Hugin project file..."
    create_pto_file $width $height $tile_width $udrot $hugin_file

    # Change to temp directory for processing
    cd "${TEMP_DIR}" || { error "Failed to change to temp directory"; exit 1; }

    # Prepare sides for stitching
    log "Stitching cubemap faces with nona..."
    if ! "$NONA_PATH" -v -o pano -m TIFF_m -z LZW "${hugin_file}"; then
        error "nona failed to stitch images"
        exit 1
    fi

    # Verify nona output files exist
    pano_files=()
    for i in {0..5}; do
        pano_file="${TEMP_DIR}/pano000${i}.tif"
        if [[ ! -f "$pano_file" ]]; then
            error "Expected output file missing: $pano_file"
            exit 1
        fi
        pano_files+=("$pano_file")
    done

    # Blend the images
    log "Blending images with verdandi..."
    if ! "$VERDANDI_PATH" "${pano_files[@]}" -o "${FILE_OUTPUT}"; then
        error "verdandi failed to blend images"
        exit 1
    fi

    # Verify output file was created
    if [[ ! -f "$FILE_OUTPUT" ]]; then
        error "Output file was not created: $FILE_OUTPUT"
        exit 1
    fi

    log "Conversion completed successfully!"
    log "Output file: $FILE_OUTPUT"

}

# Run main function with all arguments
main "$@"
