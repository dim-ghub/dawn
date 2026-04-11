#!/usr/bin/env bash
# Enables user services for AUR packages (OpenRC user-level services)
# ==============================================================================
# Description: Enables USER-level OpenRC services using rc-service --user
#              and rc-update --user. No root required.
# Standards:   Bash 5+, set -euo pipefail, STRICTLY NO SUDO
# ==============================================================================

set -euo pipefail

# --- 1. Configuration (User Editable) ---
readonly TARGET_USER_SERVICES=(
	"hypridle"
	"hyprsunset"
	"swayosd"
	"waybar"
	"pipewire"
	"wireplumber"
)

# Dotfiles user init.d directory (source for installing)
DOTFILES_USER_INITD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../openrc/user/init.d"
USER_RC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rc"
USER_INIT_DIR="${USER_RC_DIR}/init.d"

# --- 2. Formatting & Visuals ---
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_RED=$'\033[0;31m'
readonly C_BLUE=$'\033[0;34m'

log_info() { printf '%s[INFO]%s    %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%s[SKIP]%s    %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
log_error() { printf '%s[FAIL]%s    %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }

# --- 3. Root Guard ---
if [[ "${EUID}" -eq 0 ]]; then
	log_error "Do NOT run this script as root/sudo."
	log_error "User services run under your session. Run as your normal user."
	exit 1
fi

# --- 4. Pre-flight Check ---
if ! command -v rc-service >/dev/null 2>&1; then
	log_error "rc-service not found. This script requires OpenRC."
	exit 1
fi

# --- 5. Install user init scripts from dotfiles ---
log_info "Installing user service scripts to ${USER_INIT_DIR}..."
mkdir -p "${USER_INIT_DIR}"

for svc in "${TARGET_USER_SERVICES[@]}"; do
	if [[ -x "${DOTFILES_USER_INITD_DIR}/${svc}" ]]; then
		cp "${DOTFILES_USER_INITD_DIR}/${svc}" "${USER_INIT_DIR}/${svc}"
		chmod +x "${USER_INIT_DIR}/${svc}"
		log_info "Installed: ${svc}"
	fi
done

# --- 6. Enable user services ---
printf '\n%sStarting User Service Initialization (OpenRC --user)...%s\n' "${C_BOLD}" "${C_RESET}"
printf '%s-------------------------------------------------------%s\n' "${C_BOLD}" "${C_RESET}"

for svc in "${TARGET_USER_SERVICES[@]}"; do
	# Check if service is available (from dotfiles, user init.d, or system user init.d)
	if [[ -x "${USER_INIT_DIR}/${svc}" ]] ||
		[[ -x "${DOTFILES_USER_INITD_DIR}/${svc}" ]] ||
		[[ -x "/etc/user/init.d/${svc}" ]] ||
		rc-service --user --list 2>/dev/null | grep -q "^${svc}$"; then
		if rc-update --user add "$svc" default 2>/dev/null; then
			rc-service "$svc" --user start 2>/dev/null || true
			log_success "Enabled & Started (user): ${C_BOLD}${svc}${C_RESET}"
		else
			log_error "Could not enable (user): ${svc}"
		fi
	else
		log_warn "Service not found: ${C_BOLD}${svc}${C_RESET}"
	fi
done

printf '%s-------------------------------------------------------%s\n' "${C_BOLD}" "${C_RESET}"
log_info "User services updated."
printf '\n'
