#!/bin/bash

#
# Smart HEVC/H.265 Encoder Bash Script for macOS
# Encodes if file is NOT HEVC OR if dimensions exceed 1280x720
# Copyright (c) 2025 Rodrigo Polo - rodrigopolo.com - The MIT License (MIT)
#
# Usage: ./ToHEVCAndResize.sh video_file.mp4

HEVC_CRF=20
HEVC_PRESET='superfast'

# Function to print error messages
error() {
  echo "ERROR: $1" >&2
  exit 1
}

# Function to copy tags, dates, permissions, etc.
copytags(){
  local source_file="$1"
  local target_file="$2"
  local tags
  local comment
  
  echo "Copying attributes from '$source_file' to '$target_file'..."
  
  # Copy file dates (access time, modification time)
  touch -r "$source_file" "$target_file"
  
  # Copy tags
  tags=$(mdls -plist - -name _kMDItemUserTags "$source_file" | plutil -convert json -o - - | sed -n 's/.*\[\([^]]*\)\].*/\1/p')
  if [[ -n "$tags" ]]; then
    xattr -w com.apple.metadata:_kMDItemUserTags '('$tags')' "$target_file"
  fi
  
  # # Copy Finder comments
  comment=$(osascript -e "tell application \"Finder\" to get comment of (POSIX file \"$source_file\" as alias)" 2>/dev/null)
  if [[ -n "$comment" ]]; then
    osascript -e "tell application \"Finder\" to set comment of (POSIX file \"$target_file\" as alias) to \"$comment\"" &> /dev/null
  fi

  # Copy permissions
  chmod --reference="$source_file" "$target_file" 2>/dev/null || \
  chmod "$(stat -f %p "$source_file" | cut -c 3-6)" "$target_file"
  
  echo "Attributes successfully copied."
}

encode() {
  # Enable error handling
  # set -e

  local INPUT_FILE="$1"

  # Check if a file argument was provided
  if [[ -z "$INPUT_FILE" ]]; then
    echo "Error: Video file must be specified." >&2
    return 1
  fi

  # Check if the input file exists
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Error: File '$INPUT_FILE' does not exist." >&2
    return 1
  fi

  echo "=== Processing: $INPUT_FILE ==="

  # Get file information with mediainfo
  echo "Analyzing file..."
  local JSON_INFO
  JSON_INFO=$(mediainfo --Output=JSON "$INPUT_FILE") || {
    echo "Error: Failed to analyze file with mediainfo." >&2
    return 1
  }

  # Check if the video already uses HEVC codec
  local HAS_HEVC
  HAS_HEVC=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="Video") | select(.Format=="HEVC" or .CodecID=="hvc1" or .CodecID=="hev1") | .Format' 2>/dev/null)
  
  # Get video dimensions
  local WIDTH HEIGHT
  WIDTH=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Width' 2>/dev/null | head -1)
  HEIGHT=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="Video") | .Height' 2>/dev/null | head -1)

  # Check dimensions and determine if oversized
  local IS_OVERSIZED=false
  if [[ -n "$WIDTH" && -n "$HEIGHT" && "$WIDTH" != "null" && "$HEIGHT" != "null" ]]; then
    # Convert to numbers and remove any non-numeric characters
    WIDTH=$(echo "$WIDTH" | sed 's/[^0-9]//g')
    HEIGHT=$(echo "$HEIGHT" | sed 's/[^0-9]//g')
    
    echo "Current dimensions: ${WIDTH}x${HEIGHT}"
    
    # Determine if video is horizontal or vertical and check if oversized
    if [[ "$WIDTH" -ge "$HEIGHT" ]]; then
      echo "Detected horizontal video"
      if [[ "$WIDTH" -gt 1280 || "$HEIGHT" -gt 720 ]]; then
        IS_OVERSIZED=true
        echo "Resolution exceeds 1280x720 limit."
      else
        echo "Resolution is within 1280x720 limit."
      fi
    else
      echo "Detected vertical video"
      if [[ "$WIDTH" -gt 720 || "$HEIGHT" -gt 1280 ]]; then
        IS_OVERSIZED=true
        echo "Resolution exceeds 720x1280 limit."
      else
        echo "Resolution is within 720x1280 limit."
      fi
    fi
  else
    echo "Could not determine video dimensions. Will proceed with encoding."
    IS_OVERSIZED=true  # Assume oversized if we can't determine dimensions
  fi

  # Decision logic: Encode if NOT HEVC OR oversized
  local SHOULD_ENCODE=false
  if [[ -z "$HAS_HEVC" ]]; then
    echo "File is NOT encoded with HEVC codec."
    SHOULD_ENCODE=true
  else
    echo "File is already encoded with HEVC codec."
  fi
  
  if [[ "$IS_OVERSIZED" == true ]]; then
    echo "File dimensions exceed limits."
    SHOULD_ENCODE=true
  fi

  if [[ "$SHOULD_ENCODE" == false ]]; then
    echo "File is already HEVC and within size limits. Skipping."
    return 0
  fi

  echo "Proceeding with encoding..."

  # Get base filename without extension
  local FILENAME BASENAME EXTENSION OUTPUT_DIR OUTPUT_FILE MIX_FILE
  FILENAME=$(basename -- "$INPUT_FILE")
  EXTENSION="${FILENAME##*.}"
  BASENAME="${FILENAME%.*}"
  OUTPUT_DIR=$(dirname "$INPUT_FILE")
  OUTPUT_FILE="$OUTPUT_DIR/${BASENAME}.hevc.mp4"
  MIX_FILE="$OUTPUT_DIR/${BASENAME}.done.mp4"

  # Get video duration or frame count for later verification
  local ORIGINAL_DURATION ORIGINAL_FRAME_COUNT
  ORIGINAL_DURATION=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="General") | .Duration' 2>/dev/null)
  ORIGINAL_FRAME_COUNT=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="Video") | .FrameCount' 2>/dev/null)

  # Determine resize filter
  local RESIZE_FILTER NEW_WIDTH NEW_HEIGHT
  if [[ "$IS_OVERSIZED" == true && -n "$WIDTH" && -n "$HEIGHT" && "$WIDTH" != "null" && "$HEIGHT" != "null" ]]; then
    # Determine if video is horizontal or vertical
    if [[ "$WIDTH" -ge "$HEIGHT" ]]; then
      echo "Resizing horizontal video"
      if [[ "$WIDTH" -gt "$HEIGHT" ]]; then
        NEW_WIDTH=1280
        NEW_HEIGHT=$(echo "scale=0; $HEIGHT * 1280 / $WIDTH" | bc)
        NEW_HEIGHT=$(( (NEW_HEIGHT + 1) / 2 * 2 ))
      else
        NEW_HEIGHT=720
        NEW_WIDTH=$(echo "scale=0; $WIDTH * 720 / $HEIGHT" | bc)
        NEW_WIDTH=$(( (NEW_WIDTH + 1) / 2 * 2 ))
      fi
      echo "New dimensions: ${NEW_WIDTH}x${NEW_HEIGHT}"
      RESIZE_FILTER="-vf 'scale=${NEW_WIDTH}:${NEW_HEIGHT},setsar=1:1'"
    else
      echo "Resizing vertical video"
      if [[ "$HEIGHT" -gt "$WIDTH" ]]; then
        NEW_HEIGHT=1280
        NEW_WIDTH=$(echo "scale=0; $WIDTH * 1280 / $HEIGHT" | bc)
        NEW_WIDTH=$(( (NEW_WIDTH + 1) / 2 * 2 ))
      else
        NEW_WIDTH=720
        NEW_HEIGHT=$(echo "scale=0; $HEIGHT * 720 / $WIDTH" | bc)
        NEW_HEIGHT=$(( (NEW_HEIGHT + 1) / 2 * 2 ))
      fi
      echo "New dimensions: ${NEW_WIDTH}x${NEW_HEIGHT}"
      RESIZE_FILTER="-vf 'scale=${NEW_WIDTH}:${NEW_HEIGHT},setsar=1:1'"
    fi
  else
    echo "No resizing needed or dimensions unavailable."
    RESIZE_FILTER=""
  fi

  # Create audio mapping options based on audio tracks
  local AUDIO_TRACKS AUDIO_CODECS TRACK_INDEX CHANNELS LANG
  AUDIO_TRACKS=$(echo "$JSON_INFO" | jq -r '.media.track[] | select(.["@type"]=="Audio") | .ID' 2>/dev/null)
  AUDIO_CODECS=""
  if [[ -z "$AUDIO_TRACKS" ]]; then
    echo "No audio tracks found. Creating video-only output."
  else
    echo "Processing audio tracks..."
    TRACK_INDEX=0
    while IFS= read -r track_id; do
      CHANNELS=$(echo "$JSON_INFO" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .Channels // .channel_s // .Channels_Original" 2>/dev/null)
      if [[ -z "$CHANNELS" || "$CHANNELS" == "null" ]]; then
        CHANNELS=2
        echo "  Could not determine channel count for track $track_id, assuming stereo." >&2
      fi
      if [[ "$CHANNELS" == "Mono" ]]; then
        CHANNELS=1
      elif [[ "$CHANNELS" == "Stereo" ]]; then
        CHANNELS=2
      elif [[ "$CHANNELS" == *"5.1"* || "$CHANNELS" == *"6"* ]]; then
        CHANNELS=6
      fi
      CHANNELS=$(echo "$CHANNELS" | sed 's/[^0-9]//g')
      LANG=$(echo "$JSON_INFO" | jq -r ".media.track[] | select(.\"@type\"==\"Audio\" and .ID==\"$track_id\") | .Language // \"und\"" 2>/dev/null)
      if [[ "$LANG" == "null" ]]; then
        LANG="und"
      fi
      echo "  Track ID: $track_id, Channels: $CHANNELS, Language: $LANG"
      if [[ $CHANNELS -eq 1 ]]; then
        AUDIO_CODECS+=" -c:a:$TRACK_INDEX aac -b:a:$TRACK_INDEX 64k -ac:a:$TRACK_INDEX 1"
        echo "  Setting mono AAC (64k) for track $track_id"
      elif [[ $CHANNELS -eq 2 ]]; then
        AUDIO_CODECS+=" -c:a:$TRACK_INDEX aac -b:a:$TRACK_INDEX 128k -ac:a:$TRACK_INDEX 2"
        echo "  Setting stereo AAC (128k) for track $track_id"
      else
        AUDIO_CODECS+=" -c:a:$TRACK_INDEX aac -b:a:$TRACK_INDEX 384k -ac:a:$TRACK_INDEX $CHANNELS"
        echo "  Setting $CHANNELS-channel AAC (384k) for track $track_id"
      fi
      if [[ "$LANG" != "und" ]]; then
        AUDIO_CODECS+=" -metadata:s:a:$TRACK_INDEX language=$LANG"
      fi
      TRACK_INDEX=$((TRACK_INDEX + 1))
    done <<< "$AUDIO_TRACKS"
  fi

  # Start conversion
  echo "Converting to HEVC with AAC audio..."
  echo "Output file will be: $OUTPUT_FILE"

  # Create ffmpeg command
  local FFMPEG_CMD
  FFMPEG_CMD="ffpb -hwaccel auto -y -hide_banner -i \"$INPUT_FILE\" -pix_fmt yuv420p -c:v libx265 -crf $HEVC_CRF -preset $HEVC_PRESET -tag:v hvc1 $RESIZE_FILTER $AUDIO_CODECS -movflags +faststart \"$OUTPUT_FILE\""
  echo "Executing: $FFMPEG_CMD"
  eval "$FFMPEG_CMD" || {
    echo "Error: Conversion failed." >&2
    [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
    return 1
  }

  echo "Conversion completed successfully."

  # Verify the output file
  echo "Verifying output file..."
  local OUTPUT_JSON OUTPUT_DURATION OUTPUT_FRAME_COUNT
  OUTPUT_JSON=$(mediainfo --Output=JSON "$OUTPUT_FILE") || {
    echo "Error: Failed to analyze output file with mediainfo." >&2
    return 1
  }
  OUTPUT_DURATION=$(echo "$OUTPUT_JSON" | jq -r '.media.track[] | select(.["@type"]=="General") | .Duration' 2>/dev/null)
  OUTPUT_FRAME_COUNT=$(echo "$OUTPUT_JSON" | jq -r '.media.track[] | select(.["@type"]=="Video") | .FrameCount' 2>/dev/null)

  echo "Original duration: $ORIGINAL_DURATION, Output duration: $OUTPUT_DURATION"
  echo "Original frames: $ORIGINAL_FRAME_COUNT, Output frames: $OUTPUT_FRAME_COUNT"

  if [[ -z "$OUTPUT_DURATION" || "$OUTPUT_DURATION" == "null" ]]; then
    echo "Error: Could not verify output duration." >&2
    [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
    return 1
  fi

  if [[ -n "$ORIGINAL_FRAME_COUNT" && "$ORIGINAL_FRAME_COUNT" != "null" && -n "$OUTPUT_FRAME_COUNT" && "$OUTPUT_FRAME_COUNT" != "null" ]]; then
    if [[ "$ORIGINAL_FRAME_COUNT" -eq "$OUTPUT_FRAME_COUNT" ]]; then
      echo "Frame count verification passed! Files have identical frame counts."
    else
      echo "Error: Frame count mismatch! Original: $ORIGINAL_FRAME_COUNT, Output: $OUTPUT_FRAME_COUNT" >&2
      DIFF_PERCENT=$(echo "scale=2; ($OUTPUT_FRAME_COUNT - $ORIGINAL_FRAME_COUNT) * 100 / $ORIGINAL_FRAME_COUNT" | bc | sed 's/^-//')
      echo "Frame count difference: $DIFF_PERCENT%" >&2
      # [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
      # return 1
    fi
  else
    DURATION_DIFF=$(echo "scale=6; ($OUTPUT_DURATION - $ORIGINAL_DURATION)/$ORIGINAL_DURATION * 100" | bc | tr -d -)
    if (( $(echo "$DURATION_DIFF < 0.5" | bc -l) )); then
      echo "Duration verification passed! Files have equivalent durations (within 0.5%)."
    else
      echo "Error: Duration mismatch exceeds threshold! Difference: $DURATION_DIFF%" >&2
      # [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
      # return 1
    fi
  fi

  # Show file size comparison
  local ORIGINAL_SIZE NEW_SIZE
  ORIGINAL_SIZE=$(du -h "$INPUT_FILE" 2>/dev/null | cut -f1 || echo "N/A")
  NEW_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
  echo "Original size: $ORIGINAL_SIZE, New size: $NEW_SIZE"

  # Copy attributes
  copytags "$INPUT_FILE" "$OUTPUT_FILE" || {
    echo "Error: Failed to copy attributes." >&2
    # [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
    # return 1
  }

  # Move original file
  mv "$INPUT_FILE" "$MIX_FILE" || {
    echo "Error: Failed to move original file to '$MIX_FILE'." >&2
    # [[ -f "$OUTPUT_FILE" ]] && rm "$OUTPUT_FILE"
    # return 1
  }

  echo "Processing complete! Original file moved to: $MIX_FILE"
  return 0
}

# Modifying the internal field separator
IFS=$'\t\n'

# Loop
for f in $@; do
  encode "$f"
done