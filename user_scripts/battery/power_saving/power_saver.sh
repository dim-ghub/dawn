#!/usr/bin/env bash
# power_saving/power_saver.sh - MASTER CONDUCTOR
# -----------------------------------------------------------------------------
set -uo pipefail

# --- Pre-flight Checks ---
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
	printf 'Error: Bash 4.4+ required (found: %s)\n' "${BASH_VERSION}" >&2
	exit 1
fi

# --- Environment Setup ---
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly LIB_DIR="${SCRIPT_DIR}/lib"
readonly MODULES_DIR="${SCRIPT_DIR}/modules"

# --- Source Common Library ---
if [[ ! -f "${LIB_DIR}/common.sh" ]]; then
	printf 'Error: %s/common.sh not found.\n' "${LIB_DIR}" >&2
	exit 1
fi
source "${LIB_DIR}/common.sh"

# --- Dependency Check ---
if ! has_cmd gum; then
	printf 'Error: gum is required. Install: sudo pacman -S gum\n' >&2
	exit 1
fi

# --- Helper: Execute Module ---
run_module() {
	local module="$1"
	local desc="${2:-Running ${module##*/}...}"

	if [[ -x "${module}" ]]; then
		spin_exec "${desc}" "${module}"
	elif [[ -f "${module}" ]]; then
		log_warn "Module not executable: ${module##*/}"
		return 1
	else
		log_warn "Module not found: ${module##*/}"
		return 1
	fi
}

# =============================================================================
# INTERACTIVE PROMPTS
# =============================================================================
clear
# Generic Header for Public Use
gum style --border double --margin "1" --padding "1 2" \
	--border-foreground 212 --foreground 212 \
	"SYSTEM POWER SAVER"

# Theme prompt
export POWER_SAVER_THEME="false"
gum style --foreground 245 --italic "Rationale: Light mode allows lower backlight brightness."
if gum confirm "Switch to Light Mode?" --affirmative "Yes" --negative "No"; then
	export POWER_SAVER_THEME="true"
	log_step "Theme switch queued."
fi

# Wi-Fi prompt
export POWER_SAVER_WIFI="false"
if gum confirm "Turn off Wi-Fi?" --affirmative "Yes" --negative "No"; then
	export POWER_SAVER_WIFI="true"
	log_step "Wi-Fi disable queued."
fi

# =============================================================================
# USER MODULES (Non-Root)
# =============================================================================
run_module "${MODULES_DIR}/01_visuals.sh" "Module 01: Visual Effects..."
run_module "${MODULES_DIR}/02_cleanup.sh" "Module 02: Cleanup Processes..."
run_module "${MODULES_DIR}/03_hardware.sh" "Module 03: Hardware Control..."
run_module "${MODULES_DIR}/06_disable_animations.sh" "Module 06: Disabling Animations..."

# =============================================================================
# ROOT MODULES (Sudo Required)
# =============================================================================
echo
gum style --border normal --border-foreground 196 --foreground 196 \
	"PRIVILEGE ESCALATION REQUIRED"

if sudo -v; then
	export SUDO_AUTHENTICATED=true

	# --- SUDO KEEPALIVE ---
	while true; do
		sudo -n true
		sleep 50
		kill -0 "$$" || exit
	done 2>/dev/null &
	SUDO_KEEPALIVE_PID=$!
	trap 'kill ${SUDO_KEEPALIVE_PID} 2>/dev/null' EXIT

	run_module "${MODULES_DIR}/04_root_ops.sh" "Module 04: Root Operations..."

	if [[ -x "${MODULES_DIR}/07_process_terminator.sh" ]]; then
		spin_exec "Module 07: Process Terminator..." \
			sudo "${MODULES_DIR}/07_process_terminator.sh"
	fi
else
	log_error "Authentication failed. Skipping root operations (04, 07)."
fi

# =============================================================================
# DEFERRED MODULES
# =============================================================================
run_module "${MODULES_DIR}/05_theme.sh" "Module 05: Theme Configuration..."

# --- Finish ---
echo
gum style --foreground 46 --bold "✓ DONE: Power Saving Mode Active"
