#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Interactive TUI to toggle system and user OpenRC services.
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC
# REQUIRES:     Bash 5.3+, rc-service, rc-update, rc-status, rofi
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

# ─── Dependency Check ─────────────────────────────────────────────────────────

check_deps() {
	local missing=()
	for cmd in rofi rc-service rc-status; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done
	if ((${#missing[@]} > 0)); then
		printf '%s[ERROR]%s Missing dependencies: %s\n' "${C_RED}" "${C_RESET}" "${missing[*]}" >&2
		exit 1
	fi
}

# ─── System Services (require root) ──────────────────────────────────────────

get_system_services() {
	local services=()

	for svc in "${OPENRC_INITD_DIR}"/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
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
	rc-update show default 2>/dev/null | grep -q "^[[:space:]]*${svc}[[:space:]]"
}

toggle_system_service() {
	local svc="$1"
	local current_status
	current_status=$(get_system_service_status "$svc")

	if [[ "$current_status" == "started" ]]; then
		if [[ "${EUID}" -eq 0 ]]; then
			rc-service "$svc" stop 2>/dev/null || true
		else
			sudo rc-service "$svc" stop 2>/dev/null || true
		fi
	else
		if [[ "${EUID}" -eq 0 ]]; then
			rc-service "$svc" start 2>/dev/null || true
		else
			sudo rc-service "$svc" start 2>/dev/null || true
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

# ─── User Services (no root needed, --user flag) ─────────────────────────────

get_user_services() {
	local services=()
	local user_init_dir="${XDG_CONFIG_HOME:-$HOME/.config}/rc/init.d"

	for svc in "${OPENRC_USER_INITD_DIR}"/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
	done

	for svc in "${user_init_dir}"/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
	done

	for svc in /etc/user/init.d/*; do
		[[ -x "$svc" ]] && services+=("$(basename "$svc")")
	done

	while IFS= read -r svc; do
		services+=("$svc")
	done < <(rc-service --user --list 2>/dev/null)

	printf '%s\n' "${services[@]}" | sort -u
}

get_user_service_status() {
	local svc="$1"
	if rc-status --user 2>/dev/null | grep -qE "^\s*${svc}\s+\[started\]"; then
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
		rc-service "$svc" --user stop 2>/dev/null || true
	else
		rc-service "$svc" --user start 2>/dev/null || true
	fi
}

enable_user_service() {
	local svc="$1"
	rc-update --user add "$svc" default 2>/dev/null || true
}

disable_user_service() {
	local svc="$1"
	rc-update --user del "$svc" default 2>/dev/null || true
}

# ─── Scope Selection ──────────────────────────────────────────────────────────

choose_scope() {
	local choice
	choice=$(printf '%s\n' "System Services (require sudo)" "User Services (no sudo needed)" |
		rofi -dmenu -p "Service Scope" -mesg "System = rc-service | User = rc-service --user" -i 2>/dev/null) || exit 0

	case "$choice" in
	"System Services"*) echo "system" ;;
	"User Services"*) echo "user" ;;
	*) echo "system" ;;
	esac
}

# ─── System Menu ──────────────────────────────────────────────────────────────

render_system_menu() {
	local services mapfile_cmd
	mapfile -t services < <(get_system_services)

	local menu_items=()
	for svc in "${services[@]}"; do
		local status enabled icon color
		status=$(get_system_service_status "$svc")
		enabled=$(is_system_service_enabled "$svc" && echo "enabled" || echo "disabled")

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
	selected=$(rofi -dmenu -p "System Services" -mesg "Select service to toggle (requires sudo)" -i -a 0 -format "i" "${menu_items[@]}" 2>/dev/null) || return 0

	if [[ -n "$selected" ]]; then
		local svc="${services[$selected]}"
		toggle_system_service "$svc"
		render_system_menu
	fi
}

# ─── User Menu ────────────────────────────────────────────────────────────────

render_user_menu() {
	local services mapfile_cmd
	mapfile -t services < <(get_user_services)

	local menu_items=()
	for svc in "${services[@]}"; do
		local status enabled icon color
		status=$(get_user_service_status "$svc")
		enabled=$(is_user_service_enabled "$svc" && echo "enabled" || echo "disabled")

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
	selected=$(rofi -dmenu -p "User Services" -mesg "Select service to toggle (no sudo needed)" -i -a 0 -format "i" "${menu_items[@]}" 2>/dev/null) || return 0

	if [[ -n "$selected" ]]; then
		local svc="${services[$selected]}"
		toggle_user_service "$svc"
		render_user_menu
	fi
}

# ─── Listing ──────────────────────────────────────────────────────────────────

list_system_services() {
	local services
	mapfile -t services < <(get_system_services)

	printf '%-30s %-10s %-10s\n' "SYSTEM SERVICE" "STATUS" "ENABLED"
	printf '%s\n' "--------------------------------------------------"

	for svc in "${services[@]}"; do
		local status enabled
		status=$(get_system_service_status "$svc")
		enabled=$(is_system_service_enabled "$svc" && echo "yes" || echo "no")
		printf '%-30s %-10s %-10s\n' "$svc" "$status" "$enabled"
	done
}

list_user_services() {
	local services
	mapfile -t services < <(get_user_services)

	printf '%-30s %-10s %-10s\n' "USER SERVICE" "STATUS" "ENABLED"
	printf '%s\n' "--------------------------------------------------"

	for svc in "${services[@]}"; do
		local status enabled
		status=$(get_user_service_status "$svc")
		enabled=$(is_user_service_enabled "$svc" && echo "yes" || echo "no")
		printf '%-30s %-10s %-10s\n' "$svc" "$status" "$enabled"
	done
}

# ─── CLI ───────────────────────────────────────────────────────────────────────

show_help() {
	echo "OpenRC Service Toggle - Dusky"
	echo ""
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  -h, --help       Show this help message"
	echo "  -l, --list       List all services with status"
	echo "  -t, --toggle     Toggle a specific service"
	echo "  -e, --enable     Enable a service"
	echo "  -d, --disable    Disable a service"
	echo "  --user           Use user scope (combine with -t/-e/-d/-l)"
	echo "  --system         Use system scope (default)"
}

main() {
	check_deps

	local scope="system"

	# Parse --user / --system flag
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
		if [[ "$scope" == "user" ]]; then
			list_user_services
		else
			list_system_services
		fi
		;;
	-t | --toggle)
		[[ -z "${2:-}" ]] && {
			echo "Error: Service name required"
			exit 1
		}
		if [[ "$scope" == "user" ]]; then
			toggle_user_service "$2"
		else
			toggle_system_service "$2"
		fi
		;;
	-e | --enable)
		[[ -z "${2:-}" ]] && {
			echo "Error: Service name required"
			exit 1
		}
		if [[ "$scope" == "user" ]]; then
			enable_user_service "$2"
		else
			enable_system_service "$2"
		fi
		;;
	-d | --disable)
		[[ -z "${2:-}" ]] && {
			echo "Error: Service name required"
			exit 1
		}
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
		if [[ "$scope" == "user" ]]; then
			render_user_menu
		else
			render_system_menu
		fi
		;;
	esac
}

main "$@"
