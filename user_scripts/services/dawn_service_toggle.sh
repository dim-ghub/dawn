#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Interactive TUI to toggle user and system OpenRC services.
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC
# REQUIRES:     Bash 5.3+, rc-service, rc-update, rc-status, rofi, gum
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENRC_INITD_DIR="${SCRIPT_DIR}/../openrc/init.d"

C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[0;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'

check_deps() {
	local missing=()
	for cmd in rogi rc-service rc-status gum; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done
	if ((${#missing[@]} > 0)); then
		printf '%s[ERROR]%s Missing dependencies: %s\n' "${C_RED}" "${C_RESET}" "${missing[*]}" >&2
		exit 1
	fi
}

get_all_services() {
	local services=()

	for svc in "${OPENRC_INITD_DIR}"/*; do
		if [[ -x "$svc" ]]; then
			services+=("$(basename "$svc")")
		fi
	done

	for svc in $(rc-service -l 2>/dev/null); do
		services+=("$svc")
	done

	printf '%s\n' "${services[@]}" | sort -u
}

get_service_status() {
	local svc="$1"
	if rc-status --all 2>/dev/null | grep -qE "^\s*${svc}\s+\["; then
		echo "started"
	else
		echo "stopped"
	fi
}

is_service_enabled() {
	local svc="$1"
	rc-update show 2>/dev/null | grep -q "${svc}" && return 0 || return 1
}

toggle_service() {
	local svc="$1"
	local current_status
	local action

	current_status=$(get_service_status "$svc")

	if [[ "$current_status" == "started" ]]; then
		if [[ "${EUID}" -eq 0 ]]; then
			rc-service "$svc" stop 2>/dev/null
		else
			sudo rc-service "$svc" stop 2>/dev/null
		fi
	else
		if [[ "${EUID}" -eq 0 ]]; then
			rc-service "$svc" start 2>/dev/null
		else
			sudo rc-service "$svc" start 2>/dev/null
		fi
	fi
}

enable_service() {
	local svc="$1"
	if [[ "${EUID}" -eq 0 ]]; then
		rc-update add "$svc" default 2>/dev/null
	else
		sudo rc-update add "$svc" default 2>/dev/null
	fi
}

disable_service() {
	local svc="$1"
	if [[ "${EUID}" -eq 0 ]]; then
		rc-update del "$svc" default 2>/dev/null
	else
		sudo rc-update del "$svc" default 2>/dev/null
	fi
}

render_menu() {
	local services
	mapfile -t services < <(get_all_services)

	local menu_items=()
	for svc in "${services[@]}"; do
		local status enabled
		status=$(get_service_status "$svc")
		enabled=$(is_service_enabled "$svc" && echo "enabled" || echo "disabled")

		local icon color
		if [[ "$status" == "started" ]]; then
			icon="󰤴"
			color="${C_GREEN}"
		else
			icon="󰤵"
			color="${C_RED}"
		fi

		if [[ "$enabled" == "enabled" ]]; then
			menu_items+=("$svc" "${color}${icon}${C_RESET} ${svc} [${enabled}]")
		else
			menu_items+=("$svc" "${color}${icon}${C_RESET} ${svc} [${enabled}]")
		fi
	done

	local selected
	selected=$(rofi -dmenu -p "OpenRC Services" -mesg "Select service to toggle" -i -a 0 -format "i" "${menu_items[@]}" 2>/dev/null) || exit 0

	if [[ -n "$selected" ]]; then
		local svc="${services[$selected]}"
		toggle_service "$svc"
		render_menu
	fi
}

show_help() {
	echo "OpenRC Service Toggle - Dusky"
	echo ""
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  -h, --help     Show this help message"
	echo "  -l, --list     List all services with status"
	echo "  -t, --toggle   Toggle a specific service"
	echo "  -e, --enable   Enable a service"
	echo "  -d, --disable  Disable a service"
}

list_services() {
	local services
	mapfile -t services < <(get_all_services)

	printf '%-30s %-10s %-10s\n' "SERVICE" "STATUS" "ENABLED"
	printf '%s\n' "----------------------------------------"

	for svc in "${services[@]}"; do
		local status enabled
		status=$(get_service_status "$svc")
		enabled=$(is_service_enabled "$svc" && echo "yes" || echo "no")

		printf '%-30s %-10s %-10s\n' "$svc" "$status" "$enabled"
	done
}

main() {
	check_deps

	case "${1:-}" in
	-h | --help)
		show_help
		;;
	-l | --list)
		list_services
		;;
	-t | --toggle)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		toggle_service "$2"
		;;
	-e | --enable)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		enable_service "$2"
		;;
	-d | --disable)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		disable_service "$2"
		;;
	*)
		render_menu
		;;
	esac
}

main "$@"
