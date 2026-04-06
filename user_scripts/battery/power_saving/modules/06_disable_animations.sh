#!/usr/bin/env bash
# Disable animation
# -----------------------------------------------------------------------------
# Purpose: Copy 'dawn.conf' to 'active.conf' & reload Hyprland
# Env:     Arch Linux / Hyprland / UWSM
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
readonly SOURCE_FILE="${HOME}/.config/hypr/source/animations/disable.conf"
readonly TARGET_FILE="${HOME}/.config/hypr/source/animations/active/active.conf"

# --- Colors ---
readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[1;31m'
readonly C_GREEN=$'\033[1;32m'
readonly C_BLUE=$'\033[1;34m'
readonly C_GREY=$'\033[0;90m'
readonly C_YELLOW=$'\033[1;33m'

# --- Hyprland Helper ---
reload_hyprland() {
    # 1. Check if hyprctl exists
    if ! command -v hyprctl &>/dev/null; then
        return 0 # Not installed, skip gracefully
    fi

    # 2. Try to find the instance signature if missing (SSH/Cron fix)
    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        # Try to find the first active Hyprland socket in /tmp/hypr
        local instance
        instance=$(ls -t /tmp/hypr/ 2>/dev/null | grep -v '\.lock$' | head -n1 || true)
        if [[ -n "$instance" ]]; then
            export HYPRLAND_INSTANCE_SIGNATURE="$instance"
        fi
    fi

    # 3. Attempt reload, but allow failure (don't crash the script)
    if hyprctl reload &>/dev/null; then
        return 0
    else
        printf "[${C_GREY}%s${C_RESET}] ${C_YELLOW}[WARN]${C_RESET}  Config copied, but Hyprland reload failed (Is Hyprland running?)\n" \
            "$(date +%T)"
        return 0 # Return success anyway so script doesn't crash
    fi
}

main() {
    # 1. Validate source exists
    if [[ ! -f "$SOURCE_FILE" ]]; then
        printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Source missing: %s\n" \
            "$(date +%T)" "$SOURCE_FILE" >&2
        exit 1
    fi

    # 2. Ensure target directory exists
    if ! mkdir -p -- "${TARGET_FILE%/*}"; then
         printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Failed to create directory: %s\n" \
            "$(date +%T)" "${TARGET_FILE%/*}" >&2
        exit 1
    fi

    # 3. Clean up existing file or symlink
    rm -f -- "$TARGET_FILE"

    # 4. Copy the new file
    if cp -- "$SOURCE_FILE" "$TARGET_FILE"; then
        # 5. Reload Hyprland (Safe wrapper)
        reload_hyprland

        printf "[${C_GREY}%s${C_RESET}] ${C_BLUE}[INFO]${C_RESET}  Animation has been: ${C_GREEN}disabled${C_RESET}\n" \
            "$(date +%T)"
    else
        printf "[${C_GREY}%s${C_RESET}] ${C_RED}[ERROR]${C_RESET} Failed to copy config to: %s\n" \
            "$(date +%T)" "$TARGET_FILE" >&2
        exit 1
    fi
}

main "$@"
