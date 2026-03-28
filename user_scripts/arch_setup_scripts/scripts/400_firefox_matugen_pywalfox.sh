#!/usr/bin/env bash
# firefox setup for matugen themeing
# -----------------------------------------------------------------------------
# Script: 044_firefox_pywal.sh
# Description: Setup Firefox, Pywalfox, and Matugen (Orchestra compatible)
# Environment: Arch Linux / Hyprland / UWSM
# -----------------------------------------------------------------------------

# --- Safety & Error Handling ---
set -euo pipefail
IFS=$'\n\t'
trap 'printf "\n[WARN] Script interrupted. Exiting.\n" >&2; exit 130' INT TERM

# --- Configuration ---
readonly TARGET_URL='https://addons.mozilla.org/en-US/firefox/addon/pywalfox/'
readonly BROWSER_BIN='firefox'
readonly NATIVE_HOST_PKG='python-pywalfox'
readonly THEME_ENGINE_PKG='matugen'

# --- Visual Styling ---
if command -v tput &>/dev/null && (($(tput colors 2>/dev/null || echo 0) >= 8)); then
	readonly C_RESET=$'\033[0m'
	readonly C_BOLD=$'\033[1m'
	readonly C_BLUE=$'\033[38;5;45m'
	readonly C_GREEN=$'\033[38;5;46m'
	readonly C_MAGENTA=$'\033[38;5;177m'
	readonly C_WARN=$'\033[38;5;214m'
	readonly C_ERR=$'\033[38;5;196m'
else
	readonly C_RESET='' C_BOLD='' C_BLUE='' C_GREEN=''
	readonly C_MAGENTA='' C_WARN='' C_ERR=''
fi

# --- Logging Utilities ---
log_info() { printf '%b[INFO]%b %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%b[WARNING]%b %s\n' "${C_WARN}" "${C_RESET}" "$1" >&2; }
die() {
	printf '%b[ERROR]%b %s\n' "${C_ERR}" "${C_RESET}" "$1" >&2
	exit 1
}

# --- Helper Functions ---
check_aur_helper() {
	if command -v paru &>/dev/null; then
		echo "paru"
	elif command -v yay &>/dev/null; then
		echo "yay"
	else return 1; fi
}

preflight() {
	if ((EUID == 0)); then die 'Run as normal user, not Root.'; fi
}

# --- Main Logic ---
main() {
	preflight

	# 1. Interactive Prompt (No Timeout)
	printf '\n%b>>> OPTIONAL SETUP: FIREFOX, PYWALFOX & MATUGEN%b\n' "${C_WARN}" "${C_RESET}"
	printf 'This will install Firefox, Matugen, and the Pywalfox backend.\n'
	printf '%bDo you want to proceed? [y/N]:%b ' "${C_BOLD}" "${C_RESET}"

	local response=''
	read -r response || true

	if [[ ! "${response,,}" =~ ^y(es)?$ ]]; then
		log_info 'Skipping setup by user request.'
		exit 0
	fi

	# 2. Standard Packages
	log_info "Ensuring ${BROWSER_BIN} and ${THEME_ENGINE_PKG} are installed..."
	if sudo pacman -S --needed --noconfirm "${BROWSER_BIN}" "${THEME_ENGINE_PKG}"; then
		log_success "Core packages verified."
	else
		die "Failed to install standard packages."
	fi

	# 3. The Critical Pywalfox Logic (The "Smart" Part)
	log_info "Handling ${NATIVE_HOST_PKG}..."
	local helper
	if helper=$(check_aur_helper); then
		# Check if installed, then NUKE it to force clean state
		if pacman -Qq "${NATIVE_HOST_PKG}" &>/dev/null; then
			log_warn "Existing ${NATIVE_HOST_PKG} found. Removing to enforce clean rebuild..."
			sudo pacman -Rns --noconfirm "${NATIVE_HOST_PKG}" || true
		fi

		log_info "Installing/Rebuilding ${NATIVE_HOST_PKG} with ${helper}..."
		if "$helper" -S --rebuild --noconfirm "${NATIVE_HOST_PKG}"; then
			log_success "${NATIVE_HOST_PKG} ready."

			# Auto-register manifest
			if command -v pywalfox &>/dev/null; then
				log_info "Refreshing manifest..."
				pywalfox install || log_warn "Manifest update failed (non-fatal)."
			fi
		else
			die "Failed to install ${NATIVE_HOST_PKG}."
		fi
	else
		log_warn "No AUR helper found. Skipping Pywalfox backend."
	fi

	# 4. Instructions
	hash -r 2>/dev/null || true
	if [[ -t 1 ]]; then clear; fi

	printf '%b%b' "${C_BOLD}" "${C_BLUE}"
	cat <<'BANNER'
   ╔═══════════════════════════════════════╗
   ║      PYWALFOX SETUP ASSISTANT         ║
   ║      Arch / Hyprland / UWSM           ║
   ╚═══════════════════════════════════════╝
BANNER
	printf '%b\n' "${C_RESET}"
	printf "%b[Action Required]%b: Open Firefox -> Install Extensions -> Pywalfox -> 'Fetch Pywal Colors'\n" "${C_WARN}" "${C_RESET}"
	printf "Press %b[ENTER]%b to launch Firefox..." "${C_GREEN}" "${C_RESET}"
	read -r || true

	# 5. Launch Browser
	log_info "Launching..."
	nohup "${BROWSER_BIN}" "${TARGET_URL}" &>/dev/null 2>&1 &
	disown &>/dev/null || true
}

main "$@"
