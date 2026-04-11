#!/usr/bin/env bash
# ==============================================================================
# SwayNC dGPU Fix — Forces SwayNC to iGPU for power saving (OpenRC)
# ==============================================================================
# Toggles the DRI_PRIME=0 environment variable for SwayNC via OpenRC
# drop-in configuration.
#
# Usage: ./240_swaync_dgpu_fix.sh [--auto|--enable|--disable]
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Configuration ---
CONFIG_DIR="${HOME}/.config/swaync"
ACTIVE_FILE="${CONFIG_DIR}/gpu-fix.conf"
BACKUP_FILE="${CONFIG_DIR}/gpu-fix.conf.bak"

# Default configuration content (forces iGPU)
DEFAULT_CONF="# SwayNC dGPU fix — force iGPU for power saving
# This file is sourced by the swaync OpenRC init script.
# Set DRI_PRIME=0 to force integrated GPU rendering.
DRI_PRIME=0"

# --- Styling ---
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
RED=$'\033[0;31m'
RESET=$'\033[0m'

log_info() { printf '%s[INFO]%s    %s\n' "${BLUE}" "${RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
log_err() { printf '%s[ERROR]%s   %s\n' "${RED}" "${RESET}" "$1" >&2; }

# --- Argument Parsing ---
AUTO_MODE=false
ENABLE_MODE=false
DISABLE_MODE=false

for arg in "$@"; do
	case "$arg" in
	--auto) AUTO_MODE=true ;;
	--enable) ENABLE_MODE=true ;;
	--disable) DISABLE_MODE=true ;;
	esac
done

# --- Ensure config directory exists ---
if [[ ! -d "$CONFIG_DIR" ]]; then
	log_info "Creating swaync config directory: ${CONFIG_DIR}"
	mkdir -p "$CONFIG_DIR"
fi

# --- Auto-create default config if neither file exists ---
if [[ ! -f "$ACTIVE_FILE" ]] && [[ ! -f "$BACKUP_FILE" ]]; then
	log_info "No GPU fix configuration found. Creating default (ENABLED)..."
	printf '%s\n' "$DEFAULT_CONF" >"$ACTIVE_FILE"
	log_success "Created default configuration at ${ACTIVE_FILE}"
fi

# --- State Detection ---
if [[ -f "$ACTIVE_FILE" ]]; then
	CURRENT_STATE="ACTIVE"
	TARGET_ACTION="DISABLE"
elif [[ -f "$BACKUP_FILE" ]]; then
	CURRENT_STATE="DISABLED"
	TARGET_ACTION="ENABLE"
else
	# Should not reach here after auto-create, but handle gracefully
	log_err "No configuration file found (checked .conf and .conf.bak)."
	printf "Expected to find 'gpu-fix.conf' or 'gpu-fix.conf.bak' inside '%s'.\n" "$CONFIG_DIR"
	exit 1
fi

# --- User Interaction / Flag Handling ---
if [[ "${AUTO_MODE}" == true ]]; then
	if [[ "${CURRENT_STATE}" == "DISABLED" ]]; then
		log_success "Auto mode: Fix is already DISABLED. No changes made."
		exit 0
	fi
	printf '%sCurrent SwayNC GPU Fix State:%s %s%s%s\n' "${BOLD}" "${RESET}" "${BLUE}" "${CURRENT_STATE}" "${RESET}"
	log_info "Auto mode detected. Proceeding to DISABLE fix..."
elif [[ "${ENABLE_MODE}" == true ]]; then
	if [[ "${CURRENT_STATE}" == "ACTIVE" ]]; then
		log_success "Flag --enable: Fix is already ACTIVE. No changes made."
		exit 0
	fi
	log_info "Enable flag detected. Proceeding to ENABLE fix..."
elif [[ "${DISABLE_MODE}" == true ]]; then
	if [[ "${CURRENT_STATE}" == "DISABLED" ]]; then
		log_success "Flag --disable: Fix is already DISABLED. No changes made."
		exit 0
	fi
	log_info "Disable flag detected. Proceeding to DISABLE fix..."
else
	# Interactive Mode
	printf '%sCurrent SwayNC GPU Fix State:%s %s%s%s\n' "${BOLD}" "${RESET}" "${BLUE}" "${CURRENT_STATE}" "${RESET}"
	read -r -p "$(printf "Do you want to %s%s%s the power saving fix? [y/N] " "${BOLD}" "${TARGET_ACTION}" "${RESET}")" CONFIRM

	if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
		log_info "Operation cancelled by user."
		exit 0
	fi
fi

# --- Execution ---
if [[ "${CURRENT_STATE}" == "ACTIVE" ]]; then
	mv --no-clobber "$ACTIVE_FILE" "$BACKUP_FILE"
	log_success "Configuration renamed to .bak (Fix Disabled)"
else
	mv --no-clobber "$BACKUP_FILE" "$ACTIVE_FILE"
	log_success "Configuration renamed to .conf (Fix Enabled)"
fi

# --- Restart SwayNC ---
log_info "Restarting swaync..."
pkill -x swaync 2>/dev/null || true
sleep 0.5
swaync &
log_success "SwayNC restarted."
