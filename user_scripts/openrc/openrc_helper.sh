#!/usr/bin/env bash
# ==============================================================================
# OpenRC Detection Helper
# Provides functions to detect init system and run appropriate commands
# Source this file in your scripts: source /path/to/openrc_helper.sh
# ==============================================================================

# Detect init system once and export
_openrc_helper_detect_init() {
	if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
		echo "systemd"
	elif command -v rc-service >/dev/null 2>&1; then
		echo "openrc"
	else
		echo "unknown"
	fi
}

# Set INIT_SYSTEM if not already set
if [[ -z "${INIT_SYSTEM:-}" ]]; then
	readonly INIT_SYSTEM=$(_openrc_helper_detect_init)
fi

# Helper to run commands based on init system
# Usage: run_as_init "systemd" "systemctl enable foo" "rc-update add foo default"
run_as_init() {
	local cmd_systemd="$1"
	local cmd_openrc="$2"

	case "$INIT_SYSTEM" in
	systemd) eval "$cmd_systemd" ;;
	openrc) eval "$cmd_openrc" ;;
	*)
		echo "Unknown init system" >&2
		return 1
		;;
	esac
}

# Check if service is active
# Usage: is_service_active "NetworkManager"
is_service_active() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl is-active "$svc" >/dev/null 2>&1 ;;
	openrc) rc-service "$svc" status >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# Check if service is enabled
# Usage: is_service_enabled "NetworkManager"
is_service_enabled() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl is-enabled "$svc" >/dev/null 2>&1 ;;
	openrc) rc-update show default 2>/dev/null | grep -q "^[[:space:]]*$svc[[:space:]]" ;;
	*) return 1 ;;
	esac
}

# Start a service
# Usage: svc_start "NetworkManager"
svc_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl start "$svc" ;;
	openrc) rc-service "$svc" start ;;
	*) return 1 ;;
	esac
}

# Stop a service
# Usage: svc_stop "NetworkManager"
svc_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl stop "$svc" ;;
	openrc) rc-service "$svc" stop ;;
	*) return 1 ;;
	esac
}

# Enable and start a service
# Usage: svc_enable_start "NetworkManager"
svc_enable_start() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd)
		systemctl enable "$svc"
		systemctl start "$svc"
		;;
	openrc)
		rc-update add "$svc" default
		rc-service "$svc" start
		;;
	esac
}

# Disable and stop a service
# Usage: svc_disable_stop "NetworkManager"
svc_disable_stop() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd)
		systemctl stop "$svc"
		systemctl disable "$svc"
		;;
	openrc)
		rc-service "$svc" stop 2>/dev/null || true
		rc-update del "$svc" default 2>/dev/null || true
		;;
	esac
}

# Restart a service
# Usage: svc_restart "NetworkManager"
svc_restart() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl restart "$svc" ;;
	openrc) rc-service "$svc" restart ;;
	*) return 1 ;;
	esac
}

# Reload daemon (systemd only)
svc_reload_daemon() {
	case "$INIT_SYSTEM" in
	systemd) systemctl daemon-reload ;;
	openrc) ;; # No-op for OpenRC
	esac
}

# Get service status output
# Usage: svc_status "NetworkManager"
svc_status() {
	local svc="$1"
	case "$INIT_SYSTEM" in
	systemd) systemctl status "$svc" ;;
	openrc) rc-service "$svc" status ;;
	esac
}

# Log info message
log_init_info() {
	echo "[INFO] [$INIT_SYSTEM] $*"
}

# Export functions
export -f run_as_init is_service_active is_service_enabled
export -f svc_start svc_stop svc_enable_start svc_disable_stop svc_restart
export -f svc_reload_daemon svc_status log_init_info
