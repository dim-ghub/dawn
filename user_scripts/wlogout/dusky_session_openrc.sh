#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Session management for Hyprland on OpenRC (Artix Linux)
# PLATFORM:     Artix Linux · Wayland / Hyprland · OpenRC/elogind
# REQUIRES:     Bash 5.3+, loginctl (from elogind) or dbus-send
#===============================================================================

set -euo pipefail

ACTION="${1:-poweroff}"

case "$ACTION" in
poweroff | reboot | soft-reboot | logout | suspend | hibernate) ;;
*)
	echo "Error: Invalid action '$ACTION'."
	echo "Usage: sys-session [poweroff|reboot|soft-reboot|logout|suspend|hibernate]"
	exit 1
	;;
esac

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
if [[ -d "$STATE_DIR" ]]; then
	shopt -s nullglob
	rm -f -- "$STATE_DIR"/re*-required || :
	shopt -u nullglob
fi

hyprctl dispatch workspace 1 >/dev/null 2>&1 || :

close_all_windows() {
	declare -A skip_pids=()
	curr_pid=$$

	while [[ -r "/proc/$curr_pid/status" ]]; do
		skip_pids["$curr_pid"]=1
		ppid=""

		while IFS=$': \t' read -r key value _; do
			if [[ "$key" == "PPid" ]]; then
				ppid="$value"
				break
			fi
		done <"/proc/$curr_pid/status"

		[[ "$ppid" =~ ^[0-9]+$ ]] && ((ppid > 1)) || break
		curr_pid="$ppid"
	done

	local batch_cmds=""

	if clients_json=$(hyprctl clients -j 2>/dev/null); then
		if client_rows=$(jq -r '.[] | "\(.pid)\t\(.address)"' <<<"$clients_json" 2>/dev/null); then
			if [[ -n "$client_rows" ]]; then
				while IFS=$'\t' read -r c_pid addr; do
					[[ -n "${skip_pids["$c_pid"]:-}" ]] && continue
					batch_cmds+="dispatch closewindow address:${addr}; "
				done <<<"$client_rows"
			fi
		fi
	fi

	if [[ -n "$batch_cmds" ]]; then
		hyprctl --batch "$batch_cmds" >/dev/null 2>&1 || :
		sleep 1
	fi
}

do_poweroff() {
	close_all_windows

	if command -v loginctl >/dev/null 2>&1; then
		exec loginctl power-off --no-wall
	elif command -v openrc-shutdown >/dev/null 2>&1; then
		exec openrc-shutdown -p now
	elif command -v systemctl >/dev/null 2>&1; then
		exec systemctl poweroff --no-wall
	else
		exec shutdown -P now
	fi
}

do_reboot() {
	close_all_windows

	if command -v loginctl >/dev/null 2>&1; then
		exec loginctl reboot --no-wall
	elif command -v openrc-shutdown >/dev/null 2>&1; then
		exec openrc-shutdown -r now
	elif command -v systemctl >/dev/null 2>&1; then
		exec systemctl reboot --no-wall
	else
		exec shutdown -r now
	fi
}

do_soft_reboot() {
	close_all_windows

	if command -v openrc-shutdown >/dev/null 2>&1; then
		exec openrc-shutdown -r now
	elif command -v systemctl >/dev/null 2>&1; then
		exec systemctl soft-reboot --no-wall
	else
		exec shutdown -r now
	fi
}

do_suspend() {
	if command -v loginctl >/dev/null 2>&1; then
		exec loginctl suspend
	elif command -v systemctl >/dev/null 2>&1; then
		exec systemctl suspend
	else
		echo "Error: No suspend mechanism available (install elogind)"
		exit 1
	fi
}

do_hibernate() {
	if command -v loginctl >/dev/null 2>&1; then
		exec loginctl hibernate
	elif command -v systemctl >/dev/null 2>&1; then
		exec systemctl hibernate
	else
		echo "Error: No hibernate mechanism available (install elogind)"
		exit 1
	fi
}

do_logout() {
	close_all_windows
	exec hyprctl dispatch exit
}

case "$ACTION" in
poweroff) do_poweroff ;;
reboot) do_reboot ;;
soft-reboot) do_soft_reboot ;;
suspend) do_suspend ;;
hibernate) do_hibernate ;;
logout) do_logout ;;
esac
