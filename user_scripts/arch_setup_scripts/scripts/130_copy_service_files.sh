#!/usr/bin/env bash
# Installs OpenRC system and user service scripts and manages their state.
# ==============================================================================
# SERVICE INSTALLER (OpenRC System + User)
# ==============================================================================
# Description: Installs and manages both system-level and user-level OpenRC
#              service init scripts. System services require root; user services
#              do not. Correctly resolves $REAL_HOME when run via sudo.
# Standards:   Bash 5+, set -euo pipefail, Auto-Sudo for system services
# ==============================================================================

set -euo pipefail

# --- Resolve real user home directory (handles sudo) ---
REAL_HOME="${SUDO_USER_HOME:-}"
if [[ -z "${REAL_HOME}" ]] && [[ -n "${SUDO_USER:-}" ]]; then
	REAL_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
fi
REAL_HOME="${REAL_HOME:-$HOME}"

# --- Color Support ---
# Only use colors if connected to a terminal (prevents log pollution)
if [[ -t 1 ]]; then
	readonly RED=$'\033[0;31m'
	readonly GREEN=$'\033[0;32m'
	readonly BLUE=$'\033[0;34m'
	readonly YELLOW=$'\033[1;33m'
	readonly NC=$'\033[0m' # No Color
else
	readonly RED="" GREEN="" BLUE="" YELLOW="" NC=""
fi

# --- Configuration ---
# Define your services here.
# Format: "ABSOLUTE_PATH_TO_SOURCE | DEFAULT_ACTION"
# Actions:
#   'enable'  -> Default to Start & Enable (Enter = Yes)
#   'disable' -> Default to Stop & Disable (Enter = No)
readonly SERVICES_CONFIG=(
	# Example 0: Bluetooth Monitor (Default: Disable)
	# "$REAL_HOME/user_scripts/waybar/bluetooth/bt_monitor.service | disable"

	# Add your own paths below...

	# Example 1: Network Meter (Default: Enable)
	"$REAL_HOME/user_scripts/waybar/network/network_meter.service | enable"

	# Dusky Control Center Daemon (Default: Disable)
	"$REAL_HOME/user_scripts/dawn_system/control_center/service/dawn.service | disable"

	# dawn update checker
	"$REAL_HOME/user_scripts/update_dawn/update_checker/service/update_checker.service | disable"
	"$REAL_HOME/user_scripts/update_dawn/update_checker/service/update_checker.timer | enable"

	# dawn sliders
	"$REAL_HOME/user_scripts/sliders/service/dawn_sliders.service | disable"
)

# OpenRC init scripts (system-level, for Artix Linux)
readonly OPENRC_SERVICES_CONFIG=(
	"$REAL_HOME/user_scripts/openrc/init.d/network-meter | enable"
	"$REAL_HOME/user_scripts/openrc/init.d/dawn-sliders | disable"
	"$REAL_HOME/user_scripts/openrc/init.d/update-checker | disable"
	"$REAL_HOME/user_scripts/openrc/init.d/waybar | enable"
	"$REAL_HOME/user_scripts/openrc/init.d/swww | disable"
)

# OpenRC user service scripts (user-level, no root needed)
readonly OPENRC_USER_SERVICES_CONFIG=(
	"$REAL_HOME/user_scripts/openrc/user/init.d/hypridle | disable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/hyprsunset | disable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/swayosd | enable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/network-meter | enable"
	# pipewire/wireplumber/pipewire-pulse: installed by -openrc packages to /etc/user/init.d/
	"$REAL_HOME/user_scripts/openrc/user/init.d/battery-notify | enable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/dawn-control-center | disable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/dawn-sliders | disable"
	"$REAL_HOME/user_scripts/openrc/user/init.d/update-checker | disable"
)

# XDG Standard: ~/.config/systemd/user
readonly SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/systemd/user"

# Detect init system
readonly INIT_SYSTEM="openrc"

# --- Privilege Check ---
if [[ "$INIT_SYSTEM" == "openrc" && "$EUID" -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

# --- Helper Functions ---

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# Pure Bash whitespace trimmer (High Performance)
trim() {
	local s="$1"
	# Remove leading whitespace
	s="${s#"${s%%[![:space:]]*}"}"
	# Remove trailing whitespace
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

	# Extract filename using pure bash (faster than basename)
	service_name="${source_path##*/}"

	# Remove .service extension for OpenRC
	local openrc_service_name="${service_name%.service}"

	echo "------------------------------------------------"
	log_info "Processing: $service_name (init: $INIT_SYSTEM)"

	# Validation
	if [[ ! -f "$source_path" ]]; then
		log_error "Source file not found: $source_path"
		log_warn "Skipping..."
		return 0
	fi

	# Installation and enablement based on init system
	case "$INIT_SYSTEM" in
	systemd)
		target_file="${SYSTEMD_USER_DIR}/${service_name}"
		log_info "Installing to $target_file..."
		install -D -m 644 -- "$source_path" "$target_file"
		;;
	openrc)
		log_info "Installing to /etc/init.d/$openrc_service_name..."
		install -m 755 -- "$source_path" "/etc/init.d/$openrc_service_name"
		;;
	*)
		log_error "No init system detected. Skipping..."
		return 1
		;;
	esac

	# Interactive State Management
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

	# Determine choice based on input or default
	if [[ -z "$user_input" ]]; then
		if [[ "$default_action" == "enable" ]]; then
			user_choice="y"
		else
			user_choice="n"
		fi
	else
		user_choice="${user_input,,}"
	fi

	# Execute Action
	case "$user_choice" in
	y | yes)
		log_info "Starting..."
		case "$INIT_SYSTEM" in
		systemd) ;;
		openrc)
			rc-update add "$openrc_service_name" default 2>/dev/null || true
			rc-service "$openrc_service_name" start 2>/dev/null || true
			;;
		esac
		log_success "$service_name is active."
		;;
	*)
		log_info "Stopping..."
		case "$INIT_SYSTEM" in
		systemd) ;;
		openrc)
			rc-service "$openrc_service_name" stop 2>/dev/null || true
			rc-update del "$openrc_service_name" default 2>/dev/null || true
			;;
		esac
		log_success "$service_name is inactive."
		;;
	esac
}

install_and_manage_user() {
	local source_path="$1"
	local default_action="$2"
	local service_name
	local target_file
	local user_init_dir="${XDG_CONFIG_HOME:-$REAL_HOME/.config}/rc/init.d"
	local prompt_msg
	local user_input
	local user_choice

	service_name="${source_path##*/}"

	echo "------------------------------------------------"
	log_info "Processing (user): $service_name"

	if [[ ! -f "$source_path" ]]; then
		log_error "Source file not found: $source_path"
		log_warn "Skipping..."
		return 0
	fi

	# Install to user init.d directory
	target_file="${user_init_dir}/${service_name}"
	log_info "Installing to $target_file..."
	mkdir -p "${user_init_dir}"
	install -D -m 755 -- "$source_path" "$target_file"

	# Interactive State Management
	if [[ "${use_defaults:-false}" == "true" ]]; then
		log_info "Auto-applying default action ($default_action)..."
		user_input=""
	else
		if [[ "$default_action" == "enable" ]]; then
			prompt_msg="Enable and Start (user) $service_name? [Y/n] (Default: Yes): "
		else
			prompt_msg="Enable and Start (user) $service_name? [y/N] (Default: No): "
		fi

		printf "${YELLOW}%s${NC}" "$prompt_msg"
		read -r user_input </dev/tty || true
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
		log_info "Starting (user)..."
		rc-update --user add "$service_name" default 2>/dev/null || true
		rc-service "$service_name" --user start 2>/dev/null || true
		log_success "$service_name is active (user)."
		;;
	*)
		log_info "Stopping (user)..."
		rc-service "$service_name" --user stop 2>/dev/null || true
		rc-update --user del "$service_name" default 2>/dev/null || true
		log_success "$service_name is inactive (user)."
		;;
	esac
}

main() {
	# Argument Parsing
	local use_defaults="false"
	for arg in "$@"; do
		if [[ "$arg" == "--default" ]]; then
			use_defaults="true"
		fi
	done

	# Pre-flight checks
	if [[ "$INIT_SYSTEM" == "unknown" ]]; then
		log_error "No init system detected (systemd or OpenRC)."
		log_info "For Artix Linux, install: pacman -S openrc elogind"
		exit 1
	fi

	log_info "Detected init system: $INIT_SYSTEM"

	local entry
	local src_path
	local action

	# Choose config based on init system
	local config_array
	config_array=("${OPENRC_SERVICES_CONFIG[@]}")

	if [[ ${#config_array[@]} -eq 0 ]]; then
		log_warn "No services configured in SERVICES_CONFIG."
		exit 0
	fi

	log_info "Starting Service Manager..."

	# --- Phase 1: System-level OpenRC services (require root) ---
	local entry
	local src_path
	local action

	config_array=("${OPENRC_SERVICES_CONFIG[@]}")

	if [[ ${#config_array[@]} -gt 0 ]]; then
		log_info "=== System Services (require root) ==="
		for entry in "${config_array[@]}"; do
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
	fi

	# --- Phase 2: User-level OpenRC services (no root needed) ---
	config_array=("${OPENRC_USER_SERVICES_CONFIG[@]}")

	if [[ ${#config_array[@]} -gt 0 ]]; then
		log_info "=== User Services (no root needed) ==="
		for entry in "${config_array[@]}"; do
			IFS='|' read -r src_path action <<<"$entry"
			src_path=$(trim "$src_path")
			action=$(trim "$action")
			[[ -z "$src_path" ]] && continue
			if [[ "$action" != "enable" && "$action" != "disable" ]]; then
				log_warn "Invalid default action '$action' for $src_path. Defaulting to 'disable'."
				action="disable"
			fi
			install_and_manage_user "$src_path" "$action"
		done
	fi

	echo "------------------------------------------------"
	log_success "All operations completed."
}

# --- Cleanup Trap ---
cleanup() {
	local exit_code=$?
	if [[ $exit_code -ne 0 ]]; then
		log_error "Script failed or was interrupted (Exit Code: $exit_code)."
	fi
}
trap cleanup EXIT
trap 'exit 130' INT # Handle Ctrl+C gracefully

main "$@"
