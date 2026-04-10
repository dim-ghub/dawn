#!/usr/bin/env bash
# Installs and configures Cloudflare warp 1.1.1.1

set -euo pipefail
IFS=$'\n\t'

# --- Init System ---
readonly INIT_SYSTEM="openrc"

# =============================================================================
# Configuration
# =============================================================================
readonly BUILD_DIR="/tmp/warp_autonomous_build_$$"
readonly AUR_REPO="https://aur.archlinux.org/cloudflare-warp-nox-bin.git"
readonly SERVICE_NAME="warp-svc"
readonly MAX_SERVICE_WAIT=30
readonly MAX_CONNECT_WAIT=15
readonly MAX_REGISTER_ATTEMPTS=3

# =============================================================================
# Visuals (TTY Detection)
# =============================================================================
if [[ -t 1 ]]; then
	readonly C_RESET=$'\033[0m'
	readonly C_GREEN=$'\033[32m'
	readonly C_BLUE=$'\033[34m'
	readonly C_RED=$'\033[31m'
	readonly C_CYAN=$'\033[36m'
	readonly C_YELLOW=$'\033[33m'
else
	readonly C_RESET="" C_GREEN="" C_BLUE="" C_RED="" C_CYAN="" C_YELLOW=""
fi

log_info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_success() { printf '%s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_error() { printf '%s[ERR]%s  %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_step() { printf '\n%s:: %s%s\n' "$C_CYAN" "$*" "$C_RESET"; }

die() {
	log_error "$*"
	exit 1
}

# =============================================================================
# Cleanup & Signal Handling
# =============================================================================
cleanup() {
	local exit_code=$?
	if [[ -d "$BUILD_DIR" ]]; then
		rm -rf -- "$BUILD_DIR"
	fi
	exit "$exit_code"
}
# Trap EXIT and common kill signals to ensure cleanup runs
trap cleanup EXIT INT TERM HUP

# =============================================================================
# Auto-Elevation & User Detection
# =============================================================================
auto_elevate() {
	if [[ $EUID -ne 0 ]]; then
		log_warn "This script requires root permissions."
		log_info "Elevating privileges..."
		# Using realpath ensures re-execution works even if called from other dirs
		exec sudo -- "$(realpath "$0")" "$@"
	fi
}

detect_real_user() {
	local user=""

	# Priority 1: SUDO_USER (Standard for sudo calls)
	if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
		user="$SUDO_USER"
	# Priority 2: logname (User logged into the TTY)
	elif user=$(logname 2>/dev/null) && [[ -n "$user" && "$user" != "root" ]]; then
		:
	# Priority 3: Owner of the current TTY (Fallback)
	elif [[ -t 0 ]]; then
		user=$(stat -c '%U' "$(tty)" 2>/dev/null) || user=""
	fi

	if [[ -z "$user" || "$user" == "root" ]]; then
		die "Cannot determine the invoking user. Do not run directly as root login."
	fi

	printf '%s' "$user"
}

# =============================================================================
# Helpers
# =============================================================================
run_as_user() {
	sudo -u "$REAL_USER" -- "$@"
}

wait_for() {
	local description="$1" timeout="$2" check_cmd="$3"
	local elapsed=0

	log_info "Waiting for $description..."
	while ! eval "$check_cmd" &>/dev/null; do
		if ((elapsed >= timeout)); then
			return 1
		fi
		sleep 1
		((elapsed++))
	done
	return 0
}

# =============================================================================
# Core Logic
# =============================================================================

install_package() {
	log_step "Preparing Build Environment..."

	# Refresh package DB and install deps
	pacman -S --noconfirm --needed git base-devel >/dev/null

	# Setup build dir
	rm -rf -- "$BUILD_DIR"
	mkdir -p -- "$BUILD_DIR"
	# Use trailing colon to auto-detect the user's primary group
	chown -R "$REAL_USER": "$BUILD_DIR"

	log_info "Cloning AUR repository as user: $REAL_USER"
	# Depth 1 makes cloning significantly faster
	run_as_user git clone --quiet --depth=1 "$AUR_REPO" "$BUILD_DIR"

	log_info "Building package (makepkg)..."
	# Run in subshell to preserve script's CWD
	if ! (cd "$BUILD_DIR" && run_as_user makepkg -sf --noconfirm); then
		die "Package build failed."
	fi

	log_info "Installing built package..."
	local pkg_file
	pkg_file=$(find "$BUILD_DIR" -maxdepth 1 -name "*.pkg.tar.*" -print -quit)

	if [[ -z "$pkg_file" ]]; then
		die "Could not locate built package file."
	fi

	pacman -U --noconfirm "$pkg_file"
	log_success "Package installed successfully."
}

configure_service() {
	log_step "Initializing Service..."

	rc-update add "$SERVICE_NAME" default 2>/dev/null || true
	rc-service "$SERVICE_NAME" start 2>/dev/null || true

	if ! wait_for "service activation" "$MAX_SERVICE_WAIT" "rc-service $SERVICE_NAME status >/dev/null 2>&1"; then
		die "Service failed to start within ${MAX_SERVICE_WAIT}s."
	fi

	# Wait for daemon internal state (socket readiness)
	if ! wait_for "daemon socket" 10 "run_as_user warp-cli --accept-tos status"; then
		log_warn "Daemon socket check timed out, but proceeding..."
	fi
}

setup_warp() {
	log_step "Configuring Warp (As user: $REAL_USER)..."

	# 1. Cleanup old registration
	log_info "Checking registration state..."
	run_as_user warp-cli --accept-tos registration delete &>/dev/null || true

	# 2. Register with retry logic
	log_info "Registering new client..."
	local attempt
	local reg_success=0
	for ((attempt = 1; attempt <= MAX_REGISTER_ATTEMPTS; attempt++)); do
		if run_as_user warp-cli --accept-tos registration new >/dev/null; then
			reg_success=1
			break
		fi
		log_warn "Registration attempt $attempt failed. Retrying..."
		sleep 2
	done

	if ((reg_success == 0)); then
		die "Failed to register after multiple attempts."
	fi
	log_success "Registration successful."

	# 3. Connect
	log_info "Connecting..."
	if ! run_as_user warp-cli --accept-tos connect >/dev/null; then
		die "Failed to issue connect command."
	fi

	# 4. Verify Connection
	log_info "Verifying connection..."
	if wait_for "secure connection" "$MAX_CONNECT_WAIT" "run_as_user warp-cli --accept-tos status | grep -q 'Connected'"; then
		log_success "Warp is Connected and Secured."

		# 5. PERSIST TOS ACCEPTANCE (Critical Fix)
		# We invoke 'script' (part of util-linux) to fake a PTY.
		# This tricks warp-cli into accepting the piped 'y' for the interactive prompt.
		# This prevents the user from having to type 'y' on every manual run.
		log_info "Persisting TOS acceptance for interactive CLI usage..."

		# We disable pipefail locally because 'echo' will close the pipe when it finishes,
		# which is normal, but strict mode hates it.
		set +o pipefail

		if {
			sleep 0.5
			echo "y"
		} | sudo -u "$REAL_USER" script -q -c "warp-cli status" /dev/null >/dev/null 2>&1; then
			log_success "Terms of Service acceptance persisted."
		else
			log_warn "Could not explicitly persist TOS. You may need to accept it once manually."
		fi

		set -o pipefail

	else
		log_warn "Connection verification timed out. Setup likely succeeded."
		log_warn "You can verify manually later with: warp-cli status"
	fi
}

prompt_user() {
	# Check if we should prompt
	if command -v warp-cli &>/dev/null; then
		return 0
	fi

	printf "${C_YELLOW}[?]${C_RESET} Cloudflare Warp is not installed.\n"
	# read -r -p works, adding || true ensures set -e doesn't kill script on EOF
	read -r -p "Would you like to install and activate it? [Y/n] " response || true
	response=${response:-Y}

	if [[ "$response" =~ ^[nN]([oO])?$ ]]; then
		log_info "Installation aborted by user."
		exit 0
	fi
}

# =============================================================================
# Main
# =============================================================================
main() {
	# 1. Elevate permissions
	auto_elevate "$@"

	# 2. Detect User
	readonly REAL_USER=$(detect_real_user)

	# 3. Prompt (Run before extensive logging)
	prompt_user

	log_info "Starting Setup for User: $REAL_USER"

	# 4. Install if needed
	if ! pacman -Qi cloudflare-warp-nox-bin &>/dev/null; then
		install_package
	else
		log_success "Package already installed."
	fi

	# 5. Configure & Connect
	configure_service
	setup_warp

	log_step "All Done. Traffic is secured."
}

main "$@"
