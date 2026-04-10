#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: service_manager.sh
# Description: Installs multiple OpenRC user services and manages their state.
# Environment: Arch Linux / Hyprland / OpenRC
# Author: DevOps Assistant
# -----------------------------------------------------------------------------

# --- Strict Error Handling ---
set -euo pipefail

# --- Color Support ---
if [[ -t 1 ]]; then
	readonly RED=$'\033[0;31m'
	readonly GREEN=$'\033[0;32m'
	readonly BLUE=$'\033[0;34m'
	readonly YELLOW=$'\033[1;33m'
	readonly NC=$'\033[0m'
else
	readonly RED="" GREEN="" BLUE="" YELLOW="" NC=""
fi

# --- Configuration ---
readonly SERVICES_CONFIG=(
	"$HOME/user_scripts/dawn_system/control_center/service/dawn.service | disable"
	"$HOME/user_scripts/update_dawn/update_checker/service/update_checker.service | disable"
	"$HOME/user_scripts/update_dawn/update_checker/service/update_checker.timer | enable"
	"$HOME/user_scripts/sliders/service/dawn_sliders.service | disable"
)

# XDG Standard for OpenRC user services: ~/.config/init.d or direct /etc/init.d
readonly OPENRC_USER_DIR="/etc/init.d"

# --- Helper Functions ---

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	s="${s%"${s##*[![:space:]]}"}"
	printf '%s' "$s"
}

# --- Main Logic ---

install_and_manage() {
	local source_path="$1"
	local default_action="$2"
	local service_name
	local target_file
	local prompt_msg
	local user_input
	local user_choice

	service_name="${source_path##*/}"
	service_name="${service_name%.service}"
	target_file="${OPENRC_USER_DIR}/${service_name}"

	echo "------------------------------------------------"
	log_info "Processing: $service_name"

	if [[ ! -f "$source_path" ]]; then
		log_error "Source file not found: $source_path"
		log_warn "Skipping..."
		return 0
	fi

	log_info "Installing to $target_file..."
	install -D -m 755 -- "$source_path" "$target_file"

	if [[ "${use_defaults:-false}" == "true" ]]; then
		log_info "Auto-applying default action ($default_action)..."
		user_input=""
	else
		if [[ "$default_action" == "enable" ]]; then
			prompt_msg="Enable and Start $service_name? [Y/n] (Default: Yes): "
		else
			prompt_msg="Enable and Start $service_name? [y/N] (Default: No): "
		fi

		printf "${YELLOW}%s${NC}" "$prompt_msg"
		read -r user_input || true
	fi

	if [[ -z "$user_input" ]]; then
		if [[ "$default_action" == "enable" ]]; then
			user_choice="y"
		else
			user_choice="n"
		fi
	else
		user_choice="${user_input,,}"
	fi

	case "$user_choice" in
	y | yes)
		log_info "Enabling and Starting..."
		rc-update add "$service_name" default 2>/dev/null || true
		rc-service "$service_name" start 2>/dev/null || true
		log_success "$service_name is active."
		;;
	*)
		log_info "Disabling/Stopping..."
		rc-service "$service_name" stop 2>/dev/null || true
		rc-update del "$service_name" default 2>/dev/null || true
		log_success "$service_name is inactive."
		;;
	esac
}

main() {
	local use_defaults="false"
	for arg in "$@"; do
		if [[ "$arg" == "--default" ]]; then
			use_defaults="true"
		fi
	done

	if ! command -v rc-service &>/dev/null; then
		log_error "OpenRC (rc-service) not found. This script requires OpenRC."
		exit 1
	fi

	if [[ ${#SERVICES_CONFIG[@]} -eq 0 ]]; then
		log_warn "No services configured in SERVICES_CONFIG."
		exit 0
	fi

	log_info "Starting Service Manager..."

	local entry
	local src_path
	local action

	for entry in "${SERVICES_CONFIG[@]}"; do
		IFS='|' read -r src_path action <<<"$entry"

		src_path=$(trim "$src_path")
		action=$(trim "$action")

		[[ -z "$src_path" ]] && continue

		if [[ "$action" != "enable" && "$action" != "disable" ]]; then
			log_warn "Invalid default action '$action' for $src_path. Defaulting to 'disable'."
			action="disable"
		fi

		install_and_manage "$src_path" "$action"
	done

	echo "------------------------------------------------"
	log_success "All operations completed."
}

cleanup() {
	local exit_code=$?
	if ((exit_code != 0)); then
		log_error "Script failed or was interrupted (Exit Code: $exit_code)."
	fi
}
trap cleanup EXIT
trap 'exit 130' INT

main "$@"
