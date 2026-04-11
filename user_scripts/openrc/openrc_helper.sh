#!/usr/bin/env bash
# ==============================================================================
# OpenRC Detection Helper
# Provides functions to detect init system and run appropriate commands.
# Supports both system-level and user-level OpenRC service management.
# Source this file in your scripts: source /path/to/openrc_helper.sh
# ==============================================================================

# Detect init system once and export
_openrc_helper_detect_init() {
	if command -v rc-service >/dev/null 2>&1; then
		echo "openrc"
	else
		echo "unknown"
	fi
}

# Set INIT_SYSTEM if not already set
if [[ -z "${INIT_SYSTEM:-}" ]]; then
	readonly INIT_SYSTEM=$(_openrc_helper_detect_init)
fi

# ─── System-level Service Functions ───────────────────────────────────────────

# Helper to run commands based on init system
# Usage: run_as_init "systemd" "systemctl enable foo" "rc-update add foo default"
run_as_init() {
	local cmd_openrc="$1"

	case "$INIT_SYSTEM" in
	openrc) eval "$cmd_openrc" ;;
	*)
		echo "Unknown init system" >&2
		return 1
		;;
	esac
}

# Check if a system service is active
# Usage: is_service_active "NetworkManager"
is_service_active() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" status >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# Check if a system service is enabled
# Usage: is_service_enabled "NetworkManager"
is_service_enabled() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-update show default 2>/dev/null | grep -q "^[[:space:]]*$svc[[:space:]]" ;;
	*) return 1 ;;
	esac
}

# Start a system service
# Usage: svc_start "NetworkManager"
svc_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" start ;;
	*) return 1 ;;
	esac
}

# Stop a system service
# Usage: svc_stop "NetworkManager"
svc_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" stop ;;
	*) return 1 ;;
	esac
}

# Enable and start a system service
# Usage: svc_enable_start "NetworkManager"
svc_enable_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc)
		rc-update add "$svc" default
		rc-service "$svc" start
		;;
	esac
}

# Disable and stop a system service
# Usage: svc_disable_stop "NetworkManager"
svc_disable_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc)
		rc-service "$svc" stop 2>/dev/null || true
		rc-update del "$svc" default 2>/dev/null || true
		;;
	esac
}

# Restart a system service
# Usage: svc_restart "NetworkManager"
svc_restart() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" restart ;;
	*) return 1 ;;
	esac
}

# Reload daemon (OpenRC no-op)
svc_reload_daemon() {
	case "$INIT_SYSTEM" in
	openrc) ;; # No-op for OpenRC
	esac
}

# Get system service status output
# Usage: svc_status "NetworkManager"
svc_status() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" status ;;
	esac
}

# ─── User-level Service Functions ────────────────────────────────────────────
# These use rc-service --user / rc-update --user / rc-status --user.
# Service scripts live in ${XDG_CONFIG_HOME:-$HOME/.config}/rc/init.d/
# Runlevels in ${XDG_CONFIG_HOME:-$HOME/.config}/rc/runlevels/
# Requires XDG_RUNTIME_DIR to be set.

# Check if a user service is active
# Usage: is_user_service_active "hypridle"
is_user_service_active() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" --user status >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# Check if a user service is enabled
# Usage: is_user_service_enabled "hypridle"
is_user_service_enabled() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-update --user show default 2>/dev/null | grep -q "^[[:space:]]*$svc[[:space:]]" ;;
	*) return 1 ;;
	esac
}

# Start a user service
# Usage: user_svc_start "hypridle"
user_svc_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" --user start ;;
	*) return 1 ;;
	esac
}

# Stop a user service
# Usage: user_svc_stop "hypridle"
user_svc_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" --user stop ;;
	*) return 1 ;;
	esac
}

# Enable and start a user service
# Usage: user_svc_enable_start "hypridle"
user_svc_enable_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc)
		rc-update --user add "$svc" default
		rc-service "$svc" --user start
		;;
	esac
}

# Disable and stop a user service
# Usage: user_svc_disable_stop "hypridle"
user_svc_disable_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc)
		rc-service "$svc" --user stop 2>/dev/null || true
		rc-update --user del "$svc" default 2>/dev/null || true
		;;
	esac
}

# Restart a user service
# Usage: user_svc_restart "hypridle"
user_svc_restart() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" --user restart ;;
	*) return 1 ;;
	esac
}

# Get user service status output
# Usage: user_svc_status "hypridle"
user_svc_status() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	openrc) rc-service "$svc" --user status ;;
	esac
}

# List all available user services (from ~/.config/rc/init.d/ and /etc/user/init.d/)
# Usage: user_svc_list
user_svc_list() {
	local -a services=()
	local user_init_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rc/init.d"
	local sys_user_init_dir="/etc/user/init.d"

	for svc in "$user_init_dir"/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
	done

	for svc in "$sys_user_init_dir"/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
	done

	rc-service --user --list 2>/dev/null | while read -r svc; do
		services+=("$svc")
	done

	printf '%s\n' "${services[@]}" | sort -u
}

# ─── Shared ───────────────────────────────────────────────────────────────────

# Log info message
log_init_info() {
	echo "[INFO] [$INIT_SYSTEM] $*"
}

# Export ALL functions
export -f run_as_init is_service_active is_service_enabled
export -f svc_start svc_stop svc_enable_start svc_disable_stop svc_restart
export -f svc_reload_daemon svc_status log_init_info
export -f is_user_service_active is_user_service_enabled
export -f user_svc_start user_svc_stop user_svc_enable_start user_svc_disable_stop
export -f user_svc_restart user_svc_status user_svc_list
