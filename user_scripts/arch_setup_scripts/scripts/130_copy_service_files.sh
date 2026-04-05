#!/usr/bin/env bash
# Installs multiple systemd user services and manages their state.
# Supports both systemd and OpenRC.

# --- Strict Error Handling ---
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
# -o pipefail: pipeline return status is the value of the last (failed) command.
set -euo pipefail

# --- Privilege Check ---
if [[ "$INIT_SYSTEM" == "openrc" && "$EUID" -ne 0 ]]; then
	exec sudo "$0" "$@"
fi

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
	# "$HOME/user_scripts/waybar/bluetooth/bt_monitor.service | disable"

	# Add your own paths below...

	# Example 1: Network Meter (Default: Enable)
	"$HOME/user_scripts/waybar/network/network_meter.service | enable"

	# Dusky Control Center Daemon (Default: Disable)
	"$HOME/user_scripts/dusky_system/control_center/service/dusky.service | disable"

	# dusky update checker
	"$HOME/user_scripts/update_dusky/update_checker/service/update_checker.service | disable"
	"$HOME/user_scripts/update_dusky/update_checker/service/update_checker.timer | enable"

	# dusky sliders
	"$HOME/user_scripts/sliders/service/dusky_sliders.service | disable"
)

# OpenRC init scripts (for Artix Linux)
readonly OPENRC_SERVICES_CONFIG=(
	"$HOME/user_scripts/openrc/init.d/network-meter | enable"
	"$HOME/user_scripts/openrc/init.d/dusky-sliders | disable"
	"$HOME/user_scripts/openrc/init.d/update-checker | disable"
	"$HOME/user_scripts/openrc/init.d/waybar | enable"
	"$HOME/user_scripts/openrc/init.d/hypridle | disable"
	"$HOME/user_scripts/openrc/init.d/pipewire | enable"
	"$HOME/user_scripts/openrc/init.d/wireplumber | enable"
	"$HOME/user_scripts/openrc/init.d/swww | disable"
)

# XDG Standard: ~/.config/systemd/user
readonly SYSTEMD_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

# Detect init system
detect_init() {
	if command -v systemctl >/dev/null 2>&1; then
		echo "systemd"
	elif command -v rc-service >/dev/null 2>&1; then
		echo "openrc"
	else
		echo "unknown"
	fi
}

readonly INIT_SYSTEM=$(detect_init)

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
		systemctl --user daemon-reload
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
		log_info "Enabling and Starting..."
		case "$INIT_SYSTEM" in
		systemd)
			systemctl --user enable --now "$service_name"
			;;
		openrc)
			rc-update add "$openrc_service_name" default 2>/dev/null || true
			rc-service "$openrc_service_name" start 2>/dev/null || true
			;;
		esac
		log_success "$service_name is active."
		;;
	*)
		log_info "Disabling/Stopping..."
		case "$INIT_SYSTEM" in
		systemd)
			systemctl --user disable --now "$service_name" 2>/dev/null || true
			;;
		openrc)
			rc-service "$openrc_service_name" stop 2>/dev/null || true
			rc-update del "$openrc_service_name" default 2>/dev/null || true
			;;
		esac
		log_success "$service_name is inactive."
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
	if [[ "$INIT_SYSTEM" == "systemd" ]]; then
		config_array=("${SERVICES_CONFIG[@]}")
	else
		config_array=("${OPENRC_SERVICES_CONFIG[@]}")
	fi

	if [[ ${#config_array[@]} -eq 0 ]]; then
		log_warn "No services configured in SERVICES_CONFIG."
		exit 0
	fi

	log_info "Starting Service Manager..."

	# Iterate over the configuration array
	for entry in "${config_array[@]}"; do
		# Split string by delimiter '|'
		IFS='|' read -r src_path action <<<"$entry"

		# Trim whitespace using pure bash function
		src_path=$(trim "$src_path")
		action=$(trim "$action")

		# Skip empty lines if any exist
		[[ -z "$src_path" ]] && continue

		# Validate action config
		if [[ "$action" != "enable" && "$action" != "disable" ]]; then
			log_warn "Invalid default action '$action' for $src_path. Defaulting to 'disable'."
			action="disable"
		fi

		install_and_manage "$src_path" "$action"
	done

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
