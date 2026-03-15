#!/usr/bin/env bash
# Run COLMAP reconstruction
#
# Usage:
#   ./Colmap.sh [OPTIONS]
#
# Options:
#   --scenedir <path>   Working directory with images/ subfolder (required)
#   -h, --help          Show this help message

set -euo pipefail

# --- Defaults ----------------------------------------------------------------
SCENE_DIR=""

# --- Help --------------------------------------------------------------------
usage() {
  grep '^#' "$0" | grep -v '#!/' | grep -v '# -' | sed 's/^# \{0,1\}//'
  exit 0
}

# --- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage ;;
    --scenedir)
      [[ -z "${2:-}" ]] && { echo "Error: --scenedir requires a value." >&2; exit 1; }
      SCENE_DIR="$2"; shift 2 ;;
    -*)
      echo "Error: Unknown option '$1'" >&2; exit 1 ;;
    *)
      echo "Error: Unexpected argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "${SCENE_DIR}" ]]; then
  echo "Error: --scenedir is required." >&2; exit 1
fi

if [[ ! -d "${SCENE_DIR}" ]]; then
  echo "Error: Scene directory '${SCENE_DIR}' does not exist." >&2; exit 1
fi

# --- Logging -----------------------------------------------------------------
LOG_FILE="${SCENE_DIR}/colmap_$(date +%Y%m%d_%H%M%S).log"
log() {
  local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local entry="[${timestamp}] $1"
  echo "${entry}" | tee -a "${LOG_FILE}"
}

NUM_THREADS=$(sysctl -n hw.logicalcpu 2>/dev/null || nproc 2>/dev/null || echo 4)

# --- COLMAP ------------------------------------------------------------------
log "Creating database."
colmap database_creator \
  --database_path "${SCENE_DIR}/colmap.db"

log "Running feature extraction."
colmap feature_extractor \
  --database_path "${SCENE_DIR}/colmap.db" \
  --image_path "${SCENE_DIR}/images" \
  --ImageReader.single_camera 1 \
  --ImageReader.camera_model SIMPLE_RADIAL

log "Running exhaustive matcher."
colmap exhaustive_matcher \
  --database_path "${SCENE_DIR}/colmap.db"

log "Running mapper."
colmap mapper \
  --database_path "${SCENE_DIR}/colmap.db" \
  --image_path "${SCENE_DIR}/images" \
  --output_path "${SCENE_DIR}/sparse" \
  --Mapper.num_threads "${NUM_THREADS}"

log "Done."
