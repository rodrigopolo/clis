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
readonly DEFAULT_MARGIN_PERCENTAGE=19
readonly MAX_TILE_SIZE=3072
readonly MAX_GRID_DIVISIONS=14

# Global variables for tool paths
PANO_MODIFY_PATH=""
HUGIN_EXECUTOR_PATH=""
MAGICK_PATH=""
FILES=()

# Command line options
VERBOSE=0
KEEP_TEMP=0
MARGIN_PERCENTAGE=$DEFAULT_MARGIN_PERCENTAGE
DESIRED_ROWS=0  # 0 means auto-calculate

# Function to print usage
usage() {
    cat << 'EOF'
Usage: ptogrid_rows.sh [OPTIONS] <pano1.pto> [pano2.pto...]

Generate horizontal row strips from panoramic PTO files.

OPTIONS:
    -v, --verbose       Enable verbose output
    -k, --keep-temp     Keep temporary files for debugging
    -m, --margin PERCENT Margin percentage (1-50) [default: 19]
    -r, --rows NUMBER   Desired number of rows (will find closest divisible) [default: auto]
    -h, --help          Show this help message

EXAMPLES:
    ptogrid_rows.sh panorama.pto
    ptogrid_rows.sh -v *.pto
    ptogrid_rows.sh --rows 8 --margin 25 pano.pto
    ptogrid_rows.sh --keep-temp --rows 4 pano.pto

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
                "pano_modify"|"hugin_executor")
                    echo -e "  - Install Hugin:\n    https://github.com/rodrigopolo/clis/tree/main/360#dependencies" >&2
                    ;;
                "magick")
                    echo -e "  - Install ImageMagick:\n    brew install imagemagick" >&2
                    ;;
            esac
        done
        return 1
    fi
    
    log "All dependencies found"
    return 0
}

# Validate input file
validate_pto_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        error "File '$file' does not exist"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        error "File '$file' is not readable"
        return 1
    fi
    
    # Check if it's a valid PTO file
    if ! grep -q '^p ' "$file"; then
        error "File '$file' doesn't appear to be a valid PTO file (missing panorama line)"
        return 1
    fi
    
    return 0
}

# Rounds to nearest 16
sixteen() {
    local input=$1
    echo $(( (input + 8) / 16 * 16 ))
}

# To check if a number is an integer
is_integer() {
    local dividend=$1
    local divisor=$2
    local remainder=$((dividend % divisor))
    [[ $remainder -eq 0 ]]
}

# Function to create cropped versions of the panorama
createpiece() {
    local pto_file="$1"
    local row="$2"
    local col="$3"
    local square_size="$4"
    local margin="$5"
    local isLastColumn="$6"
    local isLastRow="$7"
    local output_path="$8"

    local magick_lastrow=" "
    local magick_lastcol=" "
    local right width bottom height

    local left=$(( col * square_size ))
    local top=$(( row * square_size ))

    if [[ "$isLastColumn" -eq 1 ]]; then
        right="$(( left + square_size ))"
        width="$square_size"
    else
        right="$(( left + square_size + margin ))"
        width="$(( square_size + margin ))"
    fi

    if [[ "$isLastRow" -eq 1 ]]; then
        bottom="$(( top + square_size ))"
        height="$square_size"
    else
        bottom="$(( top + square_size + margin ))"
        height="$(( square_size + margin ))"
    fi

    if [[ "$isLastColumn" -ne 1 ]]; then
        magick_lastcol=" ( -size ${margin}x${height} -define gradient:direction=East gradient:white-black -geometry +${square_size}+0 ) -compose multiply -composite "
    fi

    if [[ "$isLastRow" -ne 1 ]]; then
        magick_lastrow=" ( -size ${width}x${margin} gradient:white-black -geometry +0+${square_size} ) -compose multiply -composite "
    fi

    local filename="r${row}_c${col}"
    local temp_pto="${output_path}/${filename}.pto"
    local tmp_output="${output_path}/${filename}.tif"
    local end_output="${output_path}/${filename}_f.tif"
    local log_file="${output_path}/commands.log"

    log "Processing piece: row $row, col $col (${left},${right},${top},${bottom})"

    # Modify the crop of the original file - left, right, top, bottom
    if ! "$PANO_MODIFY_PATH" --crop="${left},${right},${top},${bottom}" -o "${temp_pto}" "${pto_file}" >> "${log_file}" 2>&1; then
        error "Failed to modify PTO for piece r${row}_c${col}"
        return 1
    fi

    # Stitch the image
    if ! "${HUGIN_EXECUTOR_PATH}" --stitching --prefix="${filename}" "${temp_pto}" >> "${log_file}" 2>&1; then
        error "Failed to stitch piece r${row}_c${col}"
        return 1
    fi

    # Apply fadeout effects or move final piece
    if [[ "$isLastColumn" -eq 1 && "$isLastRow" -eq 1 ]]; then
        mv "${tmp_output}" "${end_output}"
    else
        if ! "${MAGICK_PATH}" "${tmp_output}" -write MPR:orig -alpha extract${magick_lastrow}${magick_lastcol}MPR:orig +swap -compose copyopacity -composite "${end_output}"; then
            error "Failed to apply fadeout effects to piece r${row}_c${col}"
            return 1
        fi
    fi

    return 0
}

# Calculate optimal row count (modified for rows-only with optional desired rows)
calculate_grid_size() {
    local nheight="$1"
    local desired_rows="$2"  # 0 means auto-calculate
    
    # If desired rows specified, find closest divisible number
    if [[ $desired_rows -gt 0 ]]; then
        log "Finding closest divisible rows to desired: $desired_rows"
        
        # Find the closest divisible numbers above and below the desired count
        local best_rows=0
        local best_diff=999999
        
        # Check a reasonable range around the desired number
        local search_start=$((desired_rows > 5 ? desired_rows - 5 : 1))
        local search_end=$((desired_rows + 10))
        
        for ((i = search_start; i <= search_end && i <= MAX_GRID_DIVISIONS; i++)); do
            if is_integer "$nheight" "$i"; then
                local diff=$((i > desired_rows ? i - desired_rows : desired_rows - i))
                local row_height=$((nheight / i))
                
                # Prefer the closest match, but ensure row height is reasonable
                if [[ $row_height -le $MAX_TILE_SIZE && $diff -lt $best_diff ]]; then
                    best_rows=$i
                    best_diff=$diff
                fi
            fi
        done
        
        if [[ $best_rows -gt 0 ]]; then
            if [[ $best_rows -ne $desired_rows ]]; then
                log "Adjusted rows from $desired_rows to $best_rows (closest divisible)"
            fi
            echo "$best_rows"
            return 0
        else
            log "No suitable divisible rows found near $desired_rows, falling back to auto-calculation"
        fi
    fi
    
    # Original auto-calculation logic
    local highest_div=0
    local calc
    
    for ((i = 1; i <= MAX_GRID_DIVISIONS; i++)); do
        if [[ $highest_div -gt 0 ]]; then
            calc=$((nheight / highest_div))
            if [[ $calc -le $MAX_TILE_SIZE ]]; then
                break
            fi
        fi
        
        if is_integer "$nheight" "$i"; then
            highest_div=$i
        fi
    done
    
    if [[ $highest_div -eq 0 ]]; then
        error "Could not calculate optimal row count for height: $nheight"
        return 1
    fi
    
    echo "$highest_div"
    return 0
}

# Generate grid (modified for rows-only)
gen_grid() {
    local input_path="$1"
    local TEMP_DIR=""
    
    # Create temporary directory with error handling
    if ! TEMP_DIR=$(mktemp -d); then
        error "Failed to create temporary directory"
        return 1
    fi
    
    local log_file="${TEMP_DIR}/commands.log"
    local input_full_path input_dir input_base input_ext input_name input_next resized_pto
    
    input_full_path=$(realpath "$input_path")
    input_dir=$(dirname "$input_full_path")
    input_base=$(basename "$input_full_path")
    input_ext="${input_base##*.}"
    input_name="${input_base%*.$input_ext}"
    input_next="${input_dir}/${input_name}"
    resized_pto="${TEMP_DIR}/resized.pto"

    # Cleanup function
    cleanup_temp() {
        if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
            if [[ $KEEP_TEMP -eq 0 ]]; then
                log "Cleaning up temporary directory: $TEMP_DIR"
                rm -rf "$TEMP_DIR"
            else
                echo "Temporary files kept at: $TEMP_DIR" >&2
            fi
        fi
    }

    # Ensure cleanup on exit
    trap cleanup_temp EXIT

    echo "Processing ${input_full_path}" >&2
    log "Working in temporary folder: ${TEMP_DIR}"

    # Extract and validate PTO width
    local width
    width=$(grep '^p' "${input_full_path}" | sed -E 's/.*w([0-9]+).*/\1/') || {
        error "Failed to extract width from PTO file"
        return 1
    }
    
    if [[ ! "$width" =~ ^[0-9]+$ ]] || [[ "$width" -le 0 ]]; then
        error "Invalid width extracted from PTO: $width"
        return 1
    fi
    
    local nwidth nheight grid_height grid_width square_size margin_calc margin
    nwidth=$(sixteen "$width")
    nheight=$((nwidth / 2))

    # Calculate row count (rows-only modification)
    if ! grid_height=$(calculate_grid_size "$nheight" "$DESIRED_ROWS"); then
        return 1
    fi
    
    # For rows-only: grid_width is always 1
    grid_width=1
    square_size=$((nheight / grid_height))  # Height divided by number of rows
    margin_calc=$((square_size * MARGIN_PERCENTAGE / 100))
    margin=$(sixteen "$margin_calc")

    log "Row dimensions: ${grid_width}x${grid_height} (rows only), row height: $square_size, margin: $margin"

    # Change to temp directory
    cd "${TEMP_DIR}" || { error "Failed to change to temp directory"; return 1; }

    # Resize the original PTO
    log "Resizing PTO to ${nwidth}x${nheight}"
    if ! "$PANO_MODIFY_PATH" --canvas="${nwidth}x${nheight}" -o "${resized_pto}" "${input_full_path}" >> "${log_file}" 2>&1; then
        error "Failed to resize PTO file"
        return 1
    fi

    # Process row pieces
    local total_pieces=$((grid_height * grid_width))
    local current_piece=0
    
    for ((row = 0; row < grid_height; row++)); do
        for ((col = 0; col < grid_width; col++)); do
            current_piece=$((current_piece + 1))
            local is_last_column=1  # Always true for rows-only (only 1 column)
            local is_last_row=0
            
            [[ $row -eq $((grid_height - 1)) ]] && is_last_row=1
            
            echo "Creating row $current_piece of $total_pieces (row $((row + 1))/$grid_height)" >&2
            
            # For rows: left=0, right=nwidth, top and bottom calculated from row
            local left=0
            local right=$nwidth
            local top=$((row * square_size))
            local bottom
            
            if [[ "$is_last_row" -eq 1 ]]; then
                bottom="$nheight"
            else
                bottom="$(( top + square_size + margin ))"
            fi
            
            if ! createpiece_row "${resized_pto}" "$row" "$col" "$left" "$right" "$top" "$bottom" "$square_size" "$margin" "$is_last_row" "${TEMP_DIR}"; then
                error "Failed to create row r${row}_c${col}"
                return 1
            fi
        done
    done

    # Build and execute ImageMagick merge command
    local magick_cmd=()
    magick_cmd+=("$MAGICK_PATH" "-size" "${nwidth}x${nheight}" "xc:transparent")
    
    # Process in reverse order for better blending
    for ((row = grid_height - 1; row >= 0; row--)); do
        for ((col = grid_width - 1; col >= 0; col--)); do
            local y_pos=$((row * square_size))
            local filename="r${row}_c${col}_f.tif"
            magick_cmd+=("${filename}" "-geometry" "+0+${y_pos}" "-composite")
        done
    done
    
    local output_file="${input_next}_rows.tif"
    magick_cmd+=("${output_file}")
    
    echo "Merging to ${output_file}" >&2
    log "Executing: ${magick_cmd[*]}"
    
    if ! "${magick_cmd[@]}"; then
        error "Failed to merge rows"
        return 1
    fi

    # Manually delete the temporary directory
    cleanup_temp

    # Disable the trap to prevent it from running on script exit or interruption
    trap - EXIT

    echo "Successfully created: ${output_file}" >&2
    return 0
}

# Modified createpiece function for rows-only
createpiece_row() {
    local pto_file="$1"
    local row="$2"
    local col="$3"
    local left="$4"
    local right="$5"
    local top="$6"
    local bottom="$7"
    local square_size="$8"
    local margin="$9"
    local isLastRow="${10}"
    local output_path="${11}"

    local magick_lastrow=" "
    local width height

    width=$((right - left))
    height=$((bottom - top))

    # Only apply bottom margin for rows (no side margins needed)
    if [[ "$isLastRow" -ne 1 ]]; then
        magick_lastrow=" ( -size ${width}x${margin} gradient:white-black -geometry +0+${square_size} ) -compose multiply -composite "
    fi

    local filename="r${row}_c${col}"
    local temp_pto="${output_path}/${filename}.pto"
    local tmp_output="${output_path}/${filename}.tif"
    local end_output="${output_path}/${filename}_f.tif"
    local log_file="${output_path}/commands.log"

    log "Processing row: $row (${left},${right},${top},${bottom})"

    # Modify the crop of the original file - left, right, top, bottom
    if ! "$PANO_MODIFY_PATH" --crop="${left},${right},${top},${bottom}" -o "${temp_pto}" "${pto_file}" >> "${log_file}" 2>&1; then
        error "Failed to modify PTO for row r${row}_c${col}"
        return 1
    fi

    # Stitch the image
    if ! "${HUGIN_EXECUTOR_PATH}" --stitching --prefix="${filename}" "${temp_pto}" >> "${log_file}" 2>&1; then
        error "Failed to stitch row r${row}_c${col}"
        return 1
    fi

    # Apply fadeout effects or move final piece
    if [[ "$isLastRow" -eq 1 ]]; then
        mv "${tmp_output}" "${end_output}"
    else
        if ! "${MAGICK_PATH}" "${tmp_output}" -write MPR:orig -alpha extract${magick_lastrow}MPR:orig +swap -compose copyopacity -composite "${end_output}"; then
            error "Failed to apply fadeout effects to row r${row}_c${col}"
            return 1
        fi
    fi

    return 0
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
            -k|--keep-temp)
                KEEP_TEMP=1
                shift
                ;;
            -m|--margin)
                if [[ -z "${2:-}" ]]; then
                    error "Margin option requires a value"
                    usage
                    exit 1
                fi
                MARGIN_PERCENTAGE="$2"
                if [[ ! "$MARGIN_PERCENTAGE" =~ ^[0-9]+$ ]] || [[ "$MARGIN_PERCENTAGE" -lt 1 ]] || [[ "$MARGIN_PERCENTAGE" -gt 50 ]]; then
                    error "Margin must be between 1 and 50"
                    exit 1
                fi
                shift 2
                ;;
            -r|--rows)
                if [[ -z "${2:-}" ]]; then
                    error "Rows option requires a value"
                    usage
                    exit 1
                fi
                DESIRED_ROWS="$2"
                if [[ ! "$DESIRED_ROWS" =~ ^[0-9]+$ ]] || [[ "$DESIRED_ROWS" -lt 1 ]] || [[ "$DESIRED_ROWS" -gt $MAX_GRID_DIVISIONS ]]; then
                    error "Number of rows must be between 1 and $MAX_GRID_DIVISIONS"
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

# Main execution
main() {
    # Parse command line arguments (modifies global variables directly)
    parse_args "$@"
    
    # Validate input
    if [[ ${#FILES[@]} -lt 1 ]]; then
        error "No input files specified"
        usage
        exit 1
    fi

    # Check dependencies
    echo "Checking required dependencies..." >&2
    if ! check_dependencies; then
        exit 1
    fi

    # Get tool paths
    PANO_MODIFY_PATH=$(find_tool "pano_modify")
    HUGIN_EXECUTOR_PATH=$(find_tool "hugin_executor")
    MAGICK_PATH=$(find_tool "magick")

    # Process each PTO file
    local failed_files=()
    for file in "${FILES[@]}"; do
        if validate_pto_file "$file"; then
            if ! gen_grid "$file"; then
                failed_files+=("$file")
                error "Failed to process: $file"
            fi
        else
            failed_files+=("$file")
        fi
    done

    # Report results
    if [[ ${#failed_files[@]} -gt 0 ]]; then
        error "Failed to process ${#failed_files[@]} file(s): ${failed_files[*]}"
        exit 1
    fi
    
    echo "Successfully processed all files!" >&2
}

# Run main function with all arguments
main "$@"
