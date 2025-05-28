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


set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Script configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly REQUIRED_COMMANDS=("bc" "exiftool" "kubi")

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging functions
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_info() {
    echo "[INFO] $*"
}

# Usage function
usage() {
    cat << EOF
Usage: $SCRIPT_NAME <input_file1> [input_file2] ...

Description:
    Processes panorama images by extracting dimensions, calculating cube face size,
    and converting them using the kubi tool.

Requirements:
    - bc (basic calculator)
    - exiftool (metadata extraction)
    - kubi (panorama conversion tool)

Examples:
    $SCRIPT_NAME image1.jpg
    $SCRIPT_NAME *.jpg
    $SCRIPT_NAME /path/to/panorama1.jpg /path/to/panorama2.jpg

EOF
}

# Check if required commands are available
check_dependencies() {
    local missing_deps=()
    
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo
        echo "Please install the missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            case "$dep" in
                bc)
                    echo "  - Ubuntu/Debian: sudo apt-get install bc"
                    echo "  - macOS: brew install bc"
                    echo "  - CentOS/RHEL: sudo yum install bc"
                    ;;
                exiftool)
                    echo "  - Ubuntu/Debian: sudo apt-get install libimage-exiftool-perl"
                    echo "  - macOS: brew install exiftool"
                    echo "  - CentOS/RHEL: sudo yum install perl-Image-ExifTool"
                    ;;
                kubi)
                    echo "  - kubi: Please install from the official source"
                    echo "    (This appears to be a specialized panorama tool)"
                    ;;
            esac
        done
        return 1
    fi
    
    log_success "All dependencies are available"
    return 0
}

# Validate numeric input
is_numeric() {
    local value="$1"
    [[ $value =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# Divisor calculation function with enhanced error handling
round_to_closest_divisor() {
    local number="$1"
    local divisor="$2"

    # Validate inputs
    if [[ -z "$number" || -z "$divisor" ]]; then
        log_error "round_to_closest_divisor: Missing required arguments"
        return 1
    fi

    if ! is_numeric "$number" || ! is_numeric "$divisor"; then
        log_error "round_to_closest_divisor: Arguments must be numeric"
        return 1
    fi

    if [[ $(echo "$divisor == 0" | bc) -eq 1 ]]; then
        log_error "round_to_closest_divisor: Divisor cannot be zero"
        return 1
    fi

    # Perform calculation with error handling
    local half_divisor
    local rounded
    
    if ! half_divisor=$(echo "scale=10; $divisor / 2" | bc 2>/dev/null); then
        log_error "round_to_closest_divisor: Failed to calculate half divisor"
        return 1
    fi
    
    if ! rounded=$(echo "scale=0; (($number + $half_divisor) / $divisor) * $divisor" | bc 2>/dev/null); then
        log_error "round_to_closest_divisor: Failed to calculate rounded value"
        return 1
    fi

    echo "$rounded"
}

# Process a single image file
process_image() {
    #local input_file="$1"
    #local output="${f%.*}_p.mp4"
    #local original_dir="$PWD"

    local input_path="$1"
    local input_full_path=$(realpath "$input_path")

    local input_base=$(basename "$input_full_path")
    local input_ext="${input_base##*.}"
    local input_name="${input_base%*.$input_ext}"
    
    log_info "Processing: $input_full_path"
    
    # Check if file exists and is readable
    if [[ ! -f "$input_full_path" ]]; then
        log_error "File does not exist: $input_full_path"
        return 1
    fi
    
    if [[ ! -r "$input_full_path" ]]; then
        log_error "File is not readable: $input_full_path"
        return 1
    fi
    
    # Change to file directory with error handling
    local file_dir
    file_dir=$(dirname "$input_full_path") || {
        log_error "Failed to get directory for: $input_full_path"
        return 1
    }
    
    if ! cd "$file_dir" 2>/dev/null; then
        log_error "Failed to change to directory: $file_dir"
        return 1
    fi
    
    # Ensure we return to original directory on exit
    #trap "cd '$original_dir'" RETURN
    
    # Extract dimensions with timeout and error handling
    local height width
    local filename
    filename=$(basename "$input_full_path")
    
    log_info "Extracting image dimensions..."
    
    if ! height=$(timeout 30 exiftool -s -s -s -ImageHeight "$filename" 2>/dev/null); then
        log_error "Failed to extract height from: $input_full_path"
        return 1
    fi
    
    if ! width=$(timeout 30 exiftool -s -s -s -ImageWidth "$filename" 2>/dev/null); then
        log_error "Failed to extract width from: $input_full_path"
        return 1
    fi
    
    # Validate extracted dimensions
    if [[ -z "$height" || -z "$width" ]]; then
        log_error "Could not extract valid dimensions from: $input_full_path"
        return 1
    fi
    
    if ! is_numeric "$height" || ! is_numeric "$width"; then
        log_error "Invalid dimension values - Height: $height, Width: $width"
        return 1
    fi
    
    if [[ $(echo "$height <= 0 || $width <= 0" | bc) -eq 1 ]]; then
        log_error "Invalid dimension values - Height: $height, Width: $width (must be positive)"
        return 1
    fi
    
    log_info "Image dimensions: ${width}x${height}"
    
    # Calculate PI with error handling
    local pi
    if ! pi=$(echo "scale=10; 4*a(1)" | bc -l 2>/dev/null); then
        log_error "Failed to calculate PI"
        return 1
    fi
    
    # Calculate cubeface size
    local width_over_pi cubeface_size
    
    if ! width_over_pi=$(echo "scale=10; $width / $pi" | bc 2>/dev/null); then
        log_error "Failed to calculate width/pi"
        return 1
    fi
    
    if ! cubeface_size=$(round_to_closest_divisor "$width_over_pi" 16); then
        log_error "Failed to calculate cubeface size"
        return 1
    fi
    
    log_info "Calculated cubeface size: $cubeface_size"
    
    # Validate cubeface size
    if [[ $(echo "$cubeface_size <= 0" | bc) -eq 1 ]]; then
        log_error "Invalid cubeface size: $cubeface_size"
        return 1
    fi
    
    # Run kubi with error handling and timeout
    log_info "Running kubi conversion..."
    
    if ! timeout 300 kubi -s "${cubeface_size}" -f Right Left Up Down Front Back "${filename}" ${input_name} 2>/dev/null; then
        log_error "kubi processing failed for: $input_full_path"
        return 1
    fi
    
    log_success "Successfully processed: $input_full_path (cubeface size: $cubeface_size)"
    return 0
}

# Main function
main() {
    # Handle help flag
    if [[ $# -eq 0 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    fi
    
    # Check dependencies first
    if ! check_dependencies; then
        exit 1
    fi
    
    # Process statistics
    local total_files=0
    local successful_files=0
    local failed_files=0
    
    # Modify IFS for safe file handling
    local OLD_IFS="$IFS"
    IFS=$'\t\n'
    
    # Process each input file
    for input_file in "$@"; do
        ((total_files++))
        
        if process_image "$input_file"; then
            ((successful_files++))
        else
            ((failed_files++))
            log_warning "Skipping failed file: $input_file"
        fi
        
        echo  # Add blank line between files
    done
    
    # Restore IFS
    IFS="$OLD_IFS"
    
    # Print summary
    echo "==================== SUMMARY ===================="
    log_info "Total files processed: $total_files"
    log_success "Successful: $successful_files"
    if [[ $failed_files -gt 0 ]]; then
        log_error "Failed: $failed_files"
    else
        log_info "Failed: $failed_files"
    fi
    echo "================================================="
    
    # Exit with appropriate code
    if [[ $failed_files -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# Run main function with all arguments
main "$@"
