#!/usr/bin/env bash
# Enables Root services for AUR packages
# ==============================================================================
# SYSTEM SERVICE ENABLER (OpenRC)
# ==============================================================================
# Description: Enables system services safely and sequentially via OpenRC.
# Standards:   Bash 5+, set -euo pipefail, Auto-Sudo
# ==============================================================================

set -euo pipefail

# --- 1. Configuration (User Editable) ---
readonly TARGET_SERVICES=(
	"fwupd"
	"warp-svc"
	"preload"
	"asusd"
	"NetworkManager"
	"bluetooth"
)

# --- 2. Formatting & Visuals ---
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_RED=$'\033[0;31m'
readonly C_BLUE=$'\033[0;34m'

log_info() { printf '%s[INFO]%s    %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%s[SKIP]%s    %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
log_error() { printf '%s[FAIL]%s    %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }

# --- 3. Privilege Escalation (Auto-Sudo) ---
if [[ "${EUID}" -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

# --- 4. Pre-flight Check ---
if ! command -v rc-service >/dev/null 2>&1; then
	log_error "rc-service not found. This script requires OpenRC."
	exit 1
fi

# --- 5. Main Logic ---
main() {
	printf '\n%sStarting System Service Initialization (OpenRC)...%s\n' "${C_BOLD}" "${C_RESET}"
	printf '%s-----------------------------------------%s\n' "${C_BOLD}" "${C_RESET}"

	local svc_name

	for svc_name in "${TARGET_SERVICES[@]}"; do
		if rc-service -l 2>/dev/null | grep -q "^${svc_name}$"; then
			if rc-update add "$svc_name" default 2>/dev/null; then
				rc-service "$svc_name" start 2>/dev/null || true
				log_success "Enabled & Started: ${C_BOLD}${svc_name}${C_RESET}"
			else
				log_error "Could not enable ${svc_name}"
			fi
		else
			log_warn "Service not found: ${C_BOLD}${svc_name}${C_RESET}"
		fi
	done

	printf '%s-----------------------------------------%s\n' "${C_BOLD}" "${C_RESET}"
	log_info "Operation complete."
	printf '\n'
}

main "$@"
