#!/usr/bin/env bash
# Interactive fix for asusd D-Bus 'sudo' group policy (asus systems only)
# Target OS:   Arch Linux (Hyprland/UWSM environment)
# Logic:       Root Check -> Service Detection -> User Prompt -> Atomic Fix
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Detect Init System ---
detect_init() {
	if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
		echo "systemd"
	elif command -v rc-service >/dev/null 2>&1; then
		echo "openrc"
	else
		echo "unknown"
	fi
}
readonly INIT_SYSTEM=$(detect_init)

# --- Configuration ---
readonly TARGET_FILE="/usr/share/dbus-1/system.d/asusd.conf"
readonly SERVICE_NAME="asusd"

# ANSI Colors
readonly C_RESET=$'\033[0m'
readonly C_GREEN=$'\033[1;32m'
readonly C_BLUE=$'\033[1;34m'
readonly C_RED=$'\033[1;31m'
readonly C_YELLOW=$'\033[1;33m'

# --- Logging Helpers ---
log_info() { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$1"; }
log_success() { printf "${C_GREEN}[OK]${C_RESET}   %s\n" "$1"; }
log_warn() { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$1"; }
log_err() {
	printf "${C_RED}[ERR]${C_RESET}  %s\n" "$1" >&2
	exit 1
}

# --- Privilege Check ---
if [[ $EUID -ne 0 ]]; then
	# Pass all arguments to the sudo call
	exec sudo "$0" "$@"
fi

# --- Main Logic ---
main() {
	# 1. Critical Check: Is asusd even installed?
	# We check for the config file because that is what we intend to modify.
	if [[ ! -f "$TARGET_FILE" ]]; then
		log_warn "The file $TARGET_FILE was not found."
		log_info "It appears 'asusd' is not installed on this system."
		log_info "No actions are necessary. Exiting."
		exit 0
	fi

	# 2. User Interaction: Confirm Hardware
	# We use /dev/tty to force interaction even if script is piped (though unlikely here)
	printf "${C_YELLOW}[?]${C_RESET} Is this an ASUS laptop? [y/N] "
	read -r -n 1 response </dev/tty
	echo "" # Newline for formatting

	if [[ ! "$response" =~ ^[yY]$ ]]; then
		log_info "User indicated this is not an ASUS laptop (or cancelled)."
		log_info "Aborting operation safely."
		exit 0
	fi

	# 3. Idempotency Check
	if ! grep -q 'group="sudo"' "$TARGET_FILE"; then
		log_success "Configuration is already clean (no 'sudo' group policy found)."
		exit 0
	fi

	log_info "Confirmed ASUS laptop and legacy 'sudo' policy detected."

	# 4. Atomic Removal
	sed -i '/<policy group="sudo">/,/<\/policy>/d' "$TARGET_FILE"

	# 5. Verification
	if grep -q 'group="sudo"' "$TARGET_FILE"; then
		log_err "Failed to remove the policy block. Check file permissions."
	else
		log_success "Policy block removed successfully."
	fi

	# 6. Service Restart
	log_info "Restarting $SERVICE_NAME ($INIT_SYSTEM)..."
	if [[ "$INIT_SYSTEM" == "systemd" ]]; then
		if systemctl restart "${SERVICE_NAME}.service"; then
			log_success "Service restarted successfully."
		else
			log_warn "Service restart failed. You may need to start it manually."
		fi
	else
		if rc-service "$SERVICE_NAME" restart 2>/dev/null; then
			log_success "Service restarted successfully."
		else
			log_warn "Service restart failed. You may need to start it manually."
		fi
	fi
}

main
