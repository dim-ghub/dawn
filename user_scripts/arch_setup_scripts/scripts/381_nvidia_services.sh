#!/usr/bin/env bash
# Enables systemd system services for packages
# ==============================================================================
# Arch Linux System Service Initializer
# Context: Hyprland / UWSM / Systemd
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Strict Environment & Error Handling
# ------------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# --- Init System ---
readonly INIT_SYSTEM="openrc"

# Trap for clean exit (no temp files to clean, but good practice)
trap 'exit_code=$?; [[ $exit_code -ne 0 ]] && printf "\n[!] Script failed with code %d\n" "$exit_code"' EXIT

# ------------------------------------------------------------------------------
# 2. Configuration (User Editable)
# ------------------------------------------------------------------------------
# Add or remove system services here.
readonly TARGET_SERVICES=(
	# --- NVIDIA Power Management (Safe to include; skipped if missing) ---
	"nvidia-suspend.service"
	"nvidia-hibernate.service"
	"nvidia-resume.service"

	# Optional: Dynamic Boost for modern Turing+ Laptops
	"nvidia-powerd.service"
)

# ------------------------------------------------------------------------------
# 3. Privilege Escalation (Auto-Sudo)
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
	printf "[\033[0;33mINFO\033[0m] Escalating permissions to root...\n"
	exec sudo "$0" "$@"
fi

# ------------------------------------------------------------------------------
# 4. Helpers (Logging & Logic)
# ------------------------------------------------------------------------------
log_info() { printf "[\033[0;34mINFO\033[0m] %s\n" "$1"; }
log_success() { printf "[\033[0;32m OK \033[0m] %s\n" "$1"; }
log_warn() { printf "[\033[0;33mWARN\033[0m] %s\n" "$1"; }
log_err() { printf "[\033[0;31mERR \033[0m] %s\n" "$1"; }

enable_service() {
	local service="$1"
	local svc_name="${service%.service}"

	# OpenRC
	if rc-service -l 2>/dev/null | grep -q "^${svc_name}$"; then
		if rc-update show default 2>/dev/null | grep -q "$svc_name"; then
			log_info "$svc_name is already enabled."
		else
			if rc-update add "$svc_name" default 2>/dev/null; then
				rc-service "$svc_name" start 2>/dev/null || true
				log_success "Enabled & Started: $svc_name"
			else
				log_err "Failed to enable: $svc_name"
			fi
		fi
	else
		log_warn "Skipping: $svc_name (Package not installed / Service not found)"
	fi
}

# ------------------------------------------------------------------------------
# 5. Main Execution
# ------------------------------------------------------------------------------
main() {
	printf "\n--- Arch System Service Optimization ---\n"

	for service in "${TARGET_SERVICES[@]}"; do
		enable_service "$service"
	done

	# Hyprland Note:
	# System services handle hardware/network.
	# User-session services should be handled by exec-once in autostart.conf or systemd --user.

	printf "\n--- Operation Complete ---\n"
}

main
