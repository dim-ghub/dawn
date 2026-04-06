#!/usr/bin/env bash
# Clipboard Persistence RAM/Disk
# -----------------------------------------------------------------------------
# Clipboard Persistence Manager - v2.0.0 (OpenRC Compatible)
# -----------------------------------------------------------------------------
# Target: Artix Linux / Hyprland / OpenRC / Wayland
#
# Description: Toggles cliphist persistence between RAM and disk storage.
#              Stores configuration in ~/.config/dawn/clipboard_persistence.conf
#
# v2.0.0 CHANGELOG:
#   - BREAKING: Removed UWSM dependency (systemd-only, incompatible with OpenRC)
#   - FEAT: Uses local config file instead of UWSM env files
#   - FEAT: Sets CLIPHIST_DB_PATH in hyprland environment variables
#   - FEAT: Direct daemon respawn without uwsm-app wrapper
# v1.2.0 CHANGELOG:
#   - FEAT: Added --ram and --disk flags for non-interactive automation.
#   - REF:  Conditional TTY check (only required for interactive mode).
# v1.1.0 CHANGELOG:
#   - CRITICAL: Replaced sed -i with atomic awk + cat to preserve symlinks.
#   - FIX: Proper cleanup trap function instead of inline trap.
#   - FIX: Consistent ANSI constant declarations (declare -r).
#   - FIX: Added Bash version check (5.0+ required).
#   - FIX: Added TTY check for interactive read.
#   - FIX: Added dependency checks (awk, grep).
#   - FIX: Added file writability check.
#   - FIX: Secure temp file creation and cleanup.
#   - STYLE: Aligned with Dusky TUI Engine master template v3.9.1.
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# ANSI Constants
# =============================================================================
declare -r C_RESET=$'\033[0m'
declare -r C_RED=$'\033[0;31m'
declare -r C_GREEN=$'\033[0;32m'
declare -r C_BLUE=$'\033[0;34m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_BOLD=$'\033[1m'

# =============================================================================
# Configuration
# =============================================================================
declare -r CONFIG_DIR="${HOME}/.config/dawn"
declare -r CONFIG_FILE="${CONFIG_DIR}/clipboard_persistence.conf"
declare -r ENV_FILE="${HOME}/.config/hypr/edit_here/source/environment_variables.conf"
declare -r STATE_DIR="${HOME}/.config/dawn/settings"
declare -r STATE_FILE="${STATE_DIR}/clipboard_persistance"

# Default config values
declare -r PERSISTENT_VALUE='true' # true = disk, false = RAM
declare -r EPHEMERAL_VALUE='false'

# =============================================================================
# Temp File Global (for cleanup safety)
# =============================================================================
declare _TMPFILE=""

# =============================================================================
# Argument Parsing (v2.0.0)
# =============================================================================
declare _TARGET_MODE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	--ram)
		_TARGET_MODE="ephemeral"
		shift
		;;
	--disk)
		_TARGET_MODE="persistent"
		shift
		;;
	*)
		printf '%s[ERROR]%s Unknown argument: %s\n' "$C_RED" "$C_RESET" "$1" >&2
		exit 1
		;;
	esac
done

# =============================================================================
# Logging
# =============================================================================
log_info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

# =============================================================================
# Cleanup & Traps
# =============================================================================
cleanup() {
	# Secure temp file cleanup
	if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
		rm -f "$_TMPFILE" 2>/dev/null || :
	fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# =============================================================================
# Pre-flight Checks
# =============================================================================

# Bash version gate
if ((BASH_VERSINFO[0] < 5)); then
	log_err "Bash 5.0+ required."
	exit 1
fi

# TTY check (Only required if NO automation flags provided)
if [[ -z "$_TARGET_MODE" && ! -t 0 ]]; then
	log_err "Interactive TTY required."
	log_info "Use --ram or --disk for non-interactive mode."
	exit 1
fi

# Root guard — editing ~/.config as root breaks file ownership
if [[ $EUID -eq 0 ]]; then
	log_err "Do NOT run this script as root/sudo."
	log_err "This script modifies your personal user configuration (~/.config)."
	log_err "Please run again as your normal user."
	exit 1
fi

# Dependency checks
declare _dep
for _dep in awk grep; do
	if ! command -v "$_dep" &>/dev/null; then
		log_err "Missing dependency: ${_dep}"
		exit 1
	fi
done
unset _dep

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Create config file if it doesn't exist (default to persistent/disk)
if [[ ! -f "$CONFIG_FILE" ]]; then
	echo "PERSISTENT=${PERSISTENT_VALUE}" >"$CONFIG_FILE"
	log_info "Created default config at: ${CONFIG_FILE}"
fi

# =============================================================================
# Core Logic — Read/Write Config
# =============================================================================

get_current_mode() {
	if grep -q '^PERSISTENT=true' "$CONFIG_FILE" 2>/dev/null; then
		echo "persistent"
	else
		echo "ephemeral"
	fi
}

update_hyprland_env() {
	local mode="$1"

	mkdir -p "$(dirname "$ENV_FILE")"

	# Create the env file if it doesn't exist
	if [[ ! -f "$ENV_FILE" ]]; then
		cat >"$ENV_FILE" <<'EOF'
# Hyprland Environment Variables
# Add your custom environment variables here
EOF
	fi

	# Check if CLIPHIST_DB_PATH is already defined
	if grep -q 'CLIPHIST_DB_PATH' "$ENV_FILE" 2>/dev/null; then
		# Remove existing CLIPHIST_DB_PATH lines
		_TMPFILE=$(mktemp "${ENV_FILE}.tmp.XXXXXXXXXX")
		grep -v 'CLIPHIST_DB_PATH' "$ENV_FILE" >"$_TMPFILE"
		cat "$_TMPFILE" >"$ENV_FILE"
		rm -f "$_TMPFILE"
		_TMPFILE=""
	fi

	# Add the new CLIPHIST_DB_PATH based on mode
	if [[ "$mode" == "persistent" ]]; then
		# Persistent: use default cache location (comment out CLIPHIST_DB_PATH)
		echo "# CLIPHIST_DB_PATH commented - using default cache location for persistence" >>"$ENV_FILE"
		echo "# export CLIPHIST_DB_PATH=\"\${HOME}/.cache/cliphist.db\"" >>"$ENV_FILE"
	else
		# Ephemeral: use XDG_RUNTIME_DIR (RAM-based)
		echo "# CLIPHIST_DB_PATH set to RAM for ephemeral storage" >>"$ENV_FILE"
		echo 'export CLIPHIST_DB_PATH="${XDG_RUNTIME_DIR}/cliphist.db"' >>"$ENV_FILE"
	fi
}

update_config() {
	local mode="$1"

	mkdir -p "$STATE_DIR"
	mkdir -p "$CONFIG_DIR"

	if [[ "$mode" == "ephemeral" ]]; then
		local current_mode
		current_mode=$(get_current_mode)

		if [[ "$current_mode" == "ephemeral" ]]; then
			log_info "Config is already set to Ephemeral (RAM-based)."
			echo "false" >"$STATE_FILE"
			return 0
		fi

		# Update config file
		echo "PERSISTENT=false" >"$CONFIG_FILE"

		# Update hyprland environment
		update_hyprland_env "ephemeral"

		echo "false" >"$STATE_FILE"
		log_success "Set to Ephemeral (RAM-based). Clipboard will clear on reboot."

	elif [[ "$mode" == "persistent" ]]; then
		local current_mode
		current_mode=$(get_current_mode)

		if [[ "$current_mode" == "persistent" ]]; then
			log_info "Config is already set to Persistent (disk-based)."
			echo "true" >"$STATE_FILE"
			return 0
		fi

		# Update config file
		echo "PERSISTENT=true" >"$CONFIG_FILE"

		# Update hyprland environment
		update_hyprland_env "persistent"

		echo "true" >"$STATE_FILE"
		log_success "Set to Persistent (disk-based). Clipboard will survive reboots."
	fi

	return 0
}

# =============================================================================
# User Interface (Hybrid)
# =============================================================================

if [[ -n "$_TARGET_MODE" ]]; then
	# --- Automated Mode ---
	if [[ "$_TARGET_MODE" == "ephemeral" ]]; then
		log_info "Applying Ephemeral settings (--ram)..."
		update_config "ephemeral"
	elif [[ "$_TARGET_MODE" == "persistent" ]]; then
		log_info "Applying Persistent settings (--disk)..."
		update_config "persistent"
	fi

else
	# --- Interactive Mode ---
	clear
	printf '%sClipboard Persistence Manager%s\n' "$C_BOLD" "$C_RESET"
	printf 'Target: %s\n\n' "$CONFIG_FILE"

	printf '%sWhich mode do you prefer?%s\n\n' "$C_BOLD" "$C_RESET"

	printf '  %s1) Ephemeral (RAM-based)%s\n' "$C_BOLD" "$C_RESET"
	printf '     - Clipboard history is stored in RAM.\n'
	printf '     - It %sdisappears%s when you reboot or shutdown.\n' "$C_RED" "$C_RESET"
	printf '     - Good for privacy and saving disk writes.\n\n'

	printf '  %s2) Persistent (Disk-based)%s\n' "$C_BOLD" "$C_RESET"
	printf '     - Clipboard history is stored on your hard drive.\n'
	printf '     - Your history %sstays available%s even after you reboot.\n' "$C_GREEN" "$C_RESET"
	printf '     - Standard behavior for most users.\n\n'

	read -rp "Select option [1/2] (default: 1): " choice
	choice="${choice:-1}"

	case "$choice" in
	1)
		log_info "Applying Ephemeral settings..."
		update_config "ephemeral"
		;;
	2)
		log_info "Applying Persistent settings..."
		update_config "persistent"
		;;
	*)
		log_err "Invalid selection. Exiting."
		exit 1
		;;
	esac
fi

# =============================================================================
# Post-Process (Live Daemon Reload)
# =============================================================================
log_info "Reloading clipboard daemons..."

# 1. Determine the path to export for the new daemons
if [[ "$_TARGET_MODE" == "ephemeral" || "${choice:-}" == "1" ]]; then
	export CLIPHIST_DB_PATH="${XDG_RUNTIME_DIR:-/tmp}/cliphist.db"
else
	# Unsetting forces cliphist to fall back to the default ~/.cache location
	unset CLIPHIST_DB_PATH
fi

# 2. Terminate existing watchers securely (regex match to avoid killing random manual wl-paste tasks)
pkill -f "wl-paste.*cliphist" 2>/dev/null || :

# 3. Respawn the daemons detached from the script's lifecycle
# Direct execution without uwsm-app wrapper
if [[ -n "${CLIPHIST_DB_PATH:-}" ]]; then
	CLIPHIST_DB_PATH="$CLIPHIST_DB_PATH" wl-paste --type text --watch cliphist store >/dev/null 2>&1 &
	CLIPHIST_DB_PATH="$CLIPHIST_DB_PATH" wl-paste --type image --watch cliphist store >/dev/null 2>&1 &
else
	wl-paste --type text --watch cliphist store >/dev/null 2>&1 &
	wl-paste --type image --watch cliphist store >/dev/null 2>&1 &
fi
disown -a

log_success "Daemons reloaded. New persistence mode is now active."

# =============================================================================
# NOTE: Hyprland Restart May Be Required
# =============================================================================
printf '\n'
printf '%sNOTE%s\n' "$C_BOLD" "$C_RESET"
printf 'For changes to fully take effect, restart Hyprland or log out and back in.\n'
printf 'The clipboard daemon has been restarted with the new settings.\n'
