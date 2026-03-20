#!/usr/bin/env bash
# Extract sharp frames from a video for COLMAP/Gaussian Splatting
#
# Usage:
#   ./Exctract.sh [OPTIONS] <input_video>
#
# Options:
#   --fps <rate>           Frames per second to extract (default: 1)
#   --scenedir <path>     Override the output directory (default: same name as input video, no extension)
#   -h, --help             Show this help message

set -euo pipefail

# --- Defaults -----------------------------------------------------------------

FPS=1
OUTPUT_DIR_OVERRIDE=""

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
    --scenedir)
      [[ -z "${2:-}" ]] && { echo "Error: --scenedir requires a value." >&2; exit 1; }
      OUTPUT_DIR_OVERRIDE="$2"; shift 2 ;;
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

# --- Resolve output directory -------------------------------------------------
OUTPUT_DIR="${OUTPUT_DIR_OVERRIDE:-${INPUT_VIDEO%.*}}"

# --- Setup output directories -------------------------------------------------
mkdir -p "${OUTPUT_DIR}/frames" "${OUTPUT_DIR}/sparse"

# --- Extract sharp frames -----------------------------------------------------
echo "================================================"
echo "  Exctract -- video to sharp frames"
echo "================================================"
echo "  Input  : ${INPUT_VIDEO}"
echo "  Output : ${OUTPUT_DIR}/frames/"
echo "  FPS    : ${FPS}"
echo "================================================"
echo ""
echo "  Extracting sharp frames at ${FPS} fps..."
sharp-frames --fps "${FPS}" "${INPUT_VIDEO}" "${OUTPUT_DIR}/frames"
echo "  Done."
echo "================================================"
