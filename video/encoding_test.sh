#!/bin/bash

# FFmpeg X265 Encoding Test Script
# Tests different presets and CRF values, capturing performance metrics

# Define presets and CRF values
# PRESETS=("veryslow" "slower" "slow" "medium" "fast" "faster" "veryfast" "superfast" "ultrafast")
# CRFS=(20 21 22 23 24 25 26 27 28)

PRESETS=("fast")
CRFS=(24)

# Function to encode video and capture metrics
encode_video() {
    local input="$1"
    local preset="$2"
    local crf="$3"
    
    # Get basename without extension
    local basename=$(basename "$input" | sed 's/\.[^.]*$//')
    
    # Set output filename
    local output="${basename}.${preset}.${crf}.mp4"
    
    # Temporary file for stderr capture
    local stderr_file=$(mktemp)
    
    # Array to store fps values
    local fps_values=()
    
    echo "Encoding: ${output} (preset: ${preset}, CRF: ${crf})"
    
    # Run FFmpeg and capture stderr
    ffmpeg -hwaccel auto -y -hide_banner -i "${input}" \
        -pix_fmt yuv420p -vf "scale=1280:720" \
        -c:v libx265 -tag:v hvc1 -preset "${preset}" -crf "${crf}" \
        -an -movflags +faststart "${output}" 2> "${stderr_file}"
    
    # Check if encoding was successful
    if [ $? -ne 0 ]; then
        echo "Error: Encoding failed for ${output}"
        rm -f "${stderr_file}"
        return 1
    fi
    
    # Extract fps values from stderr
    while IFS= read -r line; do
        if [[ $line =~ fps=([0-9 .]+) ]]; then
            fps_values+=("${BASH_REMATCH[1]}")
        fi
    done < "${stderr_file}"
    
    # Calculate average fps
    local total_fps=0
    local count=0
    for fps in "${fps_values[@]}"; do
        total_fps=$(echo "$total_fps + $fps" | bc -l)
        count=$((count + 1))
    done
    
    local avg_fps=0
    if [ $count -gt 0 ]; then
        avg_fps=$(echo "scale=2; $total_fps / $count" | bc -l)
    fi
    
    # Get file size in bytes
    local filesize=0
    if [ -f "${output}" ]; then
        filesize=$(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null || echo "0")
    fi
    
    # Output results
    printf "%-10s %-3s %-8s %s\n" "${preset}" "${crf}" "${avg_fps}" "${filesize}" >&2
    
    # Cleanup
    rm -f "${stderr_file}"
}

# Main function to run all tests
run_tests() {
    local input="$1"
    
    if [ ! -f "$input" ]; then
        echo "Error: Input file '$input' not found!"
        exit 1
    fi
    
    # Check if bc is available for calculations
    if ! command -v bc &> /dev/null; then
        echo "Error: 'bc' calculator is required but not installed."
        echo "Please install bc: sudo apt-get install bc (Ubuntu/Debian) or brew install bc (macOS)"
        exit 1
    fi
    
    echo "Starting FFmpeg X265 encoding tests..."
    echo "Input file: $input"
    echo ""
    printf "%-10s %-3s %-8s %s\n" "Preset" "CRF" "Avg FPS" "File Size (bytes)" >&2
    printf "%-10s %-3s %-8s %s\n" "----------" "---" "--------" "-------------------" >&2
    
    # Loop through all combinations
    for preset in "${PRESETS[@]}"; do
        for crf in "${CRFS[@]}"; do
            encode_video "$input" "$preset" "$crf"
        done
    done
    
    echo ""
    echo "All encoding tests completed!"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 <input_video_file>"
    echo ""
    echo "This script will encode the input video with all combinations of:"
    echo "Presets: ${PRESETS[*]}"
    echo "CRF values: ${CRFS[*]}"
    echo ""
    echo "Output format: input_basename.preset.crf.mp4"
    echo "Results show: Preset, CRF, Average FPS, File Size in bytes"
}

# Check command line arguments
if [ $# -ne 1 ]; then
    show_usage
    exit 1
fi

# Run the tests
run_tests "$1"

