#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: png2jpg.sh
# Description: High-performance Bulk PNG -> JPG Converter.
#              - 100% Quality retention (4:4:4 Chroma).
#              - Parallel execution (Native Bash Job Pool).
#              - Archives original PNGs to 'png/' folder on success.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- TTY-Aware Colors ---
if [[ -t 1 ]]; then
    readonly RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' BLUE=$'\e[34m'
    readonly BOLD=$'\e[1m' RESET=$'\e[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# --- Configuration ---
# Parallelism: Fallback chain
readonly MAX_JOBS=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '4')
readonly ARCHIVE_DIR="png"

# Magick Options for 100% Fidelity
readonly -a MAGICK_OPTS=(
    -quality 100            # No compression artifacts
    -sampling-factor 4:4:4  # 4:4:4 chroma prevents color bleed
    -background black       # Flatten transparency to black
    -alpha remove           # Remove alpha channel
    -alpha off
)

# --- Logging Functions ---
log_ok()   { printf '%s[OK]%s   %s\n' "$GREEN" "$RESET" "$1"; }
log_skip() { printf '%s[SKIP]%s %s\n' "$YELLOW" "$RESET" "$1"; }
log_fail() { printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$1" >&2; }
log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$1"; }
log_err()  { printf '%s[ERR]%s  %s\n' "$RED" "$RESET" "$1" >&2; }

# --- Signal Handler ---
cleanup() {
    local -a pids
    mapfile -t pids < <(jobs -p 2>/dev/null)
    if (( ${#pids[@]} > 0 )); then
        printf '\n%sInterrupted: stopping %d job(s)...%s\n' \
            "$RED" "${#pids[@]}" "$RESET" >&2
        kill -- "${pids[@]}" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}
trap 'cleanup; exit 130' INT TERM HUP

# --- Dependency Check ---
if ! command -v magick &>/dev/null; then
    log_err "ImageMagick v7 ('magick') not found."
    printf 'Install via: %ssudo pacman -S imagemagick%s\n' "$BOLD" "$RESET" >&2
    exit 1
fi

# --- Worker Function ---
convert_and_archive() {
    local src="$1"
    local dst="${src%.*}.jpg"

    # Skip if target JPG already exists (prevents overwriting)
    if [[ -e "$dst" ]]; then
        log_skip "Exists: $dst (Source not moved)"
        return 0
    fi

    # 1. Convert
    if magick "$src" "${MAGICK_OPTS[@]}" "$dst" 2>/dev/null; then
        # 2. Archive Source (Move PNG to folder)
        # We use quotes to handle filenames with spaces
        if mv "$src" "$ARCHIVE_DIR/"; then
            log_ok "$src -> $dst (Archived)"
            return 0
        else
            log_err "Converted but failed to move: $src"
            return 1
        fi
    fi

    log_fail "$src"
    return 1
}

# --- Main Logic ---
main() {
    printf '%sPNG -> JPG Bulk Converter%s\n' "$BOLD" "$RESET"
    printf 'Quality: 100%% | Chroma: 4:4:4 | Workers: %d\n' "$MAX_JOBS"
    printf '%s\n' '----------------------------------------'

    # Ensure archive directory exists
    if [[ ! -d "$ARCHIVE_DIR" ]]; then
        mkdir -p "$ARCHIVE_DIR"
    fi

    # Robust file finding (case-insensitive glob)
    shopt -s nullglob nocaseglob
    local -a files=(./*.png)
    shopt -u nullglob nocaseglob

    local total=${#files[@]}
    if (( total == 0 )); then
        log_info 'No PNG files found in current directory.'
        return 0
    fi

    log_info "Found $total PNG file(s). Processing..."

    local job_count=0
    local failures=0

    for img in "${files[@]}"; do
        convert_and_archive "$img" &
        (( ++job_count ))

        if (( job_count >= MAX_JOBS )); then
            wait -n 2>/dev/null || (( ++failures )) || true
            (( --job_count ))
        fi
    done

    while (( job_count > 0 )); do
        wait -n 2>/dev/null || (( ++failures )) || true
        (( --job_count ))
    done

    printf '%s\n' '----------------------------------------'

    if (( failures > 0 )); then
        printf '%sBatch complete:%s %d processed, %s%d failed%s\n' \
            "$BOLD" "$RESET" "$total" "$RED" "$failures" "$RESET"
        return 1
    else
        printf '%sBatch complete:%s %d processed, %s0 failed%s\n' \
            "$BOLD" "$RESET" "$total" "$GREEN" "$RESET"
    fi
}

main "$@"
