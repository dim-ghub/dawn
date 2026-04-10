#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Power Master - OpenRC Version
# -----------------------------------------------------------------------------
# Target: OpenRC/elogind / login.conf
#
# Ported from systemd-logind to OpenRC/elogind for Artix Linux
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

C_RESET=$'\033[0m'
C_CYAN=$'\033[1;36m'
C_GREEN=$'\033[1;32m'
C_MAGENTA=$'\033[1;35m'
C_RED=$'\033[1;31m'
C_YELLOW=$'\033[1;33m'
C_WHITE=$'\033[1;37m'
C_GREY=$'\033[1;30m'
C_INVERSE=$'\033[7m'
CLR_EOL=$'\033[K'
CLR_EOS=$'\033[J'
CLR_SCREEN=$'\033[2J'
CURSOR_HOME=$'\033[H'
CURSOR_HIDE=$'\033[?25l'
CURSOR_SHOW=$'\033[?25h'
MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

declare -r ESC_READ_TIMEOUT=0.10
declare -r UNSET_MARKER='«unset»'

if [[ ${EUID} -ne 0 ]]; then
	printf '%s[PRIVILEGE ESCALATION]%s This script requires root to edit login.conf.\n' \
		"${C_YELLOW}" "${C_RESET}"
	exec sudo -- "$0" "$@"
fi

declare -r CONFIG_FILE="/etc/elogind/login.conf"
declare -r APP_TITLE="Dusky Power Manager (OpenRC)"
declare -r APP_VERSION="v3.0.0-openrc"

declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$((HEADER_ROWS + 1))

declare -ra TABS=("Power Keys" "Lid & Idle" "Session")

declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"

get_elogind_config() {
	if [[ -f "$CONFIG_FILE" ]]; then
		grep -v '^#' "$CONFIG_FILE" | grep -v '^$' | head -20
	else
		echo "KillUserProcesses=no"
		echo "KillOnlyUsers="
		echo "KillExcludeUsers=root"
		echo "InhibitDelayMaxSec=5"
		echo "UserStopDelaySec=10"
	fi
}

save_elogind_config() {
	local key="$1"
	local value="$2"

	if [[ ! -f "$CONFIG_FILE" ]]; then
		cat >"$CONFIG_FILE" <<EOF
# /etc/elogind/login.conf
# Configured by Dusky Power Manager
#
# See man login.conf for more information

KillUserProcesses=no
KillOnlyUsers=
KillExcludeUsers=root
InhibitDelayMaxSec=5
UserStopDelaySec=10
EOF
	fi

	if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
	else
		echo "${key}=${value}" >>"$CONFIG_FILE"
	fi

	pkill -HUP -x elogind 2>/dev/null || true
}

get_value() {
	local key="$1"
	local current
	current=$(get_elogind_config | grep "^${key}=" | cut -d= -f2-)
	echo "${current:-no}"
}

show_tab() {
	local tab_idx="$1"
	printf '\n%s' "${C_CYAN}${TABS[$tab_idx]}${C_RESET}"
}

render() {
	local -i current_tab="$1"
	local -i selected_idx="$2"

	printf '%s%s' "${CLR_SCREEN}" "${CURSOR_HOME}"
	printf '%s%s%s\n' "${C_INVERSE}${C_WHITE}  ${APP_TITLE} ${APP_VERSION}  ${C_RESET}" "${C_GREY}"
	printf '%s\n' "${H_LINE}"

	local -i t=0
	for tab in "${TABS[@]}"; do
		if ((t == current_tab)); then
			printf '%s[%s]%s  ' "${C_GREEN}" "${tab}" "${C_RESET}"
		else
			printf '%s %s %s  ' "${C_GREY}" "${tab}" "${C_RESET}"
		fi
		((t++))
	done
	printf '\n%s\n' "${H_LINE}"

	case "$current_tab" in
	0) render_power_keys ;;
	1) render_lid_idle ;;
	2) render_session ;;
	esac
}

render_power_keys() {
	local handle_power="$(get_value HandlePowerKey)"
	local handle_suspend="$(get_value HandleSuspendKey)"
	local handle_hibernate="$(get_value HandleHibernateKey)"

	printf '\n'
	printf '%-20s %s\n' "${C_CYAN}Power Key:${C_RESET}" "${handle_power:-ignore}"
	printf '%-20s %s\n' "${C_CYAN}Suspend Key:${C_RESET}" "${handle_suspend:-ignore}"
	printf '%-20s %s\n' "${C_CYAN}Hibernate Key:${C_RESET}" "${handle_hibernate:-ignore}"
	printf '\n%s\n' "${C_GREY}Values: ignore, poweroff, reboot, suspend, hibernate, lock${C_RESET}"
}

render_lid() {
	local handle_lid="$(get_value HandleLidSwitch)"
	local handle_lid_docked="$(get_value HandleLidSwitchDocked)"

	printf '\n'
	printf '%-20s %s\n' "${C_CYAN}Lid Switch:${C_RESET}" "${handle_lid:-suspend}"
	printf '%-20s %s\n' "${C_CYAN}Lid Docked:${C_RESET}" "${handle_lid_docked:-ignore}"
}

render_session() {
	local kill_user="$(get_value KillUserProcesses)"

	printf '\n'
	printf '%-20s %s\n' "${C_CYAN}Kill User Processes:${C_RESET}" "${kill_user:-no}"
	printf '\n%s\n' "${C_GREY}Set to yes to kill processes on logout${C_RESET}"
}

handle_input() {
	local -i tab="$1"
	local -i idx="$2"
	local key="$3"

	case "$key" in
	$'\x1b')
		return 255
		;;
	$'\t')
		((tab = (tab + 1) % ${#TABS[@]}))
		;;
	$'\n')
		return 0
		;;
	$'\x7f')
		return 254
		;;
	esac

	echo "$tab:$idx"
}

main() {
	local -i cur_tab=0
	local -i cur_idx=0

	printf '%s' "${CURSOR_HIDE}"

	render "$cur_tab" "$cur_idx"

	while true; do
		IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" key || continue

		local result
		result=$(handle_input "$cur_tab" "$cur_idx" "$key")

		if [[ "$result" == $'\x1b' ]] || [[ "$result" == "255" ]]; then
			break
		fi

		if [[ "$result" == "254" ]]; then
			((cur_idx = (cur_idx - 1 + 3) % 3))
		fi

		render "$cur_tab" "$cur_idx"
	done

	printf '%s' "${CURSOR_SHOW}"
	printf '\n\n%s\n' "${C_GREEN}Done.${C_RESET}"
}

main "$@"
