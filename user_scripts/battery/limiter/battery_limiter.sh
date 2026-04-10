#!/usr/bin/env bash
# ==============================================================================
# Target: Linux (systemd/OpenRC) / Hyprland (Wayland)
# Description: Ultra-reliable, stateless battery charge threshold optimizer.
# Validation: Tolerates write-only kernel drivers that return EOF on read.
# Integration: Safely bridges root execution to update unprivileged Waybar state.
# ==============================================================================

set -euo pipefail

# --- Detect Init System ---
detect_init() {
	if command -v rc-service >/dev/null 2>&1; then
		echo "openrc"
	else
		echo "unknown"
	fi
}
readonly INIT_SYSTEM=$(detect_init)

# ------------------------------------------------------------------------------
# Constants & Environment Setup
# ------------------------------------------------------------------------------
readonly SERVICE_NAME="battery-charge-limit.service"
readonly OPENRC_SERVICE_NAME="battery-limit"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
readonly DEFAULT_LIMIT=80

# Detect TTY for safe automation logging
if [[ -t 1 && -t 2 ]]; then
	readonly RED=$'\033[1;31m'
	readonly GREEN=$'\033[1;32m'
	readonly YELLOW=$'\033[1;33m'
	readonly BLUE=$'\033[1;34m'
	readonly BOLD=$'\033[1m'
	readonly NC=$'\033[0m'
else
	readonly RED=''
	readonly GREEN=''
	readonly YELLOW=''
	readonly BLUE=''
	readonly BOLD=''
	readonly NC=''
fi

# Globals for argument parsing and state
declare -g ACTION="interactive"
declare -g LIMIT=""
declare -g PERSIST=""
declare -a TARGET_FILES=()

declare -g TARGET_USER=""
declare -g STATE_DIR=""
declare -g STATE_FILE=""

# ------------------------------------------------------------------------------
# Logging Utilities
# ------------------------------------------------------------------------------
info() { printf "${BLUE}::${NC} ${BOLD}%s${NC}\n" "$*"; }
success() { printf "${GREEN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}WARNING:${NC} %s\n" "$*" >&2; }
error() { printf "${RED}ERROR:${NC} %s\n" "$*" >&2; }
die() {
	error "$*"
	exit 1
}

# ------------------------------------------------------------------------------
# Privilege Escalation & User Context
# ------------------------------------------------------------------------------
require_root() {
	if ((EUID != 0)); then
		command -v sudo >/dev/null 2>&1 || die "sudo is required to escalate privileges."
		command -v realpath >/dev/null 2>&1 || die "realpath is required for safe re-execution."

		local abs_path
		abs_path=$(realpath "$0") || die "Failed to resolve absolute path of script."

		info "Escalating privileges via sudo..."
		exec sudo "${abs_path}" "$@"
	fi
}

resolve_user_context() {
	TARGET_USER="${SUDO_USER:-${USER:-root}}"

	local user_home
	user_home=$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)
	user_home=${user_home:-/root}

	STATE_DIR="${user_home}/.config/dawn/settings"
	STATE_FILE="${STATE_DIR}/battery_limiter"
}

# ------------------------------------------------------------------------------
# Hardware Detection
# ------------------------------------------------------------------------------
detect_batteries() {
	local -i found_battery=0

	shopt -s nullglob
	for bat in /sys/class/power_supply/BAT*; do
		found_battery=1
		if [[ -f "${bat}/charge_control_end_threshold" ]]; then
			TARGET_FILES+=("${bat}/charge_control_end_threshold")
		elif [[ -f "${bat}/stop_charge_thresh" ]]; then
			TARGET_FILES+=("${bat}/stop_charge_thresh")
		fi
	done
	shopt -u nullglob

	((found_battery == 1)) || die "No batteries detected in /sys/class/power_supply/"
	((${#TARGET_FILES[@]} > 0)) || die "Your hardware/kernel lacks standard sysfs threshold support."
}

# ------------------------------------------------------------------------------
# Core Logic
# ------------------------------------------------------------------------------
display_status() {
	info "Current Hardware Thresholds:"
	for file in "${TARGET_FILES[@]}"; do
		local bat_name current_val=""
		bat_name=$(basename "$(dirname "${file}")")

		if [[ -r "${file}" ]]; then
			read -r current_val <"${file}" 2>/dev/null || true
			current_val="${current_val//[$'\t\r\n ']/}" # Strip all whitespace
		fi

		if [[ -n "${current_val}" ]]; then
			printf "    ${BOLD}%s${NC} -> ${GREEN}%s%%${NC}\n" "${bat_name}" "${current_val}"
		elif [[ ! -r "${file}" ]]; then
			printf "    ${BOLD}%s${NC} -> ${RED}[Requires Root or Unreadable]${NC}\n" "${bat_name}"
		else
			if [[ -f "${STATE_FILE}" ]]; then
				local cached_val=""
				read -r cached_val <"${STATE_FILE}" 2>/dev/null || true
				cached_val="${cached_val//[$'\t\r\n ']/}"

				if [[ -n "${cached_val}" ]]; then
					printf "    ${BOLD}%s${NC} -> ${YELLOW}%s (Cached / Write-Only Driver)${NC}\n" "${bat_name}" "${cached_val}"
				else
					printf "    ${BOLD}%s${NC} -> ${YELLOW}[Driver returns empty / Write-Only]${NC}\n" "${bat_name}"
				fi
			else
				printf "    ${BOLD}%s${NC} -> ${YELLOW}[Driver returns empty / Write-Only]${NC}\n" "${bat_name}"
			fi
		fi
	done
	printf "\n"
}

update_user_state() {
	local limit=$1
	info "Syncing Waybar state to target context (${TARGET_USER})..."

	# Switched to heavily simplified single-quotes and echo to bypass bash escaping bugs
	local snippet="mkdir -p '${STATE_DIR}' && echo '${limit}%' > '${STATE_FILE}' && chmod 644 '${STATE_FILE}'"

	if runuser -u "${TARGET_USER}" -- /bin/bash -c "${snippet}"; then
		success "Dusky state updated: ${STATE_FILE} -> ${limit}%"
		return 0
	else
		error "Failed to write Waybar state to ${STATE_FILE}"
		return 1
	fi
}

apply_limits_live() {
	local limit=$1
	local -i failures=0

	info "Applying ${limit}% charge limit..."

	for file in "${TARGET_FILES[@]}"; do
		local bat_name current_val="" verify_val=""
		bat_name=$(basename "$(dirname "${file}")")

		# Skip if already set
		if [[ -r "${file}" ]]; then
			read -r current_val <"${file}" 2>/dev/null || true
			current_val="${current_val//[$'\t\r\n ']/}"
			if [[ "${current_val}" == "${limit}" ]]; then
				success "[${bat_name}] Already set to ${limit}%"
				continue
			fi
		fi

		# Write to kernel
		if printf "%s" "${limit}" >"${file}" 2>/dev/null; then
			if [[ -r "${file}" ]]; then
				read -r verify_val <"${file}" 2>/dev/null || true
				verify_val="${verify_val//[$'\t\r\n ']/}"
			fi

			# Validation Logic
			if [[ "${verify_val}" == "${limit}" ]]; then
				success "[${bat_name}] Successfully locked at ${limit}%"
			elif [[ -z "${verify_val}" ]]; then
				warn "[${bat_name}] Hardware accepted write, but driver read-back is empty."
				success "[${bat_name}] Assumed locked at ${limit}% (Write-Only Driver)"
			else
				error "[${bat_name}] Kernel state mismatch. Wrote ${limit}, read back '${verify_val}'."
				failures=1
			fi
		else
			error "[${bat_name}] Kernel rejected write. The limit ${limit}% may be unsupported by your hardware."
			failures=1
		fi
	done

	if ((failures == 0)); then
		update_user_state "${limit}" || failures=1
	fi

	return "${failures}"
}

setup_persistence() {
	local limit=$1

	info "Configuring OpenRC persistence..."

	# Create OpenRC init script
	cat >"/etc/init.d/${OPENRC_SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="Battery Charge Limit"
command="/usr/bin/bash"
command_args="-c 'printf \"${limit}\" > \${TARGET_FILE}'"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need localmount
}
EOF

	# Write threshold to a known location for the init script to read
	for file in "${TARGET_FILES[@]}"; do
		echo "${limit}" >"/run/${OPENRC_SERVICE_NAME}.limit"
		break
	done

	chmod +x "/etc/init.d/${OPENRC_SERVICE_NAME}"
	rc-update add "${OPENRC_SERVICE_NAME}" default
	success "Persistence bound to OpenRC (Hardware Tolerant)."
}

remove_persistence() {
	if [[ -f "/etc/init.d/${OPENRC_SERVICE_NAME}" ]]; then
		info "Purging persistence configuration..."
		rc-service "${OPENRC_SERVICE_NAME}" stop 2>/dev/null || true
		rc-update del "${OPENRC_SERVICE_NAME}" default 2>/dev/null || true
		rm -f "/etc/init.d/${OPENRC_SERVICE_NAME}"
		success "OpenRC configuration cleanly removed."
	else
		info "No active persistence found. Nothing to remove."
	fi
}

# ------------------------------------------------------------------------------
# User Input & CLI Parsing
# ------------------------------------------------------------------------------
print_usage() {
	printf "Usage: %s [OPTIONS]\n\n" "${0##*/}"
	printf "Options:\n"
	printf "  -l, --limit <1-100>   Set charge threshold\n"
	printf "  -p, --persist         Persist limit across reboots (Requires -l)\n"
	printf "  -n, --no-persist      Apply for current session only (Requires -l)\n"
	printf "  -s, --status          Display current battery thresholds\n"
	printf "  -r, --remove          Remove systemd persistence\n"
	printf "  -h, --help            Show this help menu\n\n"
	printf "Run without arguments for interactive mode.\n"
	exit 0
}

parse_args() {
	while (($# > 0)); do
		case "$1" in
		-l | --limit)
			[[ -n "${2:-}" ]] || die "Missing value for $1"
			LIMIT="$2"
			ACTION="apply"
			shift 2
			;;
		-p | --persist)
			PERSIST="y"
			shift
			;;
		-n | --no-persist)
			PERSIST="n"
			shift
			;;
		-s | --status)
			ACTION="status"
			shift
			;;
		-r | --remove)
			ACTION="remove"
			shift
			;;
		-h | --help)
			print_usage
			;;
		*)
			die "Unknown parameter: $1"
			;;
		esac
	done

	if [[ -n "${PERSIST}" && "${ACTION}" != "apply" ]]; then
		die "--persist and --no-persist flags require the --limit flag."
	fi
}

validate_limit_input() {
	local val=$1
	[[ "${val}" =~ ^([1-9][0-9]?|100)$ ]]
}

# ------------------------------------------------------------------------------
# Main Execution Flow
# ------------------------------------------------------------------------------
main() {
	parse_args "$@"

	if [[ "${ACTION}" == "status" ]]; then
		resolve_user_context
		detect_batteries
		display_status
		exit 0
	fi

	if [[ "${ACTION}" == "remove" ]]; then
		require_root "$@"
		remove_persistence
		exit 0
	fi

	require_root "$@"
	resolve_user_context
	detect_batteries

	if [[ "${ACTION}" == "interactive" ]]; then
		display_status

		while true; do
			printf "${YELLOW}?>${NC} Target charge limit (1-100) [Default: %s]: " "${DEFAULT_LIMIT}"
			read -r LIMIT || die "Input aborted."
			LIMIT=${LIMIT:-${DEFAULT_LIMIT}}
			validate_limit_input "${LIMIT}" && break
			warn "Invalid integer. Must be between 1 and 100."
		done

		while true; do
			printf "${YELLOW}?>${NC} Persist across reboots? (y/n) [Default: y]: "
			read -r PERSIST || die "Input aborted."
			PERSIST=${PERSIST:-y}
			[[ "${PERSIST,,}" =~ ^(y|n|yes|no)$ ]] && break
			warn "Please answer 'y' or 'n'."
		done

		[[ "${PERSIST,,}" =~ ^y ]] && PERSIST="y" || PERSIST="n"
		printf "\n"
	fi

	validate_limit_input "${LIMIT}" || die "Invalid limit specified: ${LIMIT}"

	if ! apply_limits_live "${LIMIT}"; then
		warn "Failed applying thresholds. Ensure your hardware supports custom limits."
		exit 1
	fi

	if [[ "${PERSIST}" == "y" ]]; then
		setup_persistence "${LIMIT}"
	else
		remove_persistence
		info "Configuration is ephemeral. Will reset upon reboot."
	fi

	printf "\n"
	success "Battery limits successfully enforced."
}

main "$@"
