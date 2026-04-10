#!/usr/bin/env bash
# Enables Root services for Aur packages
# ==============================================================================
# SYSTEM SERVICE ENABLER (Systemd/OpenRC)
# ==============================================================================
# Description: Enables system services safely and sequentially.
#              Supports both systemd and OpenRC.
# Logic:       Checks EUID -> Detect Init -> Iterates Array -> Checks Unit Existence -> Enables
# Standards:   Bash 5+, set -euo pipefail, No Logs, Auto-Sudo
# ==============================================================================

# --- 1. Strict Error Handling & Safety ---
set -euo pipefail

# --- 2. Configuration (User Editable) ---
# Add your system services here.
readonly TARGET_SERVICES=(
	"fwupd"
	"warp-svc"
	"preload"
	"asusd"
	"NetworkManager"
	"bluetooth"
	# Add more services below:
	# "bluetooth"
)

# --- Init System ---
readonly INIT_SYSTEM="openrc"

# --- 3. Formatting & Visuals ---
# We use $'\e...' to ensure the escape character is interpreted correctly
readonly C_RESET=$'\e[0m'
readonly C_BOLD=$'\e[1m'
readonly C_GREEN=$'\e[32m'
readonly C_YELLOW=$'\e[33m'
readonly C_RED=$'\e[31m'
readonly C_BLUE=$'\e[34m'

log_info() { printf "${C_BLUE}[INFO]${C_RESET}  %s\n" "$1"; }
log_success() { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$1"; }
log_warn() { printf "${C_YELLOW}[SKIP]${C_RESET}  %s\n" "$1"; }
log_err() { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$1"; }

# --- 4. Cleanup Trap ---
cleanup() {
	# Reset terminal colors on exit/interruption
	printf "%s" "${C_RESET}"
}
trap cleanup EXIT INT TERM

# --- 5. Privilege Escalation (Auto-Sudo) ---
# If not running as root, re-execute script with sudo preserving environment
if [[ $EUID -ne 0 ]]; then
	log_info "Root privileges required. Elevating..."
	exec sudo -E "$0" "$@"
fi

# --- 6. Main Logic ---
main() {
	local init_system
	init_system=$(detect_init)

	if [[ "$init_system" == "unknown" ]]; then
		log_err "No init system detected (systemd or OpenRC)."
		exit 1
	fi

	printf "\n${C_BOLD}Starting System Service Initialization ($init_system)...${C_RESET}\n"
	printf "${C_BOLD}-----------------------------------------${C_RESET}\n"

	local svc_name

	for svc_name in "${TARGET_SERVICES[@]}"; do
		case "$init_system" in
		systemd)
			if systemctl list-unit-files "${svc_name}.service" &>/dev/null 2>&1; then
				if output=$(systemctl enable --now "${svc_name}.service" 2>&1); then
					log_success "Enabled & Started: ${C_BOLD}${svc_name}${C_RESET}"
				else
					log_err "Could not enable ${svc_name}. Reason:"
					printf "      %s\n" "$output"
				fi
			else
				log_warn "Service not found: ${C_BOLD}${svc_name}${C_RESET}. Skipping..."
			fi
			;;
		openrc)
			if rc-service -l 2>/dev/null | grep -q "^${svc_name}$"; then
				if rc-update add "$svc_name" default 2>/dev/null; then
					rc-service "$svc_name" start 2>/dev/null || true
					log_success "Enabled & Started: ${C_BOLD}$svc_name${C_RESET}"
				else
					log_err "Could not enable $svc_name"
				fi
			else
				log_warn "Service not found: ${C_BOLD}$svc_name${C_RESET}. Skipping..."
			fi
			;;
		esac
	done

	printf "${C_BOLD}-----------------------------------------${C_RESET}\n"
	log_info "Operation complete."
	printf "\n"
}

main "$@"
