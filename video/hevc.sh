#!/usr/bin/env bash

# Smart HEVC/H.265 Encoder Bash Script for macOS
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

# Set tolerance in seconds
readonly TOLERANCE=1
readonly COLORS=("no" "orange" "red" "yellow" "blue" "purple" "green" "gray")

# Global variables for tool paths
MEDIAINFO_PATH=""
FFMPEG_PATH=""
FFPB_PATH=""
FFTOOL=""
FFTOOLN=""
FILES=()

# Command line options
HEVC_CRF=20
HEVC_PRESET='superfast'
SKIP=0
VERBOSE=0
COPY_DATES=0
COPY_TAGS=0
COPY_COMMENTS=0
COPY_PERMISSIONS=0
OUTPUT_SUFFIX=".hevc"
ORIGINAL_SUFFIX=".done"
COLOR_TAG="green"
SUCCESS_ACTION=""
MAX_WIDTH=0
MAX_HEIGHT=0
FLIP_ROTATE=""


# Helper function to convert 0/1 to Off/On
bool_to_text() {
    case "$1" in
        0) echo "Off" ;;
        1) echo "On" ;;
        *) echo "$1" ;;  # fallback for other values
    esac
}

# Function to print usage
usage() {
    cat << EOF >&2
Usage: $(basename "$0") [options] <input1.mov> [input2.mp4...]

Options:
  -h, --help                  Show this help message and exit
  -v, --verbose               Enable verbose output
                              * Default: $(bool_to_text "$VERBOSE")
  -s, --size <width>x<height> Set maximum video dimensions
                              (e.g., 3840x2160; default: ${MAX_WIDTH}x${MAX_HEIGHT})
  -c, --crf <val>             Set HEVC CRF value
                              20-28, default: ${HEVC_CRF}
  -p, --preset <preset>       Set HEVC preset
                              ultrafast, superfast, veryfast, faster, fast,
                              medium, slow, slower, veryslow
                              * Default: ${HEVC_PRESET}
  -a, --after-encode <action> Action after encoding:
                              label, rename, delete; default: none
  -t, --tag-color <color>     Set Finder color tag for --after-encode=label
                              orange, red, yellow, blue, purple, green, gray;
                              * Default: ${COLOR_TAG}
  --skip                      Skip encoding if it is already HEVC and dimensions
                              are already meet
  --osufix <suffix>           Set output suffix (default: ${OUTPUT_SUFFIX})
  --isufix <suffix>           Set input suffix after encoding (default: ${ORIGINAL_SUFFIX})
  --dates                     Copy file modification dates to output
                              * Default: $(bool_to_text "$COPY_DATES")
  --tags                      Copy Finder tags to output
                              * Default: $(bool_to_text "$COPY_TAGS")
  --comments                  Copy Finder comments to output
                              * Default: $(bool_to_text "$COPY_COMMENTS")
  --permissions               Copy file permissions to output
                              * Default: $(bool_to_text "$COPY_PERMISSIONS")

Arguments:
  <file1> [file2 ...]        One or more input video files to process

Examples:
  $(basename "$0") --crf 22 --preset fast --osufix .hevc video.mp4
  $(basename "$0") --after-encode label --tag-color blue input.mkv
  $(basename "$0") --tags --dates blue input.mov

EOF
}

# Verbose logging function
log() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "[$(date '+%H:%M:%S')] $*" >&2
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
        "/opt/homebrew/bin/${tool_name}"
        "$HOME/.local/bin/${tool_name}"
        "/usr/local/bin/${tool_name}"
        "/usr/bin/${tool_name}"
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
    local tools=("mediainfo" "ffmpeg")

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
                "mediainfo")
                    echo -e "  - Install MediaInfo:\n    brew install mediainfo" >&2
                    ;;
                "ffmpeg")
                    echo -e "  - Install FFmpeg:\n    brew install ffmpeg" >&2
                    ;;
            esac
        done
        return 1
    fi
    
    log "All dependencies found"
    return 0
}

# Validate input file
validate_video_file() {
    local file="$1"
    
    if [[ ! -f "$file" ]]; then
        error "File '$file' does not exist"
        return 1
    fi
    
    if [[ ! -r "$file" ]]; then
        error "File '$file' is not readable"
        return 1
    fi
    
    if ! mediainfo "$file" | grep -q '^Video$'; then
        error "File '$file' doesn't appear to be a valid video"
        return 1
    fi
    
    return 0
}

# Function to copy tags, dates, permissions, etc.
copy_attributes(){
    local source_file="$1"
    local target_file="$2"
    local tags comment
    
    # Copy file dates
    if [[ $COPY_DATES -eq 1 ]]; then
        touch -r "$source_file" "$target_file"
    fi

    # Copy tags
    if [[ $COPY_TAGS -eq 1 ]]; then
        tags=$(mdls -plist - -name _kMDItemUserTags "$source_file" | plutil -convert json -o - - | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
        if [[ -n "$tags" ]]; then
            xattr -w com.apple.metadata:_kMDItemUserTags '('$tags')' "$target_file"
        fi
    fi

    # Copy Finder comments
    if [[ $COPY_COMMENTS -eq 1 ]]; then
        comment=$(osascript -e "tell application \"Finder\" to get comment of (POSIX file \"$source_file\" as alias)" 2>/dev/null)
        if [[ -n "$comment" ]]; then
            osascript -e "tell application \"Finder\" to set comment of (POSIX file \"$target_file\" as alias) to \"$comment\"" &> /dev/null
        fi
    fi

    if [[ $COPY_PERMISSIONS -eq 1 ]]; then
        # Copy permissions
        chmod --reference="$source_file" "$target_file" 2>/dev/null || \
        chmod "$(stat -f %p "$source_file" | cut -c 3-6)" "$target_file"
    fi

}

# Set color tag to file
set_color_tag() {
    local file_path="$1" color_name="$2"
    
    # Find the color index
    local color_index=0
    for ((i=0; i<${#COLORS[@]}; i++)); do
        if [[ "${COLORS[i]}" == "$color_name" ]]; then
            color_index="$i"
        fi
    done

    # Set the color label using osascript
    osascript -e "tell application \"Finder\" to set label index of (POSIX file \"$file_path\" as alias) to $color_index" >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "Set color label '$color_name' (index $color_index) for '$file_path'"
        return 0
    else
        echo "Error: Failed to set color label for '$file_path'" >&2
        return 1
    fi
}

# Actions to take after encoding
after_encoding(){
    local input_file="$1"
    local input_dir="$2"
    local input_name="$3"
    local input_ext="$4"

    if [ -n "$SUCCESS_ACTION" ]; then
      case "$SUCCESS_ACTION" in
        label)
          log "Setting color tag"
          set_color_tag "${input_dir}/${input_name}.${input_ext}" "${COLOR_TAG}"
          ;;
        rename)
          echo "⚠️ Renaming original" >&2
          mv "${input_file}" "${input_dir}/${input_name}${ORIGINAL_SUFFIX}.${input_ext}"
          ;;
        delete)
          echo "❗️ Deleting original" >&2
          rm "${input_dir}/${input_name}.${input_ext}"
          ;;
        *)
          # No action for unknown values
          ;;
      esac
    fi
}

# To check for rotation
get_rotate_filter() {
    if [ -n "$FLIP_ROTATE" ]; then
        case "$FLIP_ROTATE" in
            right)
                echo "transpose=1"
                ;;
            left)
                echo "transpose=2"
                ;;
            upside-down)
                echo "transpose=1,transpose=1"
                ;;
            horizontal)
                echo "hflip"
                ;;
            vertical)
                echo "vflip"
                ;;
            *)
                echo ""
                ;;
        esac
    fi
    return 0
}

# To check size limits
get_resize_filter() {
    local input_width="$1" input_height="$2"
    local new_width new_height resize_filter=""

    # Check if dimensions are valid
    if [[ -z "$input_width" || -z "$input_height" || "$input_width" == "null" || "$input_height" == "null" ]]; then
        log "Could not determine video dimensions."
        return 1
    fi

    # Convert to numbers and remove any non-numeric characters
    input_width=$(echo "$input_width" | sed 's/[^0-9]//g')
    input_height=$(echo "$input_height" | sed 's/[^0-9]//g')

    log "Current dimensions: ${input_width}x${input_height}"

    # Determine if video is horizontal or vertical and check if oversized
    if [[ "$input_width" -ge "$input_height" ]]; then
        log "Horizontal video"

        if [[ "$input_width" -gt ${MAX_WIDTH} || "$input_height" -gt ${MAX_HEIGHT} ]]; then
            log "Resolution exceeds ${MAX_WIDTH}x${MAX_HEIGHT} limit."
            new_width=${MAX_WIDTH}
            new_height=$(echo "scale=0; $input_height * ${MAX_WIDTH} / $input_width" | bc)
            new_height=$(( (new_height) / 2 * 2 ))
            resize_filter="scale=${new_width}:${new_height},setsar=1:1"
        fi
    else
        log "Vertical video"

        if [[ "$input_width" -gt ${MAX_HEIGHT} || "$input_height" -gt ${MAX_WIDTH} ]]; then
            log "Resolution exceeds ${MAX_HEIGHT}x${MAX_WIDTH} limit."
            new_height=${MAX_WIDTH}
            new_width=$(echo "scale=0; $input_width * ${MAX_WIDTH} / $input_height" | bc)
            new_width=$(( (new_width) / 2 * 2 ))
            resize_filter="scale=${new_width}:${new_height},setsar=1:1"
        fi
    fi

    # Output resize_filter (and optionally set is_oversized globally)
    echo "$resize_filter"
    return 0
}

# Function to deal with audio channels and codecs
get_audio_codecs() {
    local json_info="$1"
    local audio_codecs="" audio_track_index=0
    local audio_tracks audio_channels audio_lang audio_format audio_layout

    # Get audio tracks
    audio_tracks=$(echo "$json_info" | jq -r '.media.track[] | select(.["@type"]=="Audio") | .ID' 2>/dev/null)

    if [[ -z "$audio_tracks" ]]; then
        log "No audio tracks found. Creating video-only output."
        return 0
    fi

    log "Processing audio tracks..."
    while IFS= read -r track_id; do
        # Get audio format, channels, and layout
        audio_format=$(echo "$json_info" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .Format // \"Unknown\"" 2>/dev/null)
        audio_channels=$(echo "$json_info" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .Channels // .channel_s // .Channels_Original" 2>/dev/null)
        audio_layout=$(echo "$json_info" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .ChannelLayout // .ChannelPositions // \"\"" 2>/dev/null)
        audio_lang=$(echo "$json_info" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .Language // \"und\"" 2>/dev/null)
        
        # Clean up variables
        if [[ -z "$audio_channels" || "$audio_channels" == "null" ]]; then
            audio_channels=2
            log "  Could not determine channel count for track $track_id, assuming stereo."
        fi
        if [[ "$audio_lang" == "null" ]]; then
            audio_lang="und"
        fi
        if [[ "$audio_layout" == "null" ]]; then
            audio_layout=""
        fi

        # Convert channels to numeric if needed
        if [[ "$audio_channels" == "Mono" ]]; then
            audio_channels=1
        elif [[ "$audio_channels" == "Stereo" ]]; then
            audio_channels=2
        fi
        
        # Extract numeric value
        audio_channels=$(echo "$audio_channels" | sed 's/[^0-9]//g')
        
        log "  Track ID: $track_id, Format: $audio_format, Channels: $audio_channels, Layout: $audio_layout, Language: $audio_lang"
        
        # Determine encoding parameters based on channel count and format
        if [[ $audio_channels -eq 1 ]]; then
            # Mono
            audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 64k -ac:a:$audio_track_index 1"
            log "  Setting mono AAC (64k) for track $track_id"
            
        elif [[ $audio_channels -eq 2 ]]; then
            # Stereo
            audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 128k -ac:a:$audio_track_index 2"
            log "  Setting stereo AAC (128k) for track $track_id"
            
        elif [[ $audio_channels -eq 6 ]]; then
            # 5.1 surround - handle different formats
            case "$audio_format" in
                "AC-3"|"E-AC-3")
                    # AC-3 and E-AC-3 typically use: L R C LFE Ls Rs
                    audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 384k"
                    audio_codecs+=" -filter:a:$audio_track_index \"channelmap=channel_layout=5.1\""
                    log "  Setting 5.1 AAC (384k) with AC-3 channel mapping for track $track_id"
                    ;;
                "DTS")
                    # DTS typically uses: C L R Ls Rs LFE - needs remapping
                    audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 384k"
                    audio_codecs+=" -filter:a:$audio_track_index \"channelmap=channel_layout=5.1:map=1|2|0|5|3|4\""
                    log "  Setting 5.1 AAC (384k) with DTS channel remapping for track $track_id"
                    ;;
                *)
                    # Generic 5.1 handling
                    audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 384k"
                    audio_codecs+=" -filter:a:$audio_track_index \"channelmap=channel_layout=5.1\""
                    log "  Setting 5.1 AAC (384k) with generic 5.1 mapping for track $track_id"
                    ;;
            esac
            
        elif [[ $audio_channels -gt 6 ]]; then
            # More than 5.1 - downmix to 5.1
            log "  Track $track_id has $audio_channels channels, downmixing to 5.1"
            audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 384k"
            audio_codecs+=" -filter:a:$audio_track_index \"pan=5.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=SL+BL|BR=SR+BR\""
            log "  Setting downmixed 5.1 AAC (384k) for track $track_id"
            
        else
            # Handle other channel counts (3, 4, 5) - convert to stereo
            log "  Track $track_id has $audio_channels channels, downmixing to stereo"
            audio_codecs+=" -c:a:$audio_track_index aac -b:a:$audio_track_index 128k -ac:a:$audio_track_index 2"
            log "  Setting downmixed stereo AAC (128k) for track $track_id"
        fi
        
        # Add language metadata if available
        if [[ "$audio_lang" != "und" ]]; then
            audio_codecs+=" -metadata:s:a:$audio_track_index language=$audio_lang"
        fi
        
        audio_track_index=$((audio_track_index + 1))
    done <<< "$audio_tracks"

    echo "$audio_codecs"
    return 0
}

# Encode video
#!/bin/bash

# Encodes a video file to HEVC
encode() {
    local input_file="$1"
    local input_full_path input_dir input_base input_ext input_name output_file
    local json_info has_hevc input_width input_height original_duration
    local resize_filter rotate_filter video_filters audio_codecs ffmpeg_cmd
    local output_json output_duration abs_diff within_tolerance

    # Resolve file paths and components
    input_full_path=$(realpath "$input_file")                    # Full path: /path/to/file/video.mp4
    input_dir=$(dirname "$input_full_path")                      # Directory: /path/to/file
    input_base=$(basename "$input_full_path")                    # Filename: video.mp4
    input_ext="${input_base##*.}"                                # Extension: mp4
    input_name="${input_base%.*}"                                # Name: video
    output_file="${input_dir}/${input_name}${OUTPUT_SUFFIX}.mp4" # Output: /path/to/file/video.hevc.mp4

    log "=== Processing: $input_file ==="

    # Analyze input file with mediainfo
    json_info=$(mediainfo --Output=JSON "$input_file") || {
        error "Failed to analyze file with mediainfo."
        return 1
    }

    # Check for HEVC codec
    has_hevc=$(echo "$json_info" | jq -r '.media.track[] | select(.["@type"]=="Video") | select(.Format=="HEVC" or .CodecID=="hvc1" or .CodecID=="hev1") | .Format' 2>/dev/null)

    # Extract video dimensions and duration
    input_width=$(echo "$json_info" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Width' 2>/dev/null | head -1)
    input_height=$(echo "$json_info" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Height' 2>/dev/null | head -1)
    original_duration=$(echo "$json_info" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Duration' 2>/dev/null)

    # Get resize and rotate filters if defined in the args
    if [[ -n "$MAX_WIDTH" && -n "$MAX_HEIGHT" && "$MAX_WIDTH" =~ ^[0-9]+$ && "$MAX_HEIGHT" =~ ^[0-9]+$ && "$MAX_WIDTH" -gt 0 && "$MAX_HEIGHT" -gt 0 ]]; then
        resize_filter=$(get_resize_filter "$input_width" "$input_height")
    else
        resize_filter=""
    fi
    rotate_filter=$(get_rotate_filter)

    # Log encoding decision
    if [[ -z "$has_hevc" ]]; then
        log "File is not encoded with HEVC codec."
    fi

    # Skip encoding if already HEVC and no resizing needed
    #if [[ -n "$has_hevc" && -z "$resize_filter" ]]; then
    if [[ "$SKIP" == 1 && -n "$has_hevc" && -z "$resize_filter" ]]; then
        echo "Video is already HEVC and does not require resizing, skipping encoding." >&2
        return 0
    fi

    # Get audio codecs
    audio_codecs=$(get_audio_codecs "$json_info")

    # Log encoding details
    echo "Encoding: ${input_file}" >&2
    echo "Output:   ${output_file}" >&2

    # Build video filters
    local filters=()
    [[ -n "$resize_filter" ]] && filters+=("$resize_filter")
    [[ -n "$rotate_filter" ]] && filters+=("$rotate_filter")
    video_filters=$([[ ${#filters[@]} -gt 0 ]] && echo "-vf '$(IFS=','; echo "${filters[*]}")'" || echo "")

    # Construct ffmpeg command
    ffmpeg_cmd=" -hwaccel auto -y -hide_banner -i \"$input_file\" -pix_fmt yuv420p -c:v libx265 -crf $HEVC_CRF -preset $HEVC_PRESET -tag:v hvc1 $video_filters $audio_codecs -movflags +faststart \"$output_file\""

    # Log formatted command
    local formatted_cmd
    formatted_cmd=$(echo "${FFTOOL}${ffmpeg_cmd}" | sed 's/ -/ \\\n  -/g' | sed 's/faststart \"/faststart \\\n  "/g')
    log "Executing:\n$formatted_cmd"

    # Execute ffmpeg
    eval "${FFTOOL}${ffmpeg_cmd}" || {
        error "Error: Conversion failed."
        [[ -f "$output_file" ]] && rm -f "$output_file"
        return 1
    }

    log "Conversion completed, verifying output file."

    # Verify output file
    output_json=$(mediainfo --Output=JSON "$output_file") || {
        error "Failed to analyze output file with mediainfo."
        return 1
    }

    # Check duration tolerance
    output_duration=$(echo "$output_json" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Duration' 2>/dev/null)
    abs_diff=$(awk -v a="$original_duration" -v b="$output_duration" 'BEGIN { diff = a - b; print (diff < 0 ? -diff : diff) }')
    within_tolerance=$(awk -v d="$abs_diff" -v t="$TOLERANCE" 'BEGIN { print (d <= t) ? "yes" : "no" }')

    log "Original duration: $original_duration, Output duration: $output_duration"

    if [[ "$within_tolerance" = "yes" ]]; then
        log "✅ Duration difference is within tolerance."
        copy_attributes "$input_file" "$output_file"
        after_encoding "$input_file" "$input_dir" "$input_name" "$input_ext"
    else
        error "❌ Duration difference exceeds tolerance!"
        return 1
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
            -c|--crf)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "CRF option requires a value"
                    exit 1
                fi
                HEVC_CRF="$2"
                if [[ ! "$HEVC_CRF" =~ ^[0-9]+$ ]] || [[ "$HEVC_CRF" -lt 20 ]] || [[ "$HEVC_CRF" -gt 28 ]]; then
                    usage
                    error "CRF must be between 20 and 28"
                    exit 1
                fi
                shift 2
                ;;
            -p|--preset)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Preset option requires a value"
                    exit 1
                fi
                case "$2" in
                    ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow)
                        HEVC_PRESET="$2"
                        ;;
                    *)
                        usage
                        error "Preset must be one of: ultrafast, superfast, veryfast, faster, fast, medium, slow, slower or veryslow"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -s|--size)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Max size option requires a value"
                    exit 1
                fi
                dim="$2"

                # Check if the size matches the pattern NUMBERxNUMBER
                if [[ ! $dim =~ ^[0-9]+x[0-9]+$ ]]; then
                    usage
                    error "Size must be in the format NUMBERxNUMBER (e.g., 3840x2160)"
                    exit 1
                fi

                # Extract the two numbers using parameter expansion or cut
                MAX_WIDTH=${dim%x*}  # Get everything before 'x'
                MAX_HEIGHT=${dim#*x} # Get everything after 'x'

                # Validate MAX_WIDTH and MAX_HEIGHT
                if [[ -z "$MAX_WIDTH" || -z "$MAX_HEIGHT" || ! "$MAX_WIDTH" =~ ^[0-9]+$ || ! "$MAX_HEIGHT" =~ ^[0-9]+$ || "$MAX_WIDTH" -le 0 || "$MAX_HEIGHT" -le 0 ]]; then
                    usage
                    error "Size must be in the format NUMBERxNUMBER with positive integers (e.g., 3840x2160)"
                    exit 1
                fi

                shift 2
                ;;
            -r|--flip-rotate)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Flip-rotate option requires a value"
                    exit 1
                fi
                case "$2" in
                    right|left|upside-down|horizontal|vertical)
                        FLIP_ROTATE="$2"
                        ;;
                    *)
                        usage
                        error "Flip-rotate must be one of: right, left, upside-down, horizontal, or vertical"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            --osufix)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Output suffix requires a value"
                    exit 1
                fi
                OUTPUT_SUFFIX="$2"
                shopt -s nocasematch
                if [[ ! "$OUTPUT_SUFFIX" =~ [a-z] || ! "$OUTPUT_SUFFIX" =~ ^[a-zA-Z0-9._]+$ ]]; then
                    usage
                    error "Output suffix must contain at least one letter and only alphanumeric characters, dots, or underscores"
                    shopt -u nocasematch
                    exit 1
                fi
                shopt -u nocasematch
                shift 2
                ;;
            --isufix)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Input suffix requires a value"
                    exit 1
                fi
                ORIGINAL_SUFFIX="$2"
                shopt -s nocasematch
                if [[ ! "$ORIGINAL_SUFFIX" =~ [a-z] || ! "$ORIGINAL_SUFFIX" =~ ^[a-zA-Z0-9._]+$ ]]; then
                    usage
                    error "Input suffix must contain at least one letter and only alphanumeric characters, dots, or underscores"
                    shopt -u nocasematch
                    exit 1
                fi
                shopt -u nocasematch
                shift 2
                ;;
            --skip)
                SKIP=1
                shift
                ;;
            --dates)
                COPY_DATES=1
                shift
                ;;
            --tags)
                COPY_TAGS=1
                shift
                ;;
            --comments)
                COPY_COMMENTS=1
                shift
                ;;
            --permissions)
                COPY_PERMISSIONS=1
                shift
                ;;
            -a|--after-encode)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Preset option requires a value"
                    exit 1
                fi
                case "$2" in
                    label|rename|delete)
                        SUCCESS_ACTION="$2"
                        ;;
                    *)
                        usage
                        error "Action after encoding must be one of: label, rename, delete."
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -t|--tag-color)
                if [[ -z "${2:-}" ]]; then
                    usage
                    error "Preset option requires a value"
                    exit 1
                fi
                case "$2" in
                    orange|red|yellow|blue|purple|green|gray)
                        COLOR_TAG="$2"
                        ;;
                    *)
                        usage
                        error "Color tag must be one of: orange, red, yellow, blue, purple, green or gray"
                        exit 1
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                usage
                error "Unknown option: $1"
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
    log "Checking required dependencies..."
    if ! check_dependencies; then
        exit 1
    fi

    # Get tool paths
    MEDIAINFO_PATH=$(find_tool "mediainfo")
    FFMPEG_PATH=$(find_tool "ffmpeg")
    
    # Check if ffpb is installed
    if FFPB_PATH=$(find_tool "ffpb"); then
        FFTOOL="$FFPB_PATH"
        FFTOOLN="ffpb"
    else
        FFTOOL="$FFMPEG_PATH"
        FFTOOLN="ffmpeg"
    fi

    # Process each video
    local failed_files=()
    for file in "${FILES[@]}"; do
        if validate_video_file "$file"; then
            if ! encode "$file"; then
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

