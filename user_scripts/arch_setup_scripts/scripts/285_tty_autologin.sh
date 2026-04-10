#!/usr/bin/env bash
# ==============================================================================
# Script Name: tty_autologin_manager.sh
# Description: Manages TTY1 autologin for Linux (Hyprland/UWSM).
#              Supports both systemd and OpenRC.
#              Surgically idempotent, completely non-interactive capable.
# ==============================================================================

set -euo pipefail

readonly INIT_SYSTEM="openrc"

# --- Constants & Styling ---
readonly SYSTEMD_UNIT="getty@tty1.service"
readonly SYSTEMD_DIR="/etc/systemd/system/${SYSTEMD_UNIT}.d"
readonly SYSTEMD_OVERRIDE_FILE="${SYSTEMD_DIR}/override.conf"
readonly OPENRC_INITTAB="/etc/inittab"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly BLUE=$'\033[0;34m'
readonly YELLOW=$'\033[1;33m'
readonly NC=$'\033[0m'

# --- State Variables ---
MODE_AUTO=false
MODE_REVERT=false
CONFIRMED=false

# --- Logging ---
log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- CLI Parsing ---
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-a | --auto) MODE_AUTO=true ;;
		-r | --revert) MODE_REVERT=true ;;
		--_confirmed) CONFIRMED=true ;; # Internal flag for sudo escalation
		-h | --help)
			printf "Usage: %s [OPTIONS]\n" "${0##*/}"
			printf "Options:\n"
			printf "  -a, --auto    Run non-interactively (skip prompts)\n"
			printf "  -r, --revert  Revert autologin and restore standard TTY/SDDM\n"
			printf "  -h, --help    Show this help message\n"
			exit 0
			;;
		*)
			log_error "Unknown argument: $1"
			exit 1
			;;
		esac
		shift
	done
}

# --- Helpers ---
sddm_is_installed() {
	[[ -f /etc/init.d/sddm ]] || rc-service -l 2>/dev/null | grep -q "^sddm$"
}

sync_state_file() {
	local user="$1"
	local state="$2"
	local user_home

	# Reliably query the NSS database for the actual home directory
	user_home=$(getent passwd "${user}" | cut -d: -f6)
	if [[ -z "${user_home}" ]]; then
		log_error "Could not determine home directory for user: ${user}"
		exit 1
	fi

	local state_dir="${user_home}/.config/dawn/settings"
	local state_file="${state_dir}/auto_login_tty"

	# Drop privileges to target user to ensure correct ownership of directories and files
	sudo -u "${user}" mkdir -p "${state_dir}"
	echo "${state}" | sudo -u "${user}" tee "${state_file}" >/dev/null

	log_info "Dusky state synced: ${state_file} -> [${state}]"
}

# --- Interactivity ---
prompt_user() {
	local action="$1"
	local target="$2"

	# Bypass prompts if in auto mode or if already confirmed pre-escalation
	[[ "${MODE_AUTO}" == true || "${CONFIRMED}" == true ]] && return 0

	printf "\n${YELLOW}Arch Linux TTY1 Autologin Manager${NC}\n"

	if [[ "${action}" == "setup" ]]; then
		printf "Action: ${GREEN}ENABLE${NC} autologin for user ${GREEN}%s${NC}\n" "${target}"
	else
		printf "Action: ${RED}REVERT${NC} autologin and restore default behavior.\n"
	fi

	read -r -p "Proceed? [y/N] " response
	if [[ ! "${response}" =~ ^[yY](es)?$ ]]; then
		log_info "Operation cancelled by user."
		exit 0
	fi
}

# --- Core Logic ---
do_setup() {
	local user="$1"
	log_info "Configuring TTY1 autologin for: ${user} (${INIT_SYSTEM})"

	# OpenRC path - modify /etc/inittab
	if sddm_is_installed && rc-service sddm status >/dev/null 2>&1; then
		log_info "Disabling SDDM..."
		rc-update del sddm default 2>/dev/null || true
		log_success "SDDM disabled."
	fi

	# Check if already configured
	if grep -q "agetty.*--autologin.*${user}" "${OPENRC_INITTAB}" 2>/dev/null; then
		sync_state_file "${user}" "true"
		log_success "Autologin is already configured for ${user}. Nothing to do."
		return 0
	fi

	# Backup inittab
	cp "${OPENRC_INITTAB}" "${OPENRC_INITTAB}.bak"

	# Add autologin for tty1
	sed -i "s|^c1:12345:respawn:/sbin/agetty.*|c1:12345:respawn:/sbin/agetty --autologin ${user} --noclear %I linux|" "${OPENRC_INITTAB}"

	# If line doesn't exist, add it
	if ! grep -q "agetty.*--autologin.*${user}" "${OPENRC_INITTAB}" 2>/dev/null; then
		echo "c1:12345:respawn:/sbin/agetty --autologin ${user} --noclear %I linux" >>"${OPENRC_INITTAB}"
	fi

	# Tell init to reload
	init q 2>/dev/null || true

	sync_state_file "${user}" "true"
	log_success "Autologin configured successfully."
}

do_revert() {
	local user="$1"
	log_info "Reverting TTY1 autologin configuration... (${INIT_SYSTEM})"
	local changed=false

	# OpenRC
	if [[ -f "${OPENRC_INITTAB}" ]] && grep -q "agetty.*--autologin" "${OPENRC_INITTAB}" 2>/dev/null; then
		# Restore from backup if exists
		if [[ -f "${OPENRC_INITTAB}.bak" ]]; then
			cp "${OPENRC_INITTAB}.bak" "${OPENRC_INITTAB}"
		else
			# Remove autologin line
			sed -i "s|--autologin ${user}||g" "${OPENRC_INITTAB}"
		fi
		init q 2>/dev/null || true
		changed=true
		log_success "Removed autologin from inittab."
	fi

	if sddm_is_installed && ! rc-service sddm status >/dev/null 2>&1; then
		log_info "Re-enabling SDDM..."
		rc-update add sddm default 2>/dev/null || true
		changed=true
		log_success "SDDM enabled."
	fi

	sync_state_file "${user}" "false"

	if [[ "${changed}" == true ]]; then
		log_success "Revert complete. Standard TTY login / Display Manager restored."
	else
		log_success "System already in default state. Nothing to revert."
	fi
}

# --- Entry Point ---
main() {
	parse_args "$@"

	# 1. Determine Target Context
	local target_user
	if [[ "${EUID}" -eq 0 ]]; then
		target_user="${SUDO_USER:-}"
		if [[ -z "${target_user}" ]]; then
			log_error "Cannot determine target user from raw root shell."
			log_error "Execute the script directly as your standard user."
			exit 1
		fi
	else
		target_user="${USER}"
	fi

	# 2. Validate User Existence
	if ! id -u "${target_user}" &>/dev/null; then
		log_error "User '${target_user}' does not exist on this system."
		exit 1
	fi

	# 3. State Resolution & Prompting
	local action_type="setup"
	[[ "${MODE_REVERT}" == true ]] && action_type="revert"

	prompt_user "${action_type}" "${target_user}"

	# 4. Privilege Escalation
	if [[ "${EUID}" -ne 0 ]]; then
		log_info "Escalating privileges..."

		# Guard against exotic invocation methods (e.g. process substitution, piped input)
		if [[ ! -f "$0" ]] || [[ ! -r "$0" ]]; then
			log_error "Cannot re-execute: script path '$0' is not a regular readable file."
			log_error "Please save the script to disk and run it directly."
			exit 1
		fi

		# Build array payload to prevent word-splitting on re-execution
		local exec_args=("--_confirmed")
		[[ "${MODE_AUTO}" == true ]] && exec_args+=("--auto")
		[[ "${MODE_REVERT}" == true ]] && exec_args+=("--revert")

		exec sudo "$0" "${exec_args[@]}"
	fi

	# 5. Execution Routine
	if [[ "${MODE_REVERT}" == true ]]; then
		do_revert "${target_user}"
	else
		do_setup "${target_user}"
	fi
}

main "$@"
