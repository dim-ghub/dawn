#!/usr/bin/env bash
# ==============================================================================
# WALLPAPER MIME-TYPE SANITIZER (MANIFEST / BATCH EDITION)
# ==============================================================================
# Description: Two-phase strict MIME-type sanitizer. Builds an immutable
#              manifest to prevent filesystem walk race conditions, then
#              batches parsing via libmagic for maximum throughput.
# ==============================================================================

set -Eeuo pipefail
export LC_ALL=C

# --- CONFIGURATION ---
TARGET_DIR="${1:-.}"

# --- HELPERS ---
log()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Dependency check
for cmd in find file xargs mv mktemp realpath; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
done

[[ -d "$TARGET_DIR" ]] || die "Target directory does not exist: $TARGET_DIR"

# Prevent find/xargs flag injection
SCAN_ROOT="$TARGET_DIR"
[[ "$SCAN_ROOT" == -* ]] && SCAN_ROOT="./$SCAN_ROOT"

# Temporary files
LOG_FILE=$(mktemp --tmpdir sanitized_wallpapers.XXXXXX.log) || die "mktemp failed"
MANIFEST=$(mktemp --tmpdir sanitized_wallpapers_manifest.XXXXXX.list) || die "mktemp failed"

# Cleanup manifest on exit, keep log
trap 'rm -f -- "$MANIFEST"' EXIT

# Open File Descriptor 3 for high-performance logging (avoids constant open/close I/O)
exec 3>>"$LOG_FILE"

# --- O(1) MIME DICTIONARIES ---
declare -A MIME_EXT_MAP=(
    ["image/jpeg"]="jpg"
    ["image/png"]="png"
    ["image/webp"]="webp"
    ["image/gif"]="gif"
    ["image/avif"]="avif"
    ["image/heic"]="heic"
    ["image/heif"]="heif"
    ["image/jxl"]="jxl"
    ["image/bmp"]="bmp"
    ["image/x-ms-bmp"]="bmp"
    ["image/tiff"]="tiff"
    ["image/svg+xml"]="svg"
)

declare -A MIME_EXT_ALIASES=(
    ["image/jpeg"]="jpg jpeg jpe jfif"
    ["image/heif"]="heif hif"
    ["image/bmp"]="bmp dib"
    ["image/x-ms-bmp"]="bmp dib"
    ["image/tiff"]="tif tiff"
)

# --- METRICS ---
declare -i TOTAL_SCANNED=0
declare -i TOTAL_FIXED=0

log "Phase 1: Building immutable manifest for: $(realpath -- "$TARGET_DIR")"
# -print0 ensures newline/space safety in filenames
find "$SCAN_ROOT" -type f ! -samefile "$LOG_FILE" ! -samefile "$MANIFEST" -print0 > "$MANIFEST"

log "Phase 2: Batch scanning MIME types..."
log "Ledger will be written to: $LOG_FILE"
echo '--------------------------------------------------'

# Process the manifest using xargs to batch calls to 'file'
xargs -0 -a "$MANIFEST" -r file -0 --mime-type -- |
while IFS= read -r -d '' filepath && IFS= read -r mime_line; do
    ((++TOTAL_SCANNED))

    # Strict string parsing
    mime_type="${mime_line#*:}"
    mime_type="${mime_type//[[:space:]]/}" 

    # Fast O(1) lookup
    if [[ -v "MIME_EXT_MAP[$mime_type]" ]]; then
        canon_ext="${MIME_EXT_MAP[$mime_type]}"
        valid_exts=" ${MIME_EXT_ALIASES[$mime_type]-$canon_ext} "

        filename="${filepath##*/}"
        dirpath="${filepath%/*}"

        case "$filename" in
            .*.*|?*.*)
                ext="${filename##*.}"
                base_name="${filename%.*}"
                ;;
            *)
                ext=""
                base_name="$filename"
                ;;
        esac

        lower_ext="${ext,,}"
        
        # If the file's extension is within the valid aliases, skip it
        [[ "$valid_exts" == *" $lower_ext "* ]] && continue

        dest="${dirpath}/${base_name}.${canon_ext}"
        
        # Skip if the destination is exactly the current file
        [[ "$dest" == "$filepath" ]] && continue

        # Deterministic collision handling
        if [[ -e "$dest" ]]; then
            n=1
            while [[ -e "${dirpath}/${base_name}_${n}.${canon_ext}" ]]; do
                ((++n))
            done
            dest="${dirpath}/${base_name}_${n}.${canon_ext}"
        fi

        # Atomic target rename. mv -T ensures we don't accidentally drop a file into a sub-directory
        if mv -T -- "$filepath" "$dest"; then
            printf 'Fixed: %q -> %q\n' "$filename" "${dest##*/}"
            printf '[%s] %q -> %q\n' "$mime_type" "$filepath" "$dest" >&3
            ((++TOTAL_FIXED))
        else
            warn "Failed to rename: $filepath -> $dest"
        fi
    fi
done

echo '--------------------------------------------------'
log "Scan complete."
log "Total scanned: $TOTAL_SCANNED"
log "Total fixed:   $TOTAL_FIXED"
log "Ledger saved:  $LOG_FILE"

# Close File Descriptor 3
exec 3>&-
