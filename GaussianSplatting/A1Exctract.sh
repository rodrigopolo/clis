#!/usr/bin/env bash
# Extract perspective views from a 360 equirectangular video for COLMAP/Gaussian Splatting
#
# Usage:
#   ./AntiGravityExctract.sh [OPTIONS] <input_video>
#
# Options:
#   --fps <rate>           Frames per second to extract (default: 1)
#   --res <pixels>         Output resolution width and height (default: 2444)
#   --scenedir <path>     Override the output directory (default: same name as input video, no extension)
#   --keep-frames          Keep the intermediate equirectangular frames after processing
#   -h, --help             Show this help message

set -euo pipefail

# --- Defaults -----------------------------------------------------------------

FPS=1
RES=2444
OUTPUT_DIR_OVERRIDE=""
KEEP_FRAMES=0

# --- Views: "yaw:pitch" -------------------------------------------------------
VIEWS=(
    # Ring 1 - Horizontal (8 cameras, every 45°)
     "0:0"  #  0
    "45:0"  #  1
    "90:0"  #  2
   "135:0"  #  3
   "180:0"  #  4
  "-135:0"  #  5
   "-90:0"  #  6
   "-45:0"  #  7

    # Ring 2 - Down 45°, offset +22.5° (4 cameras, every 90°)
   "22.5:-45"  #  8
  "112.5:-45"  #  9
  "-157.5:-45" # 10
   "-67.5:-45" # 11

    # Nadir
    "0:-90" # 12
)

# --- Help ---------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -v '#!/' | grep -v '# -' | sed 's/^# \{0,1\}//'
  exit 0
}

# --- Argument parsing ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage ;;
    --fps)
      [[ -z "${2:-}" ]] && { echo "Error: --fps requires a value." >&2; exit 1; }
      FPS="$2"; shift 2 ;;
    --res)
      [[ -z "${2:-}" ]] && { echo "Error: --res requires a value." >&2; exit 1; }
      RES="$2"; shift 2 ;;
    --scenedir)
      [[ -z "${2:-}" ]] && { echo "Error: --scenedir requires a value." >&2; exit 1; }
      OUTPUT_DIR_OVERRIDE="$2"; shift 2 ;;
    --keep-frames)
      KEEP_FRAMES=1; shift ;;
    -*)
      echo "Error: Unknown option '$1'" >&2; exit 1 ;;
    *)
      INPUT_VIDEO="$1"; shift ;;
  esac
done

# --- Validate input file ------------------------------------------------------
if [[ -z "${INPUT_VIDEO:-}" ]]; then
  echo "Error: No input video specified." >&2
  usage
  exit 1
fi

if [[ ! -f "${INPUT_VIDEO}" ]]; then
  echo "Error: Input file '${INPUT_VIDEO}' not found." >&2
  exit 1
fi

INPUT_VIDEO=$(realpath "${INPUT_VIDEO}")
INPUT_BASE=$(basename "${INPUT_VIDEO%.*}")

# --- Resolve output directory -------------------------------------------------
OUTPUT_DIR="${OUTPUT_DIR_OVERRIDE:-${INPUT_VIDEO%.*}}"

# --- Setup output directories -------------------------------------------------
FRAMES_DIR="${OUTPUT_DIR}/frames"
mkdir -p "${OUTPUT_DIR}/images" "${OUTPUT_DIR}/sparse" "${FRAMES_DIR}"

# --- Cleanup trap -------------------------------------------------------------
cleanup_frames() {
  if [[ "${KEEP_FRAMES}" -eq 0 ]]; then
    echo "  Cleaning up intermediate frames..."
    rm -rf "${FRAMES_DIR}"
  else
    echo "  Keeping intermediate frames at: ${FRAMES_DIR}"
  fi
}
trap cleanup_frames EXIT

# --- Logging ------------------------------------------------------------------
LOG_FILE="${OUTPUT_DIR}/extraction_$(date +%Y%m%d_%H%M%S).log"
log() {
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local entry="[${timestamp}] $1"
  echo "${entry}" | tee -a "${LOG_FILE}"
}

# --- Summary ------------------------------------------------------------------
echo "================================================"
echo "  extract360 -- 360 video to perspective frames"
echo "================================================"
echo "  Input     : ${INPUT_VIDEO}"
echo "  Output    : ${OUTPUT_DIR}/images/"
echo "  Frames dir: ${FRAMES_DIR}"
echo "  FPS       : ${FPS}"
echo "  Resolution: ${RES}x${RES}"
echo "  Views     : ${#VIEWS[@]}"
echo "  Frames    : $([ "${KEEP_FRAMES}" -eq 1 ] && echo kept || echo removed) after processing"
echo "================================================"

# --- Pass 1: Extract equirectangular frames -----------------------------------
echo ""
echo "  [PASS 1] Extracting equirectangular sharp frames at ${FPS} fps..."
log "Sharp frames."
sharp-frames --fps "${FPS}" "${INPUT_VIDEO}" "${FRAMES_DIR}"
log "Sharp frames done."
FRAME_FILES=("${FRAMES_DIR}"/frame*.jpg)
TOTAL_FRAMES=${#FRAME_FILES[@]}
echo "  [PASS 1] Done. ${TOTAL_FRAMES} frame(s) extracted."

# --- Pass 2: Project each frame into perspective views -----------------------
echo ""
echo "  [PASS 2] Projecting frames into perspective views..."

EXTRACTED=0
i=0
for VIEW in "${VIEWS[@]}"; do
  yaw="${VIEW%%:*}"
  pitch="${VIEW##*:}"
  echo "  [EXTRACT] View ${i} yaw=${yaw} pitch=${pitch} (${TOTAL_FRAMES} frame(s))"
  log "EXTRACT: View ${i} yaw=${yaw} pitch=${pitch} (${TOTAL_FRAMES} frame(s))."
  ffmpeg -loglevel error -stats \
    -framerate 1 \
    -i "${FRAMES_DIR}/frame_%05d.jpg" \
    -vf "v360=e:rectilinear:yaw=${yaw}:pitch=${pitch}:v_fov=90:h_fov=90:w=${RES}:h=${RES}" \
    -q:v 2 \
    -start_number 0 \
    "${OUTPUT_DIR}/images/${INPUT_BASE}_frame%06d_View_${i}.jpg"
  EXTRACTED=$((EXTRACTED + 1))
  i=$((i + 1))
done
log "EXTRACT: Done."

# --- Done ---------------------------------------------------------------------
echo ""
echo "================================================"
echo "  Done. ${EXTRACTED} view(s) extracted."
IMAGE_COUNT=$(ls "${OUTPUT_DIR}/images/" | wc -l | tr -d ' ')
echo "  Total images in output: ${IMAGE_COUNT}"
echo "================================================"
