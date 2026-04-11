#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Interactive TUI to toggle user and system OpenRC services.
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC
# REQUIRES:     Bash 5.3+, rc-service, rc-update, rc-status, rofi, gum
#===============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENRC_INITD_DIR="${SCRIPT_DIR}/../openrc/init.d"
OPENRC_USER_INITD_DIR="${SCRIPT_DIR}/../openrc/user/init.d"

C_RESET=$'\033[0m'
C_RED=$'\033[0;31m'
C_GREEN=$'\033[0;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[0;34m'
C_CYAN=$'\033[0;36m'

# ─── System Services ──────────────────────────────────────────────────────────

get_system_services() {
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

get_system_service_status() {
	local svc="$1"
	if rc-status --all 2>/dev/null | grep -qE "^\s*${svc}\s+\["; then
		echo "started"
	else
		echo "stopped"
	fi
}

is_system_service_enabled() {
	local svc="$1"
	rc-update show 2>/dev/null | grep -q "${svc}"
}

toggle_system_service() {
	local svc="$1"
	local current_status
	local action

	current_status=$(get_system_service_status "$svc")

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

enable_system_service() {
	local svc="$1"
	if [[ "${EUID}" -eq 0 ]]; then
		rc-update add "$svc" default 2>/dev/null
	else
		sudo rc-update add "$svc" default 2>/dev/null
	fi
}

disable_system_service() {
	local svc="$1"
	if [[ "${EUID}" -eq 0 ]]; then
		rc-update del "$svc" default 2>/dev/null
	else
		sudo rc-update del "$svc" default 2>/dev/null
	fi
}

# ─── User Services ───────────────────────────────────────────────────────────

get_user_services() {
	local services=()
	local user_init_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rc/init.d"
	local sys_user_init_dir="/etc/user/init.d"

	for svc in "${OPENRC_USER_INITD_DIR}"/*; do
		if [[ -x "$svc" ]]; then
			services+=("$(basename "$svc")")
		fi
	done

	for svc in "${user_init_dir}"/*; do
		if [[ -x "$svc" ]]; then
			services+=("$(basename "$svc")")
		fi
	done

	for svc in "${sys_user_init_dir}"/*; do
		if [[ -x "$svc" ]]; then
			services+=("$(basename "$svc")")
		fi
	done

	rc-service --user --list 2>/dev/null | while read -r svc; do
		services+=("$svc")
	done

	printf '%s\n' "${services[@]}" | sort -u
}

get_user_service_status() {
	local svc="$1"
	if rc-status --user 2>/dev/null | grep -qE "^\s*${svc}\s+\["; then
		echo "started"
	else
		echo "stopped"
	fi
}

is_user_service_enabled() {
	local svc="$1"
	rc-update --user show default 2>/dev/null | grep -q "^[[:space:]]*${svc}[[:space:]]"
}

toggle_user_service() {
	local svc="$1"
	local current_status

	current_status=$(get_user_service_status "$svc")

	if [[ "$current_status" == "started" ]]; then
		rc-service "$svc" --user stop 2>/dev/null
	else
		rc-service "$svc" --user start 2>/dev/null
	fi
}

enable_user_service() {
	local svc="$1"
	rc-update --user add "$svc" default 2>/dev/null
}

disable_user_service() {
	local svc="$1"
	rc-update --user del "$svc" default 2>/dev/null
}

# ─── Rendering ────────────────────────────────────────────────────────────────

check_deps() {
	local missing=()
	for cmd in rofi rc-service rc-status gum; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done
	if ((${#missing[@]} > 0)); then
		printf '%s[ERROR]%s Missing dependencies: %s\n' "${C_RED}" "${C_RESET}" "${missing[*]}" >&2
		exit 1
	fi
}

choose_scope() {
	local choice
	choice=$(printf '%s\n' "System Services" "User Services" |
		rofi -dmenu -p "Service Scope" -mesg "System services require sudo · User services run under your session" -i 2>/dev/null) || exit 0

	case "$choice" in
	"System Services") echo "system" ;;
	"User Services") echo "user" ;;
	*) echo "system" ;;
	esac
}

render_menu() {
	local scope="$1"
	local services mapfile_cmd

	if [[ "$scope" == "system" ]]; then
		mapfile -t services < <(get_system_services)
	else
		mapfile -t services < <(get_user_services)
	fi

	local menu_items=()
	for svc in "${services[@]}"; do
		local status enabled icon color
		if [[ "$scope" == "system" ]]; then
			status=$(get_system_service_status "$svc")
			enabled=$(is_system_service_enabled "$svc" && echo "enabled" || echo "disabled")
		else
			status=$(get_user_service_status "$svc")
			enabled=$(is_user_service_enabled "$svc" && echo "enabled" || echo "disabled")
		fi

		if [[ "$status" == "started" ]]; then
			icon="󰤴"
			color="${C_GREEN}"
		else
			icon="󰤵"
			color="${C_RED}"
		fi

		menu_items+=("$svc" "${color}${icon}${C_RESET} ${svc} [${enabled}]")
	done

	local selected
	selected=$(rofi -dmenu -p "OpenRC ${scope^} Services" -mesg "Select service to toggle" -i -a 0 -format "i" "${menu_items[@]}" 2>/dev/null) || return 0

	if [[ -n "$selected" ]]; then
		local svc="${services[$selected]}"
		if [[ "$scope" == "system" ]]; then
			toggle_system_service "$svc"
		else
			toggle_user_service "$svc"
		fi
		# Re-render the same scope
		render_menu "$scope"
	fi
}

# ─── CLI ──────────────────────────────────────────────────────────────────────

show_help() {
	echo "OpenRC Service Toggle - Dusky"
	echo ""
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  -h, --help       Show this help message"
	echo "  -l, --list       List all services with status"
	echo "  -t, --toggle     Toggle a specific service (system scope)"
	echo "  -e, --enable     Enable a service (system scope)"
	echo "  -d, --disable    Disable a service (system scope)"
	echo "  --user           Use user scope (combine with -t/-e/-d/-l)"
	echo "  --system         Use system scope (default)"
}

list_services() {
	local scope="${1:-system}"

	if [[ "$scope" == "user" ]]; then
		mapfile -t services < <(get_user_services)
		printf '%-30s %-10s %-10s\n' "USER SERVICE" "STATUS" "ENABLED"
		printf '%s\n' "----------------------------------------"
		for svc in "${services[@]}"; do
			local status enabled
			status=$(get_user_service_status "$svc")
			enabled=$(is_user_service_enabled "$svc" && echo "yes" || echo "no")
			printf '%-30s %-10s %-10s\n' "$svc" "$status" "$enabled"
		done
	else
		mapfile -t services < <(get_system_services)
		printf '%-30s %-10s %-10s\n' "SYSTEM SERVICE" "STATUS" "ENABLED"
		printf '%s\n' "----------------------------------------"
		for svc in "${services[@]}"; do
			local status enabled
			status=$(get_system_service_status "$svc")
			enabled=$(is_system_service_enabled "$svc" && echo "yes" || echo "no")
			printf '%-30s %-10s %-10s\n' "$svc" "$status" "$enabled"
		done
	fi
}

main() {
	check_deps

	local scope="system"
	local action=""

	# Parse --user / --system flag first
	for arg in "$@"; do
		case "$arg" in
		--user) scope="user" ;;
		--system) scope="system" ;;
		esac
	done

	case "${1:-}" in
	-h | --help)
		show_help
		;;
	-l | --list)
		list_services "$scope"
		;;
	-t | --toggle)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		if [[ "$scope" == "user" ]]; then
			toggle_user_service "$2"
		else
			toggle_system_service "$2"
		fi
		;;
	-e | --enable)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		if [[ "$scope" == "user" ]]; then
			enable_user_service "$2"
		else
			enable_system_service "$2"
		fi
		;;
	-d | --disable)
		if [[ -z "${2:-}" ]]; then
			echo "Error: Service name required"
			exit 1
		fi
		if [[ "$scope" == "user" ]]; then
			disable_user_service "$2"
		else
			disable_system_service "$2"
		fi
		;;
	--user | --system)
		# Already handled above, skip
		;;
	*)
		# Interactive: ask which scope, then show menu
		scope=$(choose_scope)
		render_menu "$scope"
		;;
	esac
}

main "$@"
