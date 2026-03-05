#!/usr/bin/env bash
# =============================================================================
# gen_krpano_cube_xml.sh
#
# Scans a krpano `panos/` directory tree and outputs <scene> XML blocks for
# each panorama.  Tile structure matches tilecreator.py output exactly.
#
# Directory layout produced by tilecreator.py:
#
#   panos/
#   └── <stem>.tiles/
#       ├── preview.jpg          256×1536 vertical cube strip (l f r b u d)
#       ├── thumb.jpg            240×240 front-face thumbnail
#       └── <face>/              f  b  r  l  u  d
#           └── l<N>/            l1 = lowest res … lN = highest res
#               └── <row:02d>/   01  02  03 …  (zero-padded row directories)
#                   └── l<N>_<face>_<row:02d>_<col:02d>.jpg
#
# krpano <cube> url template:
#   panos/{stem}.tiles/%s/l%l/%0v/l%l_%s_%0v_%0h.jpg
#	 %s  = face letter	  %l  = level number
#	 %0v = zero-padded row  %0h = zero-padded col
#
# multires attribute:
#   "512,<l1_facesize>,<l2_facesize>,…"   (tile_size first, then ascending face sizes)
#
# Usage:
#   ./gen_krpano_cube_xml.sh [panos_dir]	   (default: ./panos)
#   ./gen_krpano_cube_xml.sh ./panos > cube_tags.xml
#
# Requires: bash ≥ 4, exiftool
# =============================================================================

set -uo pipefail

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '# %s\n'	 "$*" >&2; }

require_cmd() { command -v "$1" &>/dev/null || die "'$1' not found. Install it first."; }

exif_val() {   # exif_val <file> <tag>  →  value or empty string
	exiftool -s3 -"$2" "$1" 2>/dev/null || true
}

# ── arguments ─────────────────────────────────────────────────────────────────

PANOS_DIR="${1:-./panos}"
[[ -d "$PANOS_DIR" ]] || die "Directory not found: $PANOS_DIR"
require_cmd exiftool

# ── discover .tiles directories ───────────────────────────────────────────────

mapfile -t tiles_dirs < <(find "$PANOS_DIR" -maxdepth 2 -type d -name '*.tiles' | sort)
[[ ${#tiles_dirs[@]} -gt 0 ]] || die "No *.tiles directories found under: $PANOS_DIR"

# ── XML header ────────────────────────────────────────────────────────────────

printf '<?xml version="1.0" encoding="UTF-8"?>\n<krpano>\n\n'

# ── process each pano ─────────────────────────────────────────────────────────

for tiles_dir in "${tiles_dirs[@]}"; do

	raw="$(basename "$tiles_dir")"
	stem="${raw%.tiles}"
	scene_name="scene_$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]' | tr ' -' '__')"

	info "Processing: $stem  ($tiles_dir)"

	# ── find a face directory to use as level reference ───────────────────────
	sample_face=""
	for face in f b r l u d; do
		if [[ -d "${tiles_dir}/${face}" ]]; then
			sample_face="${tiles_dir}/${face}"
			break
		fi
	done
	if [[ -z "$sample_face" ]]; then
		info "  WARNING: no face dirs (f/b/r/l/u/d) found – skipping."
		continue
	fi

	# ── discover levels inside the face dir (l1, l2, …) ──────────────────────
	mapfile -t level_dirs < <(
		find "$sample_face" -maxdepth 1 -type d -name 'l[0-9]*' | sort -t'l' -k2 -n
	)
	if [[ ${#level_dirs[@]} -eq 0 ]]; then
		info "  WARNING: no level dirs found – skipping."
		continue
	fi
	num_levels="${#level_dirs[@]}"
	info "  Levels: $num_levels"

	# ── canonical tile size: read from the interior (row 01, col 01) tile ─────
	# Row dirs are zero-padded (01, 02, …); pick the lowest one, then col 01.
	# This guarantees we get a full-size interior tile, not a partial edge tile.
	lnum1="$(basename "${level_dirs[0]}" | tr -d 'l')"
	first_row_dir="$(find "${level_dirs[0]}" -maxdepth 1 -type d | sort | grep -v "^${level_dirs[0]}$" | head -1)"
	interior_tile=""
	if [[ -n "$first_row_dir" ]]; then
		interior_tile="$(find "$first_row_dir" -maxdepth 1 -type f -name "l${lnum1}_*_01_01.jpg" 2>/dev/null | head -1)"
		# fallback: any tile whose name ends in _01_01
		[[ -z "$interior_tile" ]] && \
			interior_tile="$(find "$first_row_dir" -maxdepth 1 -type f -name '*_01_01.jpg' 2>/dev/null | head -1)"
	fi
	# last fallback: just find row 01 dir by name
	if [[ -z "$interior_tile" ]]; then
		interior_tile="$(find "${level_dirs[0]}/01" -maxdepth 1 -type f -name '*.jpg' 2>/dev/null | head -1)"
	fi

	[[ -z "$interior_tile" ]] && { info "  WARNING: no tile images found – skipping."; continue; }

	tile_w="$(exif_val "$interior_tile" ImageWidth)"
	tile_h="$(exif_val "$interior_tile" ImageHeight)"
	if [[ -z "$tile_w" || -z "$tile_h" ]]; then
		info "  WARNING: could not read tile dimensions – skipping."
		continue
	fi
	info "  Tile: ${tile_w}×${tile_h} px  (from: ${interior_tile##*/})"

	# ── face pixel size per level ─────────────────────────────────────────────
	# Tile filenames: l<N>_<face>_<row:02d>_<col:02d>.jpg
	# Face size = (max_col - 1) * tile_w  +  width_of_last_col_tile

	level_face_sizes=()

	for level_dir in "${level_dirs[@]}"; do
		lnum="$(basename "$level_dir" | tr -d 'l')"

		max_col=0
		max_row=0
		while IFS= read -r tfile; do
			base="${tfile##*/}"
			base="${base%.jpg}"
			# pattern: l<N>_<face>_<row>_<col>
			IFS='_' read -r _l _f rr cc <<< "$base"
			cc=$(( 10#$cc ))   # strip leading zeros for arithmetic
			rr=$(( 10#$rr ))
			(( cc > max_col )) && max_col=$cc
			(( rr > max_row )) && max_row=$rr
		done < <(find "$level_dir" -maxdepth 2 -type f -name '*.jpg' 2>/dev/null)

		if (( max_col == 0 )); then
			info "  WARNING: could not parse tile grid for l${lnum}"
			level_face_sizes+=(0)
			continue
		fi

		# Width of the last-column tile (may be a partial edge tile)
		last_tile="$(find "$level_dir" -maxdepth 2 -type f \
			-name "l${lnum}_*_$(printf '%02d' "$max_row")_$(printf '%02d' "$max_col").jpg" \
			2>/dev/null | head -1)"

		if [[ -n "$last_tile" ]]; then
			last_w="$(exif_val "$last_tile" ImageWidth)"
			: "${last_w:=$tile_w}"
		else
			last_w="$tile_w"
		fi

		face_size=$(( (max_col - 1) * tile_w + last_w ))
		level_face_sizes+=("$face_size")
		info "  l${lnum}: ${max_col}×${max_row} grid → face ${face_size} px"
	done

	# ── multires = "tile_w,l1_size,l2_size,…" ────────────────────────────────
	multires_attr="$tile_w"
	for sz in "${level_face_sizes[@]}"; do
		multires_attr+=",${sz}"
	done

	# ── optional asset URLs ───────────────────────────────────────────────────
	thumb_url=""
	[[ -f "${tiles_dir}/thumb.jpg"   ]] && thumb_url="panos/${stem}.tiles/thumb.jpg"
	preview_url=""
	[[ -f "${tiles_dir}/preview.jpg" ]] && preview_url="panos/${stem}.tiles/preview.jpg"

	# ── emit XML ──────────────────────────────────────────────────────────────

	printf '	<!-- ═══ %s ═══ -->\n' "$stem"
	printf '	<scene name="%s" title="%s"' "$scene_name" "$stem"
	[[ -n "$thumb_url" ]] && printf '\n			thumburl="%s"' "$thumb_url"
	printf '\n			onstart="" heading="0.0">\n\n'

	printf '		<control bouncinglimits="calc:image.cube ? true : false" />\n'
	printf '		<view hlookat="0.0" vlookat="0.0" fovtype="MFOV" fov="120"\n'
	printf '			  maxpixelzoom="2.0" fovmin="70" fovmax="140" limitview="auto" />\n\n'

	[[ -n "$preview_url" ]] && printf '		<preview url="%s" />\n\n' "$preview_url"

	printf '		<image>\n'
	printf '			<cube url="panos/%s.tiles/%%s/l%%l/%%0v/l%%l_%%s_%%0v_%%0h.jpg"\n' "$stem"
	printf '				  multires="%s"\n' "$multires_attr"
	printf '			/>\n'
	printf '		</image>\n\n'

	printf '	</scene>\n\n'

	unset level_face_sizes

done

printf '</krpano>\n'
info "Done."

