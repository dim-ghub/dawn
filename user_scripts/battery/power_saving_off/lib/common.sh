#!/usr/bin/env bash
# power_saving_off/lib/common.sh
# -----------------------------------------------------------------------------
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
readonly _COMMON_SH_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly RESTORE_BRIGHTNESS="50%"
readonly RESTORE_VOLUME_CAP=100

# Dynamic path resolution
readonly POWER_SAVING_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"

# Script paths
readonly ASUS_PROFILE_SCRIPT="${POWER_SAVING_ROOT}/modules/asus_tuf_profile/performance_profile.sh"
readonly BLUR_SCRIPT="${HOME}/user_scripts/hypr/hypr_blur_opacity_shadow_toggle.sh"
readonly THEME_SCRIPT="${HOME}/user_scripts/theme_matugen/matugen_config.sh"

# =============================================================================
# HELPERS
# =============================================================================
has_cmd() { command -v "$1" &>/dev/null; }

# =============================================================================
# LOGGING (Gum / Fallback)
# =============================================================================
if has_cmd gum; then
	log_step() { gum style --foreground 46 ":: $*"; }
	log_warn() { gum style --foreground 208 "⚠ $*"; }
	log_error() { gum style --foreground 196 "✗ $*" >&2; }
else
	log_step() { printf '\033[1;32m:: %s\033[0m\n' "$*"; }
	log_warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
	log_error() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }
fi

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
	local desc="${2:-Running script...}"
	shift 2

	if [[ ! -x "${script_path}" ]]; then
		log_warn "Script missing or not executable: ${script_path}"
		return 1
	fi

	spin_exec "${desc}" "${script_path}" "$@"
}
