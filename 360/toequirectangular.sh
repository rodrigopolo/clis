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

#  Usage:
#    toequirectangular.sh Prefix_Back.tif
#    OR
#    toequirectangular.sh Prefix_Back.tif Prefix_Down.tif Prefix_Front.tif Prefix_Left.tif Prefix_Right.tif Prefix_Up.tif


# Function to show usage
show_usage() {
    echo "Usage:"
    echo "  $0 Prefix_Back.tif"
    echo "  $0 Prefix_Back.tif Prefix_Down.tif Prefix_Front.tif Prefix_Left.tif Prefix_Right.tif Prefix_Up.tif"
    echo ""
    echo "The script can work in two modes:"
    echo "  1. Single file mode: Provide any one cubemap face file"
    echo "     - Script will auto-detect the prefix and find all other faces"
    echo "     - Output will be named: Prefix_equirectangular.extension"
    echo ""
    echo "  2. Multiple file mode: Provide all 6 cubemap face files"
    echo "     - All files must share the same prefix and extension"
    echo ""
    echo "Supported naming patterns:"
    echo "  - With underscore: Prefix_Back.tif, Prefix_Front.tif, etc."
    echo "  - Without underscore: PrefixBack.tif, PrefixFront.tif, etc."
    echo ""
    echo "Required face names: Back, Down, Front, Left, Right, Up"
    echo "All cubemap faces must be square images with identical dimensions."
}


#set -euo pipefail  # Exit on error, undefined vars, and pipe failures

use_pi_calc=false
is_fb_pano=false

# Color output for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions - all output to stderr to avoid interfering with function returns
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to find tool in common locations
find_tool() {
    local tool_name="$1"
    local tool_path=""
    
    # Common locations to check
    local common_paths=(
        "/usr/local/bin/${tool_name}"
        "/usr/bin/${tool_name}"
        "/opt/homebrew/bin/${tool_name}"
        "/Applications/Hugin/PTBatcherGUI.app/Contents/MacOS/${tool_name}"
        "/Applications/Hugin.app/Contents/MacOS/${tool_name}"
        "/usr/local/Hugin.app/Contents/MacOS/${tool_name}"
    )
    
    # First check if it's in PATH
    if command -v "$tool_name" >/dev/null 2>&1; then
        tool_path=$(command -v "$tool_name")
        log_info "Found $tool_name in PATH: $tool_path"
        echo "$tool_path"
        return 0
    fi
    
    # Then check common installation paths
    for path in "${common_paths[@]}"; do
        if [[ -x "$path" ]]; then
            log_info "Found $tool_name at: $path"
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Function to check required tools
check_dependencies() {
    local missing_tools=()
    local tools=("exiftool" "bc" "nona" "verdandi")
    
    log_info "Checking required dependencies..."
    
    for tool in "${tools[@]}"; do
        if ! find_tool "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Installation suggestions:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                "exiftool")
                    echo "  - Install exiftool: brew install exiftool (macOS) or apt-get install libimage-exiftool-perl (Ubuntu)"
                    ;;
                "bc")
                    echo "  - Install bc: brew install bc (macOS) or apt-get install bc (Ubuntu)"
                    ;;
                "nona"|"verdandi")
                    echo "  - Install Hugin: https://hugin.sourceforge.io/ or brew install --cask hugin (macOS)"
                    ;;
            esac
        done
        return 1
    fi
    
    log_success "All dependencies found"
    return 0
}

# Divisor calc with better error handling
round_to_closest_divisor() {
    local number="$1"
    local divisor="$2"

    if [[ -z "$number" || -z "$divisor" || "$divisor" -eq 0 ]]; then
        log_error "Invalid input for round_to_closest_divisor. Number: '$number', Divisor: '$divisor'"
        return 1
    fi

    # Clean the input to ensure it's a valid number
    number=$(echo "$number" | tr -d '\n' | sed 's/[^0-9.]//g')
    
    if [[ -z "$number" ]]; then
        log_error "Invalid number after cleaning: '$1'"
        return 1
    fi

    local half_divisor=$(echo "scale=0; $divisor / 2" | bc -l)
    local rounded=$(echo "scale=0; ($number + $half_divisor) / $divisor" | bc -l)
    local result=$(echo "scale=0; $rounded * $divisor" | bc -l)

    echo "$result"
}

# Function to validate image files
validate_image_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        log_error "File does not exist: $file"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        log_error "File is not readable: $file"
        return 1
    fi
    
    # Check if it's a valid image file
    if ! exiftool -q -q "$file" >/dev/null 2>&1; then
        log_error "File is not a valid image: $file"
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
        log_error "Could not determine width of image: $file"
        return 1
    fi
    
    echo "$width"
}

# Function to verify all cubemap faces have the same dimensions
verify_cubemap_dimensions() {
    local files=("$@")
    local reference_width
    local reference_height
    
    log_info "Verifying cubemap face dimensions..."
    
    # Get dimensions from first file as reference
    reference_width=$(get_image_width "${files[0]}")
    reference_height=$(exiftool -s -s -s -ImageHeight "${files[0]}" 2>/dev/null)
    
    if [[ -z "$reference_width" || -z "$reference_height" ]]; then
        log_error "Could not determine dimensions of reference image: ${files[0]}"
        return 1
    fi
    
    # Check if image is square (required for cubemap faces)
    if [[ "$reference_width" -ne "$reference_height" ]]; then
        log_error "Cubemap faces must be square. ${files[0]} is ${reference_width}x${reference_height}"
        return 1
    fi
    
    # Check all other files
    for file in "${files[@]:1}"; do
        local width height
        width=$(get_image_width "$file")
        height=$(exiftool -s -s -s -ImageHeight "$file" 2>/dev/null)
        
        if [[ "$width" != "$reference_width" || "$height" != "$reference_height" ]]; then
            log_error "Dimension mismatch: $file (${width}x${height}) vs reference (${reference_width}x${reference_height})"
            return 1
        fi
    done
    
    log_success "All cubemap faces have matching dimensions: ${reference_width}x${reference_height}"
    echo "$reference_width"
}

# Function to extract prefix from filename
extract_prefix() {
    local filename="$1"
    local basename=$(basename "$filename")
    local face_patterns=("Back" "Down" "Front" "Left" "Right" "Up")
    
    for pattern in "${face_patterns[@]}"; do
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
    
    log_error "Could not extract prefix from filename: $filename"
    log_error "Filename must contain one of: Back, Down, Front, Left, Right, Up"
    return 1
}

# Function to detect file extension from input
get_file_extension() {
    local filename="$1"
    local basename=$(basename "$filename")
    echo "${basename##*.}"
}

# Function to build cubemap file paths
build_cubemap_paths() {
    local first_file="$1"
    local prefix extension directory
    
    # Extract components from first file
    prefix=$(extract_prefix "$first_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    extension=$(get_file_extension "$first_file")
    directory=$(dirname "$first_file")
    
    log_info "Detected prefix: '$prefix'"
    log_info "Detected extension: '$extension'"
    log_info "Base directory: '$directory'"
    
    # Build paths for all faces
    local faces=("Back" "Down" "Front" "Left" "Right" "Up")
    local separator
    
    # Determine separator (underscore or none) based on original filename
    local basename=$(basename "$first_file")
    if [[ "$basename" == *"_"* ]]; then
        separator="_"
    else
        separator=""
    fi
    
    # Set global variables
    face_back="${directory}/${prefix}${separator}Back.${extension}"
    face_down="${directory}/${prefix}${separator}Down.${extension}"
    face_front="${directory}/${prefix}${separator}Front.${extension}"
    face_left="${directory}/${prefix}${separator}Left.${extension}"
    face_right="${directory}/${prefix}${separator}Right.${extension}"
    face_up="${directory}/${prefix}${separator}Up.${extension}"
    
    # Generate output filename
    file_output="${directory}/${prefix}_equirectangular.${extension}"
    
    log_info "Generated file paths:"
    log_info "  Back:   $face_back"
    log_info "  Down:   $face_down"
    log_info "  Front:  $face_front"
    log_info "  Left:   $face_left"
    log_info "  Right:  $face_right"
    log_info "  Up:     $face_up"
    log_info "  Output: $file_output"
}

# Function to validate provided files and detect missing ones
validate_and_detect_files() {
    local provided_files=("$@")
    local all_faces=("Back" "Down" "Front" "Left" "Right" "Up")
    local provided_faces=()
    local prefix extension directory separator
    
    # Extract info from first file
    local first_file="${provided_files[0]}"
    prefix=$(extract_prefix "$first_file")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    extension=$(get_file_extension "$first_file")
    directory=$(dirname "$first_file")
    
    # Determine separator
    local basename=$(basename "$first_file")
    if [[ "$basename" == *"_"* ]]; then
        separator="_"
    else
        separator=""
    fi
    
    # Check which faces were provided
    for file in "${provided_files[@]}"; do
        local file_basename=$(basename "$file")
        for face in "${all_faces[@]}"; do
            if [[ "$file_basename" == *"${separator}${face}."* ]] || [[ "$file_basename" == *"${face}."* && "$separator" == "" ]]; then
                provided_faces+=("$face")
                break
            fi
        done
    done
    
    log_info "Provided faces: ${provided_faces[*]}"
    
    # Check if all expected files exist
    local missing_faces=()
    for face in "${all_faces[@]}"; do
        local expected_file="${directory}/${prefix}${separator}${face}.${extension}"
        if [[ ! -f "$expected_file" ]]; then
            missing_faces+=("$face")
        fi
    done
    
    if [[ ${#missing_faces[@]} -gt 0 ]]; then
        log_error "Missing cubemap faces: ${missing_faces[*]}"
        log_error "Expected files with prefix '$prefix' and extension '$extension'"
        for face in "${missing_faces[@]}"; do
            log_error "  Missing: ${directory}/${prefix}${separator}${face}.${extension}"
        done
        return 1
    fi
    
    # Set global variables
    face_back="${directory}/${prefix}${separator}Back.${extension}"
    face_down="${directory}/${prefix}${separator}Down.${extension}"
    face_front="${directory}/${prefix}${separator}Front.${extension}"
    face_left="${directory}/${prefix}${separator}Left.${extension}"
    face_right="${directory}/${prefix}${separator}Right.${extension}"
    face_up="${directory}/${prefix}${separator}Up.${extension}"
    file_output="${directory}/${prefix}_equirectangular.${extension}"
    
    log_success "All cubemap faces found successfully"
    return 0
}

direct_width=''
direct_height=''
# Check if the first argument matches --size=WIDTHxHEIGHT
if [[ "$1" =~ ^--size=[0-9]+x[0-9]+$ ]]; then
    # Extract width and height using parameter expansion
    size_param=${1#--size=}           # Remove --size= prefix
    direct_width=${size_param%x*}     # Extract width (before 'x')
    direct_height=${size_param#*x}    # Extract height (after 'x')
    shift                            # Remove the first argument
fi


# Main script starts here
log_info "Starting cubemap to equirectangular conversion..."

# Check arguments
if [[ $# -eq 0 ]]; then
   log_error "At least 1 argument is required"
   show_usage
   exit 1
elif [[ $# -eq 1 ]]; then
   log_info "Single file mode: detecting all faces from prefix"
   if ! build_cubemap_paths "$1"; then
       exit 1
   fi
elif [[ $# -eq 6 ]]; then
   log_info "Multiple file mode: validating provided faces"
   if ! validate_and_detect_files "$@"; then
       exit 1
   fi
else
   log_error "Invalid number of arguments: $#"
   log_error "Provide either 1 file (auto-detect mode) or all 6 cubemap faces"
   show_usage
   exit 1
fi

# Check dependencies first
if ! check_dependencies; then
    exit 1
fi

# Get tool paths
NONA_PATH=$(find_tool "nona")
VERDANDI_PATH=$(find_tool "verdandi")
EXIFTOOL_PATH=$(find_tool "exiftool")

# Create a temporary directory
TEMP_DIR=$(mktemp -d)
log_info "Created temporary directory: $TEMP_DIR"

# Ensure the directory is deleted when the script exits (success or failure)
trap 'log_info "Cleaning up temporary directory: $TEMP_DIR"; rm -rf "$TEMP_DIR"' EXIT

hugin_file="${TEMP_DIR}/pano.pto"

# Array to hold the paths of the input files (now set by the detection functions)
input_files=("$face_back" "$face_down" "$face_front" "$face_left" "$face_right" "$face_up")

log_info "Validating input files..."

# Validate each input file
for file in "${input_files[@]}"; do
    if ! validate_image_file "$file"; then
        exit 1
    fi
done

# Verify cubemap dimensions and get tile width
tile_width=$(verify_cubemap_dimensions "${input_files[@]}")
if [[ $? -ne 0 ]]; then
    exit 1
fi

log_info "Cubemap face size: ${tile_width}x${tile_width}"

# Check if output directory is writable
output_dir=$(dirname "$file_output")
if [[ ! -w "$output_dir" ]]; then
    log_error "Output directory is not writable: $output_dir"
    exit 1
fi

# Get output dimensions
log_info "Calculating output dimensions..."
if ! pi=$(echo "scale=10; 4*a(1)" | bc -l); then
    log_error "Failed to calculate pi"
    exit 1
fi

# Calculate width using pi * tile_width
pi_times_width=$(echo "scale=2; $pi * $tile_width" | bc -l)
if [[ -z "$pi_times_width" ]]; then
    log_error "Failed to calculate pi * tile_width"
    exit 1
fi

width=$(round_to_closest_divisor "$pi_times_width" 16)
if [[ $? -ne 0 || -z "$width" ]]; then
    log_error "Failed to calculate output width"
    exit 1
fi

height=$(echo "scale=0; $width / 2" | bc -l)
if [[ -z "$height" ]]; then
    log_error "Failed to calculate output height"
    exit 1
fi

# Check if direct_width and direct_height are valid numbers
if [[ -n "$direct_width" && -n "$direct_height" && "$direct_width" =~ ^[0-9]+$ && "$direct_height" =~ ^[0-9]+$ ]]; then
    width=$direct_width
    height=$direct_height
fi

log_info "Output dimensions: ${width}x${height}"

# 180 degree rotation in case of a Facebook pano
if [[ $is_fb_pano == true ]]; then
    udrot=180
    log_info "Using Facebook panorama orientation (180° rotation)"
else
    udrot=0
fi

log_info "Creating Hugin project file..."

# Output the Hugin .pto file
cat > "${hugin_file}" << EOF
p f2 w${width} h${height} v360  k0 E0 R0 n"TIFF_m c:LZW r:CROP"
m i0

i w${tile_width} h${tile_width} f0 v90 Ra0 Rb0 Rc0 Rd0 Re0 Eev0 Er1 Eb1 r0 p0 y180 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a0 b0 c0 d0 e0 g0 t0 Va1 Vb0 Vc0 Vd0 Vx0 Vy0  Vm5 n"${face_back}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y0 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_front}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p-90 y${udrot} TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_down}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y-90 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_left}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p0 y90 TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_right}"
i w${tile_width} h${tile_width} f0 v=0 Ra=0 Rb=0 Rc=0 Rd=0 Re=0 Eev0 Er1 Eb1 r0 p90 y${udrot} TrX0 TrY0 TrZ0 Tpy0 Tpp0 j0 a=0 b=0 c=0 d=0 e=0 g=0 t=0 Va=0 Vb=0 Vc=0 Vd=0 Vx=0 Vy=0  Vm5 n"${face_up}"

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

# Change to temp directory for processing
cd "${TEMP_DIR}" || { log_error "Failed to change to temp directory"; exit 1; }

# Prepare sides for stitching
log_info "Stitching cubemap faces with nona..."
if ! "$NONA_PATH" -v -o pano -m TIFF_m -z LZW "${hugin_file}"; then
    log_error "nona failed to stitch images"
    exit 1
fi

# Verify nona output files exist
pano_files=()
for i in {0..5}; do
    pano_file="${TEMP_DIR}/pano000${i}.tif"
    if [[ ! -f "$pano_file" ]]; then
        log_error "Expected output file missing: $pano_file"
        exit 1
    fi
    pano_files+=("$pano_file")
done

# Blend the images
log_info "Blending images with verdandi..."
if ! "$VERDANDI_PATH" "${pano_files[@]}" -o "${file_output}"; then
    log_error "verdandi failed to blend images"
    exit 1
fi

# Verify output file was created
if [[ ! -f "$file_output" ]]; then
    log_error "Output file was not created: $file_output"
    exit 1
fi

log_success "Conversion completed successfully!"
log_info "Output file: $file_output"

# Show output file info
if command -v "$EXIFTOOL_PATH" >/dev/null 2>&1; then
    output_width=$("$EXIFTOOL_PATH" -s -s -s -ImageWidth "$file_output" 2>/dev/null)
    output_height=$("$EXIFTOOL_PATH" -s -s -s -ImageHeight "$file_output" 2>/dev/null)
    if [[ -n "$output_width" && -n "$output_height" ]]; then
        log_info "Final image dimensions: ${output_width}x${output_height}"
    fi
fi