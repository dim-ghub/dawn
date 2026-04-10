#!/usr/bin/env bash
# Enables user services
# ==============================================================================
# Script Name: enable_hyprland_services_v2.sh
# Description: Fixed logic for enabling Hyprland user services.
#              Supports both systemd and OpenRC.
# ==============================================================================

set -euo pipefail

readonly C_RESET=$'\e[0m'
readonly C_GREEN=$'\e[1;32m'
readonly C_RED=$'\e[1;31m'
readonly C_BLUE=$'\e[1;34m'
readonly C_YELLOW=$'\e[1;33m'
readonly C_BOLD=$'\e[1m'

log() {
	local level="$1"
	local message="$2"
	case "$level" in
	INFO) printf "${C_BLUE}[INFO]${C_RESET}  %s\n" "$message" ;;
	SUCCESS) printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$message" ;;
	WARN) printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$message" ;;
	ERROR) printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$message" ;;
	esac
}

# --- Init System ---
readonly INIT_SYSTEM="openrc"

# --- Root Privilege Check ---
if [[ $EUID -eq 0 ]]; then
	log ERROR "Do NOT run user service scripts as root."
	exit 1
fi

# --- Service Definition ---
services_systemd=(
	"pipewire.socket"
	"pipewire-pulse.socket"
	"wireplumber.service"
	"hypridle.service"
	"hyprpolkitagent.service"
	"fumon.service"
	"gnome-keyring-daemon.service"
	"gnome-keyring-daemon.socket"
)

services_openrc=(
	"pipewire"
	"wireplumber"
	"hypridle"
	"hyprpolkitagent"
)

main() {
	local init_system
	init_system=$(detect_init)

	if [[ "$init_system" == "unknown" ]]; then
		log ERROR "No init system detected."
		exit 1
	fi

	log INFO "Initializing Hyprland User Service Setup ($init_system)..."

	local success_count=0
	local fail_count=0

	local services
	if [[ "$init_system" == "systemd" ]]; then
		services=("${services_systemd[@]}")
	else
		services=("${services_openrc[@]}")
	fi

	for unit in "${services[@]}"; do
		if [[ "$init_system" == "systemd" ]]; then
			if ! systemctl --user list-unit-files "$unit" &>/dev/null; then
				log WARN "Unit ${C_BOLD}$unit${C_RESET} not found. Skipped."
				fail_count=$((fail_count + 1))
				continue
			fi

			if output=$(systemctl --user enable --now "$unit" 2>&1); then
				log SUCCESS "Enabled: ${C_BOLD}$unit${C_RESET}"
				success_count=$((success_count + 1))
			else
				log ERROR "Failed: ${C_BOLD}$unit${C_RESET}"
				printf "      └─ %s\n" "$output"
				fail_count=$((fail_count + 1))
			fi
		else
			if ! rc-service -l 2>/dev/null | grep -q "^${unit}$" && [[ ! -x "/etc/init.d/$unit" ]]; then
				log WARN "Service ${C_BOLD}$unit${C_RESET} not found. Skipped."
				fail_count=$((fail_count + 1))
				continue
			fi

			if rc-update add "$unit" default 2>/dev/null; then
				rc-service "$unit" start 2>/dev/null || true
				log SUCCESS "Enabled: ${C_BOLD}$unit${C_RESET}"
				success_count=$((success_count + 1))
			else
				log ERROR "Failed: ${C_BOLD}$unit${C_RESET}"
				fail_count=$((fail_count + 1))
			fi
		fi
	done

	printf "\n"
	log INFO "Done. Success: ${success_count} | Skipped/Failed: ${fail_count}"

	if [[ "$init_system" == "systemd" ]]; then
		systemctl --user daemon-reload
	fi
}

main
