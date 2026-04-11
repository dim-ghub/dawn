#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Idempotent Declarative Unit State Manager (System & User scopes)
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC
# REQUIRES:     Bash 5.3+, rc-service, rc-update, rc-status, id, flock
# USAGE:        ./dawn_service_manager.sh [--dry-run|--check]
#
# System services use rc-service / rc-update (require root).
# User services use rc-service --user / rc-update --user (no root needed).
#===============================================================================

readonly SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# Only auto-escalate for root-required operations (system services)
# User services do NOT need root — leave that check to the sync functions.
if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3))); then
	printf 'FATAL: This script requires Bash 5.3 or higher.\n' >&2
	exit 1
fi

set -euo pipefail

DRY_RUN=0
while (($#)); do
	case "$1" in
	--dry-run | --check)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		printf 'Usage: %s [--dry-run|--check]\n' "${SCRIPT_PATH##*/}"
		exit 0
		;;
	*)
		printf 'Unknown option: %s\nUsage: %s [--dry-run|--check]\n' "$1" "${SCRIPT_PATH##*/}" >&2
		exit 1
		;;
	esac
done
readonly DRY_RUN

if [[ -t 1 ]]; then
	readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[0;34m' RESET=$'\033[0m'
else
	readonly RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

log_info() { printf '%s[INFO]%s    %s\n' "${BLUE}" "${RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${GREEN}" "${RESET}" "$1"; }
log_warn() { printf '%s[WARN]%s    %s\n' "${YELLOW}" "${RESET}" "$1"; }
log_error() { printf '%s[ERROR]%s   %s\n' "${RED}" "${RESET}" "$1" >&2; }

readonly REQUIRED_BINS=(rc-service rc-update rc-status id flock)
for _bin in "${REQUIRED_BINS[@]}"; do
	if ! command -v "${_bin}" >/dev/null 2>&1; then
		log_error "Required binary '${_bin}' not found in PATH. You need OpenRC installed."
		exit 1
	fi
done
unset _bin

readonly LOCK_FILE='/run/service-manager.lock'

# Try to create lock file, but don't fail if we can't (user services don't need root)
if [[ "${EUID}" -eq 0 ]]; then
	exec 9>"${LOCK_FILE}" || {
		log_error "Cannot create lock file: ${LOCK_FILE}"
		exit 1
	}
	if ! flock -n 9; then
		log_error "Another instance is already running. Exiting."
		exit 1
	fi
fi

# ─── System Services (require root) ──────────────────────────────────────────

declare -A SYSTEM_SERVICES=(
	["NetworkManager"]="true"
	["bluetooth"]="true"
	["cronie"]="true"
	["elogind"]="true"
	["swayosd"]="true"
)

# ─── User Services (no root needed, use --user flag) ─────────────────────────

declare -A USER_SERVICES=(
	["hypridle"]="false"
	["hyprsunset"]="false"
	["network-meter"]="true"
	["dawn-control-center"]="false"
	["dawn-sliders"]="false"
	["update-checker"]="false"
)

OPENRC_INITD_DIR="/home/dim/dawn/user_scripts/openrc/init.d"
OPENRC_USER_INITD_DIR="/home/dim/dawn/user_scripts/openrc/user/init.d"
USER_RC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rc"
USER_INIT_DIR="${USER_RC_DIR}/init.d"

# ─── System Service Functions ─────────────────────────────────────────────────

check_system_service_exists() {
	local svc="$1"
	if rc-service -l 2>/dev/null | grep -q "^${svc}$"; then
		return 0
	fi
	if [[ -x "${OPENRC_INITD_DIR}/${svc}" ]]; then
		return 0
	fi
	return 1
}

get_system_service_status() {
	local svc="$1"
	if rc-status --all 2>/dev/null | grep -q "${svc}.*\[started\]"; then
		echo "started"
	elif rc-status --all 2>/dev/null | grep -q "${svc}"; then
		echo "stopped"
	else
		echo "unknown"
	fi
}

sync_system_service() {
	local svc="$1"
	local desired_state="$2"
	local current_state

	if ! check_system_service_exists "$svc"; then
		log_warn "System service '${svc}' does not exist, skipping."
		return 0
	fi

	current_state=$(get_system_service_status "$svc")

	if [[ "$desired_state" == "true" ]]; then
		if [[ "$current_state" != "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would start: ${svc}"
			else
				log_info "Starting: ${svc}"
				if [[ "${EUID}" -eq 0 ]]; then
					rc-service "$svc" start 2>/dev/null || log_warn "Failed to start ${svc}"
				else
					sudo rc-service "$svc" start 2>/dev/null || log_warn "Failed to start ${svc}"
				fi
			fi
		else
			log_info "Already started: ${svc}"
		fi
		if ! rc-update show 2>/dev/null | grep -q "${svc}"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would add to default runlevel: ${svc}"
			else
				if [[ "${EUID}" -eq 0 ]]; then
					rc-update add "$svc" default 2>/dev/null || log_warn "Failed to enable ${svc}"
				else
					sudo rc-update add "$svc" default 2>/dev/null || log_warn "Failed to enable ${svc}"
				fi
			fi
		fi
	else
		if [[ "$current_state" == "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would stop: ${svc}"
			else
				log_info "Stopping: ${svc}"
				if [[ "${EUID}" -eq 0 ]]; then
					rc-service "$svc" stop 2>/dev/null || log_warn "Failed to stop ${svc}"
				else
					sudo rc-service "$svc" stop 2>/dev/null || log_warn "Failed to stop ${svc}"
				fi
			fi
		fi
		if rc-update show 2>/dev/null | grep -q "${svc}"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would remove from default runlevel: ${svc}"
			else
				if [[ "${EUID}" -eq 0 ]]; then
					rc-update del "$svc" default 2>/dev/null || log_warn "Failed to disable ${svc}"
				else
					sudo rc-update del "$svc" default 2>/dev/null || log_warn "Failed to disable ${svc}"
				fi
			fi
		fi
	fi
}

# ─── User Service Functions ───────────────────────────────────────────────────

check_user_service_exists() {
	local svc="$1"

	# Check user's local init.d first
	if [[ -x "${USER_INIT_DIR}/${svc}" ]]; then
		return 0
	fi

	# Check dotfiles user init.d
	if [[ -x "${OPENRC_USER_INITD_DIR}/${svc}" ]]; then
		return 0
	fi

	# Check system-wide user init.d
	if [[ -x "/etc/user/init.d/${svc}" ]]; then
		return 0
	fi

	# Check rc-service --user listing
	if rc-service --user --list 2>/dev/null | grep -q "^${svc}$"; then
		return 0
	fi

	return 1
}

get_user_service_status() {
	local svc="$1"
	if rc-status --user 2>/dev/null | grep -qE "^\s*${svc}\s+\[started\]"; then
		echo "started"
	elif rc-status --user 2>/dev/null | grep -qE "^\s*${svc}"; then
		echo "stopped"
	else
		echo "unknown"
	fi
}

sync_user_service() {
	local svc="$1"
	local desired_state="$2"
	local current_state src_path

	if ! check_user_service_exists "$svc"; then
		log_warn "User service '${svc}' does not exist, skipping."
		return 0
	fi

	# Install user service script if it exists in dotfiles but not in user's init.d
	if [[ -x "${OPENRC_USER_INITD_DIR}/${svc}" ]] && [[ ! -e "${USER_INIT_DIR}/${svc}" ]]; then
		if [[ "$DRY_RUN" -eq 1 ]]; then
			log_info "[DRY-RUN] Would install user service script: ${svc}"
		else
			mkdir -p "${USER_INIT_DIR}"
			cp "${OPENRC_USER_INITD_DIR}/${svc}" "${USER_INIT_DIR}/${svc}"
			chmod +x "${USER_INIT_DIR}/${svc}"
			log_info "Installed user service script: ${svc}"
		fi
	fi

	current_state=$(get_user_service_status "$svc")

	if [[ "$desired_state" == "true" ]]; then
		if [[ "$current_state" != "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would start (user): ${svc}"
			else
				log_info "Starting (user): ${svc}"
				rc-service "$svc" --user start 2>/dev/null || log_warn "Failed to start (user) ${svc}"
			fi
		else
			log_info "Already started (user): ${svc}"
		fi
		if ! rc-update --user show default 2>/dev/null | grep -q "^[[:space:]]*${svc}[[:space:]]"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would add to user default runlevel: ${svc}"
			else
				rc-update --user add "$svc" default 2>/dev/null || log_warn "Failed to enable (user) ${svc}"
			fi
		fi
	else
		if [[ "$current_state" == "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would stop (user): ${svc}"
			else
				log_info "Stopping (user): ${svc}"
				rc-service "$svc" --user stop 2>/dev/null || log_warn "Failed to stop (user) ${svc}"
			fi
		fi
		if rc-update --user show default 2>/dev/null | grep -q "^[[:space:]]*${svc}[[:space:]]"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would remove from user default runlevel: ${svc}"
			else
				rc-update --user del "$svc" default 2>/dev/null || log_warn "Failed to disable (user) ${svc}"
			fi
		fi
	fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────

log_info "Starting OpenRC service synchronization..."
log_info "Mode: $([[ "$DRY_RUN" -eq 1 ]] && echo "DRY-RUN" || echo "LIVE")"
echo

# Sync system services (requires root)
log_info "=== System Services ==="
if [[ "${EUID}" -ne 0 ]]; then
	log_warn "Not running as root — system service changes will use sudo."
fi
for svc in "${!SYSTEM_SERVICES[@]}"; do
	sync_system_service "$svc" "${SYSTEM_SERVICES[$svc]}"
done

echo

# Sync user services (no root needed)
log_info "=== User Services ==="
for svc in "${!USER_SERVICES[@]}"; do
	sync_user_service "$svc" "${USER_SERVICES[$svc]}"
done

echo
log_success "OpenRC service synchronization complete."

if [[ "$DRY_RUN" -eq 1 ]]; then
	log_info "Run without --dry-run to apply changes."
fi
