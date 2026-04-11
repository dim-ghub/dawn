#!/usr/bin/env bash
# Installs/uninstalls the battery_notify OpenRC user service.
# ==============================================================================
# On Artix/OpenRC, battery-notify is a user-level service managed via
# rc-service --user / rc-update --user.
# ==============================================================================

set -euo pipefail

# --- Styling & Colors ---
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly BOLD=$'\033[1m'
readonly NC=$'\033[0m'

log_info() { printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$1"; }
log_success() { printf '%s[OK]%s   %s\n' "${GREEN}" "${NC}" "$1"; }
log_warn() { printf '%s[WARN]%s %s\n' "${YELLOW}" "${NC}" "$1"; }
log_error() { printf '%s[ERROR]%s %s\n' "${RED}" "${NC}" "$1" >&2; }

# --- Configuration ---
readonly SERVICE_NAME="battery-notify"
readonly DOTFILES_INITD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../openrc/user/init.d"
readonly USER_RC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rc"
readonly USER_INIT_DIR="${USER_RC_DIR}/init.d"

# --- Root Guard ---
if [[ "${EUID}" -eq 0 ]]; then
	log_error "Do NOT run this script as root. User services run under your session."
	exit 1
fi

# --- Argument Parsing ---
AUTO_MODE=false
UNINSTALL_MODE=false

for arg in "$@"; do
	case "$arg" in
	--auto | auto) AUTO_MODE=true ;;
	--uninstall | -u) UNINSTALL_MODE=true ;;
	esac
done

# --- Uninstall ---
if [[ "${UNINSTALL_MODE}" == true ]]; then
	log_info "Uninstalling battery-notify user service..."

	if rc-service --user --list 2>/dev/null | grep -q "^${SERVICE_NAME}$"; then
		rc-service "${SERVICE_NAME}" --user stop 2>/dev/null || true
		rc-update --user del "${SERVICE_NAME}" default 2>/dev/null || true
		log_success "Stopped and disabled: ${SERVICE_NAME}"
	fi

	if [[ -f "${USER_INIT_DIR}/${SERVICE_NAME}" ]]; then
		rm -f "${USER_INIT_DIR}/${SERVICE_NAME}"
		log_success "Removed: ${USER_INIT_DIR}/${SERVICE_NAME}"
	fi

	log_success "Battery notify service uninstalled."
	exit 0
fi

# --- Install ---
log_info "Installing battery-notify as OpenRC user service..."

mkdir -p "${USER_INIT_DIR}"

# Install from dotfiles user init.d if available
if [[ -x "${DOTFILES_INITD_DIR}/${SERVICE_NAME}" ]]; then
	cp "${DOTFILES_INITD_DIR}/${SERVICE_NAME}" "${USER_INIT_DIR}/${SERVICE_NAME}"
	chmod +x "${USER_INIT_DIR}/${SERVICE_NAME}"
	log_success "Installed: ${SERVICE_NAME}"
elif [[ -x "/etc/user/init.d/${SERVICE_NAME}" ]]; then
	cp "/etc/user/init.d/${SERVICE_NAME}" "${USER_INIT_DIR}/${SERVICE_NAME}"
	chmod +x "${USER_INIT_DIR}/${SERVICE_NAME}"
	log_success "Installed from system: ${SERVICE_NAME}"
else
	log_error "battery-notify service script not found."
	log_error "Checked: ${DOTFILES_INITD_DIR}/${SERVICE_NAME}"
	log_error "Checked: /etc/user/init.d/${SERVICE_NAME}"
	exit 1
fi

# Enable
if rc-update --user add "${SERVICE_NAME}" default 2>/dev/null; then
	rc-service "${SERVICE_NAME}" --user start 2>/dev/null || true
	log_success "Enabled & started (user): ${SERVICE_NAME}"
else
	log_error "Failed to enable (user): ${SERVICE_NAME}"
fi

printf '\n'
log_info "Done. Manage via: rc-service --user battery-notify start|stop"
log_info "                  rc-update --user add battery-notify default"
