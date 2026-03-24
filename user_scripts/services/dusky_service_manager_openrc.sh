#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Idempotent Declarative Unit State Manager (System & User scopes)
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC
# REQUIRES:     Bash 5.3+, rc-service, rc-update, rc-status, id, flock
# USAGE:        ./dusky_service_manager_openrc.sh [--dry-run|--check]
#===============================================================================

readonly SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

if [[ "${EUID}" -ne 0 ]]; then
	exec sudo "${SCRIPT_PATH}" "$@"
	printf 'FATAL: Failed to escalate privileges via sudo.\n' >&2
	exit 1
fi

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
	readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m' RESET=$'\033[0m'
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
exec 9>"${LOCK_FILE}" || {
	log_error "Cannot create lock file: ${LOCK_FILE}"
	exit 1
}
if ! flock -n 9; then
	log_error "Another instance is already running. Exiting."
	exit 1
fi

declare -A SYSTEM_SERVICES=(
	["NetworkManager"]="true"
	["bluetooth"]="true"
	["cronie"]="true"
	["elogind"]="true"
)

declare -A USER_SERVICES=(
	["dusky-sliders"]="false"
	["network-meter"]="false"
	["update-checker"]="false"
)

OPENRC_INITD_DIR="/home/dim/duskyRC/user_scripts/openrc/init.d"

check_service_exists() {
	local svc="$1"
	if rc-service -l 2>/dev/null | grep -q "^${svc}$"; then
		return 0
	fi
	if [[ -x "${OPENRC_INITD_DIR}/${svc}" ]]; then
		return 0
	fi
	return 1
}

get_service_status() {
	local svc="$1"
	if rc-status --all 2>/dev/null | grep -q "${svc}.*\[started\]"; then
		echo "started"
	elif rc-status --all 2>/dev/null | grep -q "${svc}"; then
		echo "stopped"
	else
		echo "unknown"
	fi
}

sync_service() {
	local svc="$1"
	local desired_state="$2"
	local current_state

	if ! check_service_exists "$svc"; then
		log_warn "Service '${svc}' does not exist, skipping."
		return 0
	fi

	current_state=$(get_service_status "$svc")

	if [[ "$desired_state" == "true" ]]; then
		if [[ "$current_state" != "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would start: ${svc}"
			else
				log_info "Starting: ${svc}"
				rc-service "$svc" start 2>/dev/null || log_warn "Failed to start ${svc}"
			fi
		else
			log_info "Already started: ${svc}"
		fi
		if ! rc-update show 2>/dev/null | grep -q "${svc}"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would add to default runlevel: ${svc}"
			else
				rc-update add "$svc" default 2>/dev/null || log_warn "Failed to enable ${svc}"
			fi
		fi
	else
		if [[ "$current_state" == "started" ]]; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would stop: ${svc}"
			else
				log_info "Stopping: ${svc}"
				rc-service "$svc" stop 2>/dev/null || log_warn "Failed to stop ${svc}"
			fi
		fi
		if rc-update show 2>/dev/null | grep -q "${svc}"; then
			if [[ "$DRY_RUN" -eq 1 ]]; then
				log_info "[DRY-RUN] Would remove from default runlevel: ${svc}"
			else
				rc-update del "$svc" default 2>/dev/null || log_warn "Failed to disable ${svc}"
			fi
		fi
	fi
}

log_info "Starting OpenRC service synchronization..."
log_info "Mode: $([[ "$DRY_RUN" -eq 1 ]] && echo "DRY-RUN" || echo "LIVE")"
echo

log_info "=== System Services ==="
for svc in "${!SYSTEM_SERVICES[@]}"; do
	sync_service "$svc" "${SYSTEM_SERVICES[$svc]}"
done

echo
log_info "=== User Services ==="
for svc in "${!USER_SERVICES[@]}"; do
	sync_service "$svc" "${USER_SERVICES[$svc]}"
done

echo
log_success "OpenRC service synchronization complete."

if [[ "$DRY_RUN" -eq 1 ]]; then
	log_info "Run without --dry-run to apply changes."
fi
