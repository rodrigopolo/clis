#!/usr/bin/env bash
# RigExtract.sh — Extract perspective views from a 360 equirectangular video for COLMAP/Gaussian Splatting
#                 Designed for a 3-camera vertical rig (high / mid / low elevation).
#
# Usage:
#   ./RigExtract.sh --elevation <level> [OPTIONS] <input_video>
#
# Required:
#   --elevation <level>    Camera elevation in the rig: high | mid | low
#
# Options:
#   --fps <rate>           Frames per second to extract (default: 1)
#   --res <pixels>         Output resolution width and height (default: 2444)
#   --scenedir <path>     Override the output directory (default: same name as input video, no extension)
#   --keep-frames          Keep the intermediate equirectangular frames after processing
#   -h, --help             Show this help message
#
# Elevation view sets:
#   high  — 8 views: horizontal ring tilted down 30° on the forward half, level on the back half
#   mid   — 5 views: level horizontal ring (front-facing arc)
#   low   — 5 views: horizontal ring tilted up 30° (front-facing arc)
#
# Workflow — run once per camera, pointing all outputs to the same --scenedir:
#   ./RigExtract.sh --elevation high --scenedir ./scene high_cam.mp4
#   ./RigExtract.sh --elevation mid  --scenedir ./scene mid_cam.mp4
#   ./RigExtract.sh --elevation low  --scenedir ./scene low_cam.mp4
# Then feed ./scene/images/ to COLMAP.

set -euo pipefail

# --- Defaults -----------------------------------------------------------------
FPS=1
RES=2444
ELEVATION=""
OUTPUT_DIR_OVERRIDE=""
KEEP_FRAMES=0

# --- View sets: "yaw:pitch" ---------------------------------------------------
#
# HIGH camera — 8 views
#   Forward half (0°, ±45°, ±90°) tilted down 30° to look into the scene below.
#   Back half (±135°, 180°) kept level to cover the horizon behind the rig.
VIEWS_HIGH=(
    "0:-30"    #  0
   "45:-30"    #  1
   "90:-30"    #  2
  "135:0"      #  3
  "180:0"      #  4
  "-135:0"     #  5
  "-90:-30"    #  6
  "-45:-30"    #  7
)

# MID camera — 5 views
#   Level horizontal arc covering the front-facing 180°.
VIEWS_MID=(
    "0:0"      #  8
   "45:0"      #  9
   "90:0"      # 10
  "-90:0"      # 11
  "-45:0"      # 12
)

# LOW camera — 5 views
#   Same arc as mid but tilted up 30° to look into the scene above.
VIEWS_LOW=(
    "0:30"     # 13
   "45:30"     # 14
   "90:30"     # 15
  "-90:30"     # 16
  "-45:30"     # 17
)

# --- Help ---------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

# --- Argument parsing ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage ;;
    --elevation)
      [[ -z "${2:-}" ]] && { echo "Error: --elevation requires a value." >&2; exit 1; }
      ELEVATION="$2"; shift 2 ;;
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

# --- Validate elevation -------------------------------------------------------
if [[ -z "${ELEVATION}" ]]; then
  echo "Error: --elevation is required. Valid values: high, mid, low" >&2
  exit 1
fi

case "${ELEVATION}" in
  high) VIEWS=("${VIEWS_HIGH[@]}") ;;
  mid)  VIEWS=("${VIEWS_MID[@]}") ;;
  low)  VIEWS=("${VIEWS_LOW[@]}") ;;
  *)
    echo "Error: Unknown elevation '${ELEVATION}'. Valid values: high, mid, low" >&2
    exit 1 ;;
esac

# --- Validate input file ------------------------------------------------------
if [[ -z "${INPUT_VIDEO:-}" ]]; then
  echo "Error: No input video specified." >&2
  echo "Usage: $0 --elevation <high|mid|low> [OPTIONS] <input_video>" >&2
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

# --- Setup directories --------------------------------------------------------
# Intermediate frames go into an elevation-specific subfolder so that running
# all three cameras into the same --scenedir doesn't cause collisions.
FRAMES_DIR="${OUTPUT_DIR}/frames_${ELEVATION}"
mkdir -p "${OUTPUT_DIR}/images" "${OUTPUT_DIR}/sparse" "${FRAMES_DIR}"

# --- Cleanup trap -------------------------------------------------------------
cleanup_frames() {
  if [[ "${KEEP_FRAMES}" -eq 0 ]]; then
    echo "  Cleaning up intermediate frames in ${FRAMES_DIR}..."
    rm -rf "${FRAMES_DIR}"
  else
    echo "  Keeping intermediate frames at: ${FRAMES_DIR}"
  fi
}
trap cleanup_frames EXIT

# --- Logging ------------------------------------------------------------------
LOG_FILE="${OUTPUT_DIR}/extraction_${ELEVATION}_$(date +%Y%m%d_%H%M%S).log"
log() {
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  echo "[${timestamp}] $1" | tee -a "${LOG_FILE}"
}

# --- Summary ------------------------------------------------------------------
echo "================================================"
echo "  RigExtract -- 360 rig video to perspective frames"
echo "================================================"
echo "  Input     : ${INPUT_VIDEO}"
echo "  Elevation : ${ELEVATION} (${#VIEWS[@]} views)"
echo "  Output    : ${OUTPUT_DIR}/images/"
echo "  Frames dir: ${FRAMES_DIR}"
echo "  FPS       : ${FPS}"
echo "  Resolution: ${RES}x${RES}"
echo "  Frames    : $([ "${KEEP_FRAMES}" -eq 1 ] && echo kept || echo removed) after processing"
echo "================================================"

# --- Pass 1: Extract equirectangular frames -----------------------------------
echo ""
echo "  [PASS 1] Extracting sharp equirectangular frames at ${FPS} fps..."
log "PASS 1: sharp-frames start. elevation=${ELEVATION} fps=${FPS}."
sharp-frames --fps "${FPS}" "${INPUT_VIDEO}" "${FRAMES_DIR}"
log "PASS 1: sharp-frames done."

FRAME_FILES=("${FRAMES_DIR}"/frame*.jpg)
TOTAL_FRAMES=${#FRAME_FILES[@]}
echo "  [PASS 1] Done. ${TOTAL_FRAMES} frame(s) extracted."

# --- Pass 2: Project each frame into perspective views -----------------------
echo ""
echo "  [PASS 2] Projecting frames into perspective views..."
log "PASS 2: projection start. views=${#VIEWS[@]}."

EXTRACTED=0
i=0
for VIEW in "${VIEWS[@]}"; do
  yaw="${VIEW%%:*}"
  pitch="${VIEW##*:}"

  echo "  [EXTRACT] View ${i} (${ELEVATION}) yaw=${yaw} pitch=${pitch} — ${TOTAL_FRAMES} frame(s)"
  log "EXTRACT: elevation=${ELEVATION} view=${i} yaw=${yaw} pitch=${pitch} frames=${TOTAL_FRAMES}."

  ffmpeg -loglevel error -stats \
    -framerate 1 \
    -i "${FRAMES_DIR}/frame_%05d.jpg" \
    -vf "v360=e:rectilinear:yaw=${yaw}:pitch=${pitch}:v_fov=90:h_fov=90:w=${RES}:h=${RES}" \
    -q:v 2 \
    -start_number 0 \
    "${OUTPUT_DIR}/images/${INPUT_BASE}_${ELEVATION}_frame%06d_View_${i}.jpg"

  EXTRACTED=$((EXTRACTED + 1))
  i=$((i + 1))
done

log "PASS 2: done. extracted=${EXTRACTED}."

# --- Done ---------------------------------------------------------------------
echo ""
echo "================================================"
echo "  Done. ${EXTRACTED} view(s) extracted (${ELEVATION} camera)."
IMAGE_COUNT=$(ls "${OUTPUT_DIR}/images/" | wc -l | tr -d ' ')
echo "  Total images in output dir: ${IMAGE_COUNT}"
echo "================================================"
