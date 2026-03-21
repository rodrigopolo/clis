#!/usr/bin/env bash
# Select best COLMAP sparse model and run Brush Gaussian Splatting training
#
# Usage:
#   ./Brush.sh [OPTIONS]
#
# Options:
#   --scenedir <path>   Working directory with sparse/ subfolder (required)
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

if [[ ! -d "${SCENE_DIR}/sparse" ]]; then
	echo "Error: No sparse/ folder found in '${SCENE_DIR}'. Run Colmap.sh first." >&2; exit 1
fi

# --- Logging -----------------------------------------------------------------
LOG_FILE="${SCENE_DIR}/brush_$(date +%Y%m%d_%H%M%S).log"
log() {
	local timestamp; timestamp=$(date +"%Y-%m-%d %H:%M:%S")
	local entry="[${timestamp}] $1"
	echo "${entry}" | tee -a "${LOG_FILE}"
}

# --- Select best sparse model ------------------------------------------------
log "Selecting best sparse model."
BEST_SPARSE=""
BEST_COUNT=0

for MODEL_DIR in "${SCENE_DIR}/sparse"/*/; do
	if [[ -f "${MODEL_DIR}/images.bin" ]]; then
		COUNT=$(python3 -c "
import pycolmap, sys
m = pycolmap.Reconstruction(sys.argv[1])
print(len(m.images))
" "${MODEL_DIR}" 2>/dev/null || true)
		log "Model ${MODEL_DIR}: ${COUNT:-<no count>} registered images."
		if [[ -n "${COUNT}" && "${COUNT}" -gt "${BEST_COUNT}" ]]; then
			BEST_COUNT=${COUNT}
			BEST_SPARSE="${MODEL_DIR}"
		fi
	fi
done

if [[ -z "${BEST_SPARSE}" ]]; then
	log "ERROR: No valid sparse model found. Exiting."
	exit 1
fi

log "Best sparse model: ${BEST_SPARSE} (${BEST_COUNT} registered images)."

# --- Backup & cleanup sparse models ------------------------------------------
log "Backing up sparse folder (no compression)."
zip -r0 "${SCENE_DIR}/sparse_backup.zip" "${SCENE_DIR}/sparse/"

log "Sparse backup created at ${SCENE_DIR}/sparse_backup.zip"

log "Removing non-best sparse models."
for MODEL_DIR in "${SCENE_DIR}/sparse"/*/; do
	if [[ "${MODEL_DIR%/}" != "${BEST_SPARSE%/}" ]]; then
		log "Deleting ${MODEL_DIR}"
		rm -rf "${MODEL_DIR}"
	fi
done

# --- Rename best model to sparse/0 -------------------------------------------
SPARSE_ZERO="${SCENE_DIR}/sparse/0"
if [[ "${BEST_SPARSE%/}" != "${SPARSE_ZERO}" ]]; then
	log "Renaming best model to sparse/0."
	mv "${BEST_SPARSE%/}" "${SPARSE_ZERO}"
fi

# --- Brush -------------------------------------------------------------------
log "Starting Brush training."
brush "${SCENE_DIR}" \
	--total-steps 30000 \
	--max-splats 4000000 \
	--max-resolution 2444 \
	--growth-stop-iter 15000 \
	--sh-degree 3 \
	--export-every 5000 \
	--export-path "${SCENE_DIR}/exports/"

log "Done."
