#!/usr/bin/env bash
# power_saving/lib/common.sh - Shared configuration and helpers
# -----------------------------------------------------------------------------
# Guard against multiple sourcing (C-style header protection)
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
readonly _COMMON_SH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly BRIGHTNESS_LEVEL="1%"
readonly VOLUME_CAP=50

# Dynamic path resolution (Points to power_saving/ directory)
readonly POWER_SAVING_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

# Script paths (Self-contained resolution)
readonly ASUS_PROFILE_SCRIPT="${POWER_SAVING_ROOT}/modules/asus_tuf_profile/quiet_profile_and_keyboard_light.sh"
readonly BLUR_SCRIPT="${HOME}/user_scripts/hypr/hypr_blur_opacity_shadow_toggle.sh"
readonly THEME_SCRIPT="${HOME}/user_scripts/theme_matugen/matugen_config.sh"

# =============================================================================
# CORE HELPERS
# =============================================================================
has_cmd() { command -v "$1" &>/dev/null; }

is_numeric() {
	[[ -n "${1:-}" && "$1" =~ ^[0-9]+$ ]]
}

# =============================================================================
# LOGGING (with gum fallback for safety)
# =============================================================================
if has_cmd gum; then
	log_step() { gum style --foreground 212 ":: $*"; }
	log_warn() { gum style --foreground 208 "⚠ $*"; }
	log_error() { gum style --foreground 196 "✗ $*" >&2; }
else
	log_step() { printf '\033[1;35m:: %s\033[0m\n' "$*"; }
	log_warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
	log_error() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }
fi

# =============================================================================
# EXECUTION WRAPPERS
# =============================================================================
run_quiet() { "$@" &>/dev/null || true; }

spin_exec() {
	local title="$1"
	shift
	if has_cmd gum; then
		gum spin --spinner dot --title "$title" -- "$@"
	else
		printf '%s\n' "$title"
		"$@"
	fi
}

run_external_script() {
	local script_path="$1"
	local description="${2:-Running script...}"
	shift 2
	local -a extra_args=("$@")

	if [[ ! -f "${script_path}" ]]; then
		log_warn "Script not found: ${script_path}"
		return 1
	fi

	if [[ ! -x "${script_path}" ]]; then
		log_warn "Script not executable: ${script_path}"
		return 1
	fi

	spin_exec "${description}" "${script_path}" "${extra_args[@]}"
}
