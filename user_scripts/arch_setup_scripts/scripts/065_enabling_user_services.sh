#!/usr/bin/env bash
# Enables user-level and system-level OpenRC services
# ==============================================================================
# Script Name: enabling_user_services.sh
# Description: Enables Hyprland session services using OpenRC user-level services
#              (rc-service --user / rc-update --user) and system services.
#              User services do NOT require root; system services require sudo.
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

DOTFILES_USER_INITD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../openrc/user/init.d"
USER_RC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rc"
USER_INIT_DIR="${USER_RC_DIR}/init.d"

# ─── System Services (require root) ──────────────────────────────────────────

SYSTEM_SERVICES=(
	"pipewire"
	"wireplumber"
)

# ─── User Services (no root needed) ──────────────────────────────────────────

USER_SERVICES=(
	"hypridle"
	"hyprsunset"
	"network-meter"
	"dawn-control-center"
	"dawn-sliders"
	"update-checker"
)

# ─── Install user service scripts ─────────────────────────────────────────────

install_user_service_scripts() {
	log INFO "Installing user service scripts to ${USER_INIT_DIR}..."

	mkdir -p "${USER_INIT_DIR}"

	for svc in "${USER_SERVICES[@]}"; do
		if [[ -x "${DOTFILES_USER_INITD_DIR}/${svc}" ]]; then
			cp "${DOTFILES_USER_INITD_DIR}/${svc}" "${USER_INIT_DIR}/${svc}"
			chmod +x "${USER_INIT_DIR}/${svc}"
			log SUCCESS "Installed: ${C_BOLD}${svc}${C_RESET}"
		else
			log WARN "User service script not found in dotfiles: ${svc}"
		fi
	done

	# Also install pipewire and wireplumber user service scripts if available
	for svc in "pipewire" "wireplumber"; do
		if [[ -x "${DOTFILES_USER_INITD_DIR}/${svc}" ]]; then
			cp "${DOTFILES_USER_INITD_DIR}/${svc}" "${USER_INIT_DIR}/${svc}"
			chmod +x "${USER_INIT_DIR}/${svc}"
			log SUCCESS "Installed: ${C_BOLD}${svc}${C_RESET}"
		fi
	done
}

# ─── Enable system services (require root) ────────────────────────────────────

enable_system_services() {
	log INFO "Enabling system services (may require sudo)..."

	for unit in "${SYSTEM_SERVICES[@]}"; do
		if ! rc-service -l 2>/dev/null | grep -q "^${unit}$" && [[ ! -x "/etc/init.d/$unit" ]]; then
			log WARN "System service ${C_BOLD}$unit${C_RESET} not found. Skipped."
			continue
		fi

		if rc-update add "$unit" default 2>/dev/null; then
			rc-service "$unit" start 2>/dev/null || true
			log SUCCESS "Enabled (system): ${C_BOLD}$unit${C_RESET}"
		else
			sudo rc-update add "$unit" default 2>/dev/null &&
				sudo rc-service "$unit" start 2>/dev/null &&
				log SUCCESS "Enabled (system): ${C_BOLD}$unit${C_RESET}" ||
				log ERROR "Failed (system): ${C_BOLD}$unit${C_RESET}"
		fi
	done
}

# ─── Enable user services (no root needed) ────────────────────────────────────

enable_user_services() {
	log INFO "Enabling user services..."

	for unit in "${USER_SERVICES[@]}"; do
		if ! rc-service --user --list 2>/dev/null | grep -q "^${unit}$" &&
			[[ ! -x "${USER_INIT_DIR}/${unit}" ]] &&
			[[ ! -x "/etc/user/init.d/${unit}" ]]; then
			log WARN "User service ${C_BOLD}$unit${C_RESET} not found. Skipped."
			continue
		fi

		if rc-update --user add "$unit" default 2>/dev/null; then
			rc-service "$unit" --user start 2>/dev/null || true
			log SUCCESS "Enabled (user): ${C_BOLD}$unit${C_RESET}"
		else
			log ERROR "Failed (user): ${C_BOLD}$unit${C_RESET}"
		fi
	done
}

main() {
	log INFO "Enabling Hyprland Services (OpenRC user + system)..."

	if [[ "${EUID}" -eq 0 ]]; then
		log ERROR "Do NOT run user service scripts as root."
		log ERROR "System services will use sudo when needed."
		exit 1
	fi

	# Step 1: Install user service scripts from dotfiles
	install_user_service_scripts

	# Step 2: Enable system services (pipewire, wireplumber)
	enable_system_services

	# Step 3: Enable user services
	enable_user_services

	printf "\n"
	log INFO "Done. User services are managed via: rc-service --user <name> start|stop"
	log INFO "                                  rc-update --user add <name> default"
	log INFO "                                  rc-status --user"
}

main
