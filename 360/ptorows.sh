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

# Strict error handling
set -euo pipefail

# Set locale to ensure consistent number formatting
export LC_NUMERIC=C
export LC_ALL=C

# Global variables
readonly SCRIPT_NAME=$(basename "$0")
readonly TEMP_PREFIX="ptorows"
VERBOSE=false

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*" >&2
    fi
}

# Usage function
usage() {
    cat << EOF >&2
Usage: $SCRIPT_NAME [OPTIONS] <pano1.pto> [pano2.pto...]

Process panorama .pto files by splitting them into rows and merging with fades.

OPTIONS:
    -h, --help      Show this help message
    -v, --verbose   Enable verbose output
    --version       Show version information

EXAMPLES:
    $SCRIPT_NAME panorama.pto
    $SCRIPT_NAME --verbose pano1.pto pano2.pto

DEPENDENCIES:
    - Hugin tools (nona, enblend)
    - ImageMagick (magick command)
    - bc (basic calculator)
    - Standard Unix tools (grep, sed, cut, etc.)

EOF
}

# Version information
show_version() {
    echo "$SCRIPT_NAME version 2.0" >&2
    echo "Copyright (c) 2025 Rodrigo Polo" >&2
}

# Dependency checking
check_dependencies() {
    local missing_deps=()
    local deps=("nona" "enblend" "magick" "bc" "grep" "sed" "cut" "mktemp" "realpath")
    
    log_info "Checking dependencies..."
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep" >&2
        done
        echo >&2
        echo "Please install the missing dependencies:" >&2
        echo "  - Hugin tools: https://hugin.sourceforge.io/" >&2
        echo "  - ImageMagick: https://imagemagick.org/" >&2
        echo "  - bc: usually available in system repositories" >&2
        return 1
    fi
    
    log_success "All dependencies found"
    return 0
}

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        log_verbose "Cleaning up temporary directory: $TEMP_DIR"
        rm -rf "$TEMP_DIR" || log_warn "Failed to remove temporary directory: $TEMP_DIR"
    fi
    exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Function to round numbers properly (like Math.round in JS)
round() {
    echo "($1 + 0.5)/1" | bc -l | cut -d. -f1
}

# Validate .pto file
validate_pto_file() {
    local pto_file="$1"
    
    if [[ ! -f "$pto_file" ]]; then
        log_error "File not found: $pto_file"
        return 1
    fi
    
    if [[ ! -r "$pto_file" ]]; then
        log_error "File not readable: $pto_file"
        return 1
    fi
    
    # Check if it's a valid .pto file by looking for panorama line
    if ! grep -q '^p ' "$pto_file"; then
        log_error "Invalid .pto file (no panorama line found): $pto_file"
        return 1
    fi
    
    return 0
}

# Extract panorama width from .pto file
extract_panorama_width() {
    local pto_file="$1"
    local width
    
    width=$(grep '^p ' "$pto_file" | head -n1 | sed -E 's/.*w([0-9]+).*/\1/')
    
    if [[ ! "$width" =~ ^[0-9]+$ ]] || [[ "$width" -eq 0 ]]; then
        log_error "Could not extract valid panorama width from: $pto_file"
        return 1
    fi
    
    echo "$width"
}

# Row processing function with error handling
stitch_and_merge() {
    local rez_pto="$1"
    local row_crop="$2"
    local row_pto="$3"
    local row_out="$4"
    local row_name="$5"

    log_info "Processing $row_name..."
    
    # Create modified .pto file
    log_verbose "Creating modified .pto file: $row_pto"
    if ! sed "s/R0 n\"TIFF_m/R0 ${row_crop} n\"TIFF_m/" "$rez_pto" > "$row_pto"; then
        log_error "Failed to create modified .pto file: $row_pto"
        return 1
    fi

    # Stitching
    log_verbose "Stitching $row_name..."
    if ! nona -v -m TIFF_m -z LZW -o pano "$row_pto" 2>&1 | grep -v -i 'warning' >&2; then
        log_error "Stitching failed for $row_name"
        return 1
    fi
    
    # Check if pano files were created
    if ! ls pano*.tif &> /dev/null; then
        log_error "No panorama TIFF files were created during stitching"
        return 1
    fi

    # Merging row 
    log_verbose "Merging $row_name to: $row_out"
    if ! enblend --verbose=1 -o "$row_out" pano*.tif 2>&1 | grep -i 'enblend: info:' >&2; then
        log_error "Merging failed for $row_name"
        return 1
    fi
    
    # Verify output file was created
    if [[ ! -f "$row_out" ]]; then
        log_error "Output file was not created: $row_out"
        return 1
    fi

    # Remove intermediate tifs
    log_verbose "Cleaning up intermediate TIFF files"
    rm -f *.tif || log_warn "Failed to remove some intermediate TIFF files"
    
    log_success "$row_name completed successfully"
}

# Process a single .pto file
process_pto_file() {
    local input_file="$1"
    
    log_info "Processing file: $input_file"
    
    # Validate input file
    if ! validate_pto_file "$input_file"; then
        return 1
    fi
    
    # Get absolute paths and file info
    local input_full_path
    if ! input_full_path=$(realpath "$input_file"); then
        log_error "Failed to get absolute path for: $input_file"
        return 1
    fi
    
    local input_dir=$(dirname "$input_full_path")
    local input_base=$(basename "$input_full_path")
    local input_ext="${input_base##*.}"
    local input_name="${input_base%.*}"
    local input_next="${input_dir}/${input_name}"

    log_verbose "Input file: $input_full_path"
    log_verbose "Output prefix: $input_next"

    # Extract panorama width
    local pano_width
    if ! pano_width=$(extract_panorama_width "$input_full_path"); then
        return 1
    fi
    
    log_verbose "Original panorama width: $pano_width"

    # Calculate dimensions
    local row_margin=21
    local new_pano_width new_pano_height row_height margin total_row_height
    
    if ! new_pano_width=$(round "$pano_width/16"); then
        log_error "Failed to calculate new panorama width"
        return 1
    fi
    new_pano_width=$((new_pano_width * 16))
    new_pano_height=$((new_pano_width / 2))
    
    local temp
    temp=$(echo "scale=10; ($new_pano_height / 3) / 2" | bc -l)
    if ! row_height=$(round "$temp"); then
        log_error "Failed to calculate row height"
        return 1
    fi
    row_height=$((row_height * 2))
    
    temp=$(echo "scale=10; ($new_pano_height / $row_margin) / 16" | bc -l)
    if ! margin=$(round "$temp"); then
        log_error "Failed to calculate margin"
        return 1
    fi
    margin=$((margin * 16))
    
    total_row_height=$((row_height + margin))

    log_verbose "Calculated dimensions:"
    log_verbose "  New panorama: ${new_pano_width}x${new_pano_height}"
    log_verbose "  Row height: $row_height"
    log_verbose "  Margin: $margin"
    log_verbose "  Total row height: $total_row_height"

    # Calculate crop boundaries
    local r1b=$total_row_height
    local r2t=$(((new_pano_height / 2) - (total_row_height / 2)))
    local r2b=$((r2t + total_row_height))
    local r3t=$((new_pano_height - total_row_height))
    local r3b=$new_pano_height
    local gradient=$((r1b - r2t))

    # Define crop strings
    local row1_crop="S0,${new_pano_width},0,${r1b}"
    local row2_crop="S0,${new_pano_width},${r2t},${r2b}"
    local row3_crop="S0,${new_pano_width},${r3t},${r3b}"

    log_verbose "Crop regions:"
    log_verbose "  Row 1: $row1_crop"
    log_verbose "  Row 2: $row2_crop"
    log_verbose "  Row 3: $row3_crop"

    # Create temporary directory
    if ! TEMP_DIR=$(mktemp -d -t "${TEMP_PREFIX}.XXXXXX"); then
        log_error "Failed to create temporary directory"
        return 1
    fi
    
    log_verbose "Created temporary directory: $TEMP_DIR"
    
    # Change to temp directory
    local original_dir="$PWD"
    if ! cd "$TEMP_DIR"; then
        log_error "Failed to change to temporary directory: $TEMP_DIR"
        return 1
    fi

    # File paths
    local file_resized="${TEMP_DIR}/resized.pto"
    local row1_pto="${TEMP_DIR}/row1.pto"
    local row2_pto="${TEMP_DIR}/row2.pto"
    local row3_pto="${TEMP_DIR}/row3.pto"
    local row1_out="${input_next}_row1.tif"
    local row2_out="${input_next}_row2.tif"
    local row3_out="${input_next}_row3.tif"

    # Create resized pto with adjusted dimensions and normalized file paths
    log_verbose "Creating resized .pto file"
    if ! cat "${input_full_path}" | \
        sed "s/^p f2 w[0-9]\+ h[0-9]\+ v/p f2 w${new_pano_width} h${new_pano_height} v/" | \
        sed "s|Vm5 n\"|Vm5 n\"${input_dir}/|" > "${file_resized}"; then
        log_error "Failed to create resized .pto file"
        cd "$original_dir"
        return 1
    fi

    # Process each row
    if ! stitch_and_merge "$file_resized" "$row1_crop" "$row1_pto" "$row1_out" "Row 1"; then
        cd "$original_dir"
        return 1
    fi
    
    if ! stitch_and_merge "$file_resized" "$row2_crop" "$row2_pto" "$row2_out" "Row 2"; then
        cd "$original_dir"
        return 1
    fi
    
    if ! stitch_and_merge "$file_resized" "$row3_crop" "$row3_pto" "$row3_out" "Row 3"; then
        cd "$original_dir"
        return 1
    fi

    # Return to original directory
    cd "$original_dir"

    # Create fades
    log_info "Creating fade effects..."
    if ! magick "$row1_out" \( -size "${new_pano_width}x${gradient}" gradient:white-black \) \
         -geometry "+0+${r2t}" -alpha off -compose copy_opacity -composite "${input_next}_row1a.tif"; then
        log_error "Failed to create fade for row 1"
        return 1
    fi
    
    if ! magick "$row2_out" \( -size "${new_pano_width}x${gradient}" gradient:white-black \) \
         -geometry "+0+${r2t}" -alpha off -compose copy_opacity -composite "${input_next}_row2a.tif"; then
        log_error "Failed to create fade for row 2"
        return 1
    fi

    # Final merge
    log_info "Creating final merged panorama..."
    if ! magick -size "${new_pano_width}x${new_pano_height}" xc:transparent \
         "$row3_out" -geometry "+0+${r3t}" -composite \
         "${input_next}_row2a.tif" -geometry "+0+${r2t}" -composite \
         "${input_next}_row1a.tif" -geometry "+0+0" -composite \
         -depth 16 "${input_next}_merged.tif"; then
        log_error "Failed to create final merged panorama"
        return 1
    fi

    # Clean up intermediate files
    log_verbose "Cleaning up intermediate files"
    rm -f "${input_next}_row1a.tif" "${input_next}_row2a.tif" || \
        log_warn "Failed to remove some intermediate files"

    log_success "Successfully processed: $input_file"
    log_success "Output created: ${input_next}_merged.tif"
    
    return 0
}

# Parse command line arguments
parse_arguments() {
    local files=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                echo "Use --help for usage information." >&2
                exit 1
                ;;
            *)
                files+=("$1")
                shift
                ;;
        esac
    done
    
    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "No input files specified"
        usage
        exit 1
    fi
    
    # Return files array
    printf '%s\n' "${files[@]}"
}

# Main function
main() {
    local input_files=()
    
    # Parse arguments - compatible with Bash 3.2+
    while IFS= read -r file; do
        input_files+=("$file")
    done < <(parse_arguments "$@")

    # Check if input_files is empty
    if [[ ${#input_files[@]} -eq 0 ]]; then
        log_error "No files to process after parsing arguments"
        exit 1
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    local success_count=0
    local total_count=${#input_files[@]}
    
    log_info "Processing $total_count file(s)..."
    
    # Process each input file
    for input_file in "${input_files[@]}"; do
        if process_pto_file "$input_file"; then
            ((success_count++))
        else
            log_error "Failed to process: $input_file"
        fi
        echo >&2  # Add blank line between files
    done
    
    # Summary
    log_success "Processing completed. $success_count of $total_count files processed successfully."
    
    if [[ $success_count -lt $total_count ]]; then
        exit 1
    fi
}

# Run main function with all arguments
main "$@"