#!/usr/bin/env bash
# ==============================================================================
# Description:  Installs artix-archlinux-support and configures Arch repos
#               in pacman.conf. Only runs on Artix Linux (OpenRC).
#               Skips entirely on standard Arch Linux.
#
# On Artix, this package provides:
#   - /etc/pacman.d/mirrorlist-arch (Arch mirror list)
#   - archlinux-keyring and archlinux-mirrorlist as dependencies
#   - The Arch [extra] and [multilib] repo entries
#
# Artix repos (system, world, galaxy, lib32) always take precedence
# because they are listed first in pacman.conf.
# ==============================================================================

set -euo pipefail

# --- Root Privilege Check ---
if [[ "${EUID}" -ne 0 ]]; then
	SCRIPT_PATH="$(readlink -f "$0")"
	exec sudo "${SCRIPT_PATH}" "$@"
fi

# --- Presentation Constants ---
readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_BOLD=$'\033[1m'

log_info() { printf '%s[INFO]%s    %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%s[WARN]%s    %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
log_error() { printf '%s[ERROR]%s   %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }

# --- OS Detection ---
if ! grep -qiE '^ID=(artix|artixlinux)$' /etc/os-release 2>/dev/null; then
	log_info "Standard Arch Linux detected. Arch repo support not needed — skipping."
	exit 0
fi

log_info "Artix Linux detected. Setting up Arch Linux repository support..."

PACMAN_CONF="/etc/pacman.conf"

# --- Step 1: Install artix-archlinux-support ---
log_info "Installing artix-archlinux-support package..."
if pacman -Qq artix-archlinux-support >/dev/null 2>&1; then
	log_info "artix-archlinux-support is already installed."
else
	if pacman -Sy --noconfirm artix-archlinux-support; then
		log_success "artix-archlinux-support installed."
	else
		log_error "Failed to install artix-archlinux-support."
		log_error "Cannot continue without Arch repo support. Exiting."
		exit 1
	fi
fi

# --- Step 2: Uncomment [lib32] repo in pacman.conf ---
# artix-archlinux-support may have already configured pacman.conf,
# but we ensure [lib32] (Artix 32-bit compat) is uncommented.
if grep -q '^#\[lib32\]' "${PACMAN_CONF}" 2>/dev/null; then
	log_info "Enabling [lib32] repository in pacman.conf..."
	sed -i '/^#\[lib32\]/,/^#Include = \/etc\/pacman.d\/mirrorlist/ s/^#//' "${PACMAN_CONF}"
fi

# --- Step 3: Ensure Arch [extra] and [multilib] repos are configured ---
# These must come AFTER the Artix repos so Artix takes precedence
# when package names collide with equal or higher versions.

CHANGED=0

if ! grep -q '^\[extra\]' "${PACMAN_CONF}" 2>/dev/null; then
	log_info "Adding [extra] repository to pacman.conf..."
	printf '\n# Arch Linux repositories (Artix repos take precedence)\n[extra]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >>"${PACMAN_CONF}"
	CHANGED=1
fi

if ! grep -q '^\[multilib\]' "${PACMAN_CONF}" 2>/dev/null; then
	log_info "Adding [multilib] repository to pacman.conf..."
	printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist-arch\n' >>"${PACMAN_CONF}"
	CHANGED=1
fi

# Verify that Artix repos come before Arch repos (precedence check)
ARTIX_LINE=$(grep -n '^\[system\]\|^\[world\]\|^\[galaxy\]' "${PACMAN_CONF}" 2>/dev/null | head -1 | cut -d: -f1)
ARCH_LINE=$(grep -n '^\[extra\]' "${PACMAN_CONF}" 2>/dev/null | head -1 | cut -d: -f1)

if [[ -n "${ARTIX_LINE}" ]] && [[ -n "${ARCH_LINE}" ]]; then
	if ((ARTIX_LINE > ARCH_LINE)); then
		log_warn "Artix repos appear AFTER Arch repos in pacman.conf."
		log_warn "This may cause issues — Artix repos must take precedence."
		log_warn "Please reorder pacman.conf so [system], [world], [galaxy] come before [extra], [multilib]."
	fi
fi

# --- Step 4: Populate Arch Linux keyring ---
log_info "Populating Arch Linux keyring..."
if pacman-key --populate archlinux 2>/dev/null; then
	log_success "Arch Linux keyring populated."
else
	log_warn "pacman-key --populate archlinux failed. Attempting alternative approach..."
	# Initialize keyring if needed
	pacman-key --init 2>/dev/null || true
	pacman-key --populate archlinux 2>/dev/null || log_warn "Arch keyring population failed. You may need to run: pacman-key --populate archlinux"
fi

# --- Step 5: Sync package databases ---
log_info "Syncing package databases..."
if pacman -Syy; then
	log_success "Package databases synced."
else
	log_error "Failed to sync package databases. Check your mirrorlists."
	exit 1
fi

log_success "Arch Linux repository support is now configured."
log_info "Artix repos (system, world, galaxy, lib32) take precedence over Arch repos (extra, multilib)."
