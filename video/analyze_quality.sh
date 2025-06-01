#!/bin/bash

# Video Quality Analysis Script
# Analyzes encoded videos against original using VMAF, SSIM, PSNR, and MS-SSIM

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check if required tools are available
check_dependencies() {
    local missing_deps=()
    
    if ! command -v ffmpeg &> /dev/null; then
        missing_deps+=("ffmpeg")
    fi
    
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    # Check if FFmpeg has VMAF support
    if ! ffmpeg -hide_banner -filters 2>/dev/null | grep -q "vmaf"; then
        echo -e "${YELLOW}Warning: FFmpeg doesn't have VMAF support. VMAF scores will be skipped.${NC}"
        echo "To enable VMAF, you may need to compile FFmpeg with libvmaf support."
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}"
        echo "Please install the missing tools and try again."
        exit 1
    fi
}

# Function to get video duration in seconds
get_duration() {
    local file="$1"
    ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null
}

# Function to analyze video quality
# Function to analyze video quality
analyze_quality() {
    local original="$1"
    local encoded="$2"
    local output_file="$3"
    
    echo -e "${BLUE}Analyzing: $(basename "$encoded")${NC}"
    
    # Create temporary files for metrics
    local vmaf_log=$(mktemp)
    local ssim_log=$(mktemp)
    local psnr_log=$(mktemp)
    local msssim_log=$(mktemp)
    
    # Get file sizes
    local orig_size=$(stat -c%s "$original" 2>/dev/null || stat -f%z "$original" 2>/dev/null || echo "0")
    local enc_size=$(stat -c%s "$encoded" 2>/dev/null || stat -f%z "$encoded" 2>/dev/null || echo "0")
    local compression_ratio=0
    
    if [ "$orig_size" -gt 0 ]; then
        compression_ratio=$(echo "scale=2; $enc_size / $orig_size" | bc -l)
    fi
    
    # Extract preset and CRF from filename
    local basename=$(basename "$encoded" .mp4)
    local preset=$(echo "$basename" | cut -d'.' -f2)
    local crf=$(echo "$basename" | cut -d'.' -f3)
    
    # Initialize metric values
    local vmaf_score="N/A"
    local ssim_score="N/A"
    local psnr_score="N/A"
    local msssim_score="N/A"
    
    # Run VMAF analysis (if supported)
    if ffmpeg -hide_banner -filters 2>/dev/null | grep -q "vmaf"; then
        echo "  Computing VMAF..."
        if ffmpeg -hide_banner -i "$encoded" -i "$original" \
            -lavfi "[0:v][1:v]libvmaf=log_path=${vmaf_log}:log_fmt=json" \
            -f null - &>/dev/null; then
            
            if [ -f "$vmaf_log" ] && [ -s "$vmaf_log" ]; then
                vmaf_score=$(python3 -c "
import json, sys
try:
    with open('$vmaf_log', 'r') as f:
        data = json.load(f)
    if 'pooled_metrics' in data and 'vmaf' in data['pooled_metrics']:
        print(f\"{data['pooled_metrics']['vmaf']['mean']:.2f}\")
    else:
        print('N/A')
except:
    print('N/A')
" 2>/dev/null)
            fi
        fi
    fi
    
    # Run SSIM analysis
    echo "  Computing SSIM..."
    if ffmpeg -hide_banner -i "$encoded" -i "$original" \
        -lavfi "[0:v][1:v]ssim=stats_file=${ssim_log}" \
        -f null - &>/dev/null; then
        
        if [ -f "$ssim_log" ] && [ -s "$ssim_log" ]; then
            # Extract the 'All' value (field 8) and compute the average, excluding 'inf'
            ssim_score=$(awk -F'[ :]+' '
                $8 ~ /^[0-1]\.[0-9]+$/ {sum += $8; count++}
                END {if (count > 0) printf "%.4f", sum/count; else print "N/A"}
            ' "$ssim_log" 2>/dev/null)
            [ -z "$ssim_score" ] && ssim_score="N/A"
        fi
    fi
    
    # Run PSNR analysis
    echo "  Computing PSNR..."
    if ffmpeg -hide_banner -i "$encoded" -i "$original" \
        -lavfi "[0:v][1:v]psnr=stats_file=${psnr_log}" \
        -f null - &>/dev/null; then
        
        if [ -f "$psnr_log" ] && [ -s "$psnr_log" ]; then
            # Extract the 'psnr_avg' value (field 6) and compute the average, excluding 'inf'
            psnr_score=$(awk -F'[ :]+' '
                $6 ~ /^[0-9]+\.[0-9]+$/ {sum += $6; count++}
                END {if (count > 0) printf "%.2f", sum/count; else print "N/A"}
            ' "$psnr_log" 2>/dev/null)
            [ -z "$psnr_score" ] && psnr_score="N/A"
        fi
    fi
    
    # Run MS-SSIM analysis (if available)
    echo "  Computing MS-SSIM..."
    if ffmpeg -hide_banner -filters 2>/dev/null | grep -q "msssim"; then
        if ffmpeg -hide_banner -i "$encoded" -i "$original" \
            -lavfi "[0:v][1:v]msssim=stats_file=${msssim_log}" \
            -f null - &>/dev/null; then
            
            if [ -f "$msssim_log" ] && [ -s "$msssim_log" ]; then
                msssim_score=$(awk -F'[ :]+' '
                    $8 ~ /^[0-1]\.[0-9]+$/ {sum += $8; count++}
                    END {if (count > 0) printf "%.4f", sum/count; else print "N/A"}
                ' "$msssim_log" 2>/dev/null)
                [ -z "$msssim_score" ] && msssim_score="N/A"
            fi
        fi
    fi
    
    # Convert file sizes to MB for readability
    local orig_size_mb=$(echo "scale=2; $orig_size / 1048576" | bc -l)
    local enc_size_mb=$(echo "scale=2; $enc_size / 1048576" | bc -l)
    
    # Write results to output file
    printf "%-10s %-3s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %s\n" \
        "$preset" "$crf" "$vmaf_score" "$ssim_score" "$psnr_score" "$msssim_score" \
        "$orig_size_mb" "$enc_size_mb" "$compression_ratio" "$(basename "$encoded")" >> "$output_file"
    
    # Cleanup temporary files
    rm -f "$vmaf_log" "$ssim_log" "$psnr_log" "$msssim_log"
}

# Function to generate summary statistics
generate_summary() {
    local results_file="$1"
    local summary_file="$2"
    
    echo "Generating summary statistics..."
    
    cat << EOF > "$summary_file"
# Video Quality Analysis Summary

## Metric Explanations:
- **VMAF**: Netflix's perceptual quality metric (0-100, higher is better)
  - 95+: Excellent quality, virtually indistinguishable from source
  - 80-95: Very good quality, minor artifacts
  - 60-80: Good quality, some noticeable artifacts
  - 40-60: Fair quality, artifacts visible
  - <40: Poor quality, significant artifacts

- **SSIM**: Structural Similarity Index (0-1, higher is better)
  - 0.95+: Excellent
  - 0.90-0.95: Very good
  - 0.80-0.90: Good
  - 0.70-0.80: Fair
  - <0.70: Poor

- **PSNR**: Peak Signal-to-Noise Ratio (dB, higher is better)
  - 40+: Excellent
  - 35-40: Very good
  - 30-35: Good
  - 25-30: Fair
  - <25: Poor

- **MS-SSIM**: Multi-Scale SSIM (0-1, higher is better, similar to SSIM)

## Best Quality/Size Ratios:
EOF

    # Find best combinations for different criteria
    if [ -f "$results_file" ]; then
        echo "" >> "$summary_file"
        echo "### Top 5 by VMAF Score:" >> "$summary_file"
        awk 'NR>2 && $3 != "N/A" {print $0}' "$results_file" | sort -k3 -nr | head -5 | \
        while read line; do
            echo "- $line" >> "$summary_file"
        done
        
        echo "" >> "$summary_file"
        echo "### Top 5 by Compression Ratio (smallest files):" >> "$summary_file"
        awk 'NR>2 && $9 != "N/A" {print $0}' "$results_file" | sort -k9 -n | head -5 | \
        while read line; do
            echo "- $line" >> "$summary_file"
        done
        
        echo "" >> "$summary_file"
        echo "### Best Quality/Size Balance (VMAF > 80, smallest file):" >> "$summary_file"
        awk 'NR>2 && $3 != "N/A" && $3 > 80 {print $0}' "$results_file" | sort -k9 -n | head -3 | \
        while read line; do
            echo "- $line" >> "$summary_file"
        done
    fi
}

# Main function
main() {
    local original_file="$1"
    local pattern="$2"
    
    # Check dependencies
    check_dependencies
    
    if [ ! -f "$original_file" ]; then
        echo -e "${RED}Error: Original file '$original_file' not found!${NC}"
        exit 1
    fi
    
    # Create results file with timestamp
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local results_file="quality_analysis_${timestamp}.txt"
    local summary_file="quality_summary_${timestamp}.md"
    
    echo -e "${GREEN}Starting quality analysis...${NC}"
    echo "Original file: $original_file"
    echo "Results will be saved to: $results_file"
    echo ""
    
    # Write header to results file
    printf "%-10s %-3s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %s\n" \
        "Preset" "CRF" "VMAF" "SSIM" "PSNR" "MS-SSIM" "Orig(MB)" "Enc(MB)" "Compression" "Filename" > "$results_file"
    
    printf "%-10s %-3s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %s\n" \
        "----------" "---" "--------" "--------" "--------" "--------" "--------" "--------" "------------" "----------------" >> "$results_file"
    
    # Find all encoded files
    local count=0
    if [ -n "$pattern" ]; then
        # Use provided pattern
        for encoded_file in $pattern; do
            if [ -f "$encoded_file" ]; then
                analyze_quality "$original_file" "$encoded_file" "$results_file"
                count=$((count + 1))
            fi
        done
    else
        # Auto-detect encoded files (assuming they follow the pattern from your encoding script)
        local basename=$(basename "$original_file" | sed 's/\.[^.]*$//')
        for encoded_file in "${basename}".*.*.mp4; do
            if [ -f "$encoded_file" ]; then
                analyze_quality "$original_file" "$encoded_file" "$results_file"
                count=$((count + 1))
            fi
        done
    fi
    
    if [ $count -eq 0 ]; then
        echo -e "${RED}No encoded files found matching the pattern!${NC}"
        echo "Make sure encoded files are in the current directory and follow the naming pattern:"
        echo "  original_basename.preset.crf.mp4"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}Analysis complete! Processed $count files.${NC}"
    echo -e "${BLUE}Results saved to: $results_file${NC}"
    
    # Generate summary
    generate_summary "$results_file" "$summary_file"
    echo -e "${BLUE}Summary saved to: $summary_file${NC}"
    
    # Display results
    echo ""
    echo -e "${YELLOW}Quality Analysis Results:${NC}"
    cat "$results_file"
    
    echo ""
    echo -e "${YELLOW}Quick Summary:${NC}"
    echo "Use 'cat $summary_file' to view detailed analysis and recommendations."
}

# Function to show usage
show_usage() {
    cat << EOF
Usage: $0 <original_video_file> [encoded_files_pattern]

Examples:
  $0 original.mp4                    # Auto-detect encoded files
  $0 original.mp4 "encoded_*.mp4"    # Use custom pattern
  $0 original.mp4 file1.mp4 file2.mp4 file3.mp4  # Specific files

This script analyzes video quality metrics comparing encoded files to the original:
- VMAF (Netflix's perceptual quality metric, 0-100)
- SSIM (Structural Similarity Index, 0-1)
- PSNR (Peak Signal-to-Noise Ratio, dB)
- MS-SSIM (Multi-Scale SSIM, 0-1)

Output includes compression ratios and recommendations for best quality/size balance.

Requirements:
- FFmpeg with libvmaf support (for VMAF scores)
- Python3 (for JSON parsing of VMAF results)
- bc (for calculations)
EOF
}

# Check command line arguments
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

# Run the analysis
if [ $# -eq 1 ]; then
    main "$1"
else
    main "$1" "${@:2}"
fi

