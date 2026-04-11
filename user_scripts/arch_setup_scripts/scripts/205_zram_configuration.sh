#!/usr/bin/env bash
# ==============================================================================
# Zram Configuration
# Context: Artix Linux (OpenRC) / Hyprland
# Logic:   Dynamic configuration based on available RAM (<=8GB vs >8GB)
# ==============================================================================

set -euo pipefail

# --- Styles ---
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
YELLOW=$'\033[1;33m'
RED=$'\033[0;31m'
NC=$'\033[0m'

log_info() { printf '%s[INFO]%s    %s\n' "${BLUE}" "${NC}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "${GREEN}" "${NC}" "$1"; }
log_err() { printf '%s[ERROR]%s   %s\n' "${RED}" "${NC}" "$1" >&2; }

# --- 1. Root Privilege Escalation ---
if [[ "${EUID}" -ne 0 ]]; then
	printf '%s[INFO]%s    Privilege escalation required.\n' "${YELLOW}" "${NC}"
	exec sudo "$0" "$@"
fi

# --- 2. Detect init system ---
IS_OPENRC=false
if command -v rc-service >/dev/null 2>&1; then
	IS_OPENRC=true
	log_info "OpenRC detected."
else
	log_info "Standard init detected (systemd or other)."
fi

# --- 3. Ensure zram-generator is installed ---
if ! pacman -Qq zram-generator >/dev/null 2>&1; then
	log_info "Installing zram-generator..."
	pacman -S --noconfirm zram-generator || {
		log_err "Failed to install zram-generator."
		exit 1
	}
fi

# On OpenRC, also install the service wrapper
if [[ "${IS_OPENRC}" == true ]]; then
	if ! pacman -Qq zram-generator-openrc >/dev/null 2>&1; then
		log_info "Installing zram-generator-openrc (OpenRC service wrapper)..."
		pacman -S --noconfirm zram-generator-openrc || {
			log_err "Failed to install zram-generator-openrc."
			log_err "Install it manually: pacman -S zram-generator-openrc"
		}
	fi
fi

# --- 4. Configuration file path ---
CONFIG_FILE="/etc/systemd/zram-generator.conf"
MOUNT_POINT="/mnt/zram1"

log_info "Detected config path: ${CONFIG_FILE}"

# Create the config directory if it doesn't exist
CONFIG_DIR="$(dirname "${CONFIG_FILE}")"
if [[ ! -d "${CONFIG_DIR}" ]]; then
	mkdir -p "${CONFIG_DIR}"
	log_info "Created config directory: ${CONFIG_DIR}"
fi

# --- 5. Memory Calculation ---
TOTAL_MEM_KB=""
while read -r key value _unit; do
	if [[ "$key" == "MemTotal:" ]]; then
		TOTAL_MEM_KB=$value
		break
	fi
done </proc/meminfo

TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
log_info "Detected System RAM: ${TOTAL_MEM_MB} MB"

# --- 6. Logic Determination ---
if ((TOTAL_MEM_MB <= 8192)); then
	ZRAM_SIZE_VAL="ram"
	log_info "RAM is <= 8GB. Setting zram-size to full 'ram'."
else
	ZRAM_SIZE_VAL="ram - 2000"
	log_info "RAM is > 8GB. Setting zram-size to 'ram - 2000'."
fi

# --- 7. Execution ---
if [[ ! -d "$MOUNT_POINT" ]]; then
	mkdir -p "$MOUNT_POINT"
	log_info "Created mount point: $MOUNT_POINT"
fi

cat >"${CONFIG_FILE}" <<EOF
[zram0]
zram-size = ${ZRAM_SIZE_VAL}
compression-algorithm = zstd

[zram1]
zram-size = ${ZRAM_SIZE_VAL}
fs-type = ext2
mount-point = ${MOUNT_POINT}
compression-algorithm = zstd
options = rw,nosuid,nodev,discard,X-mount.mode=1777
EOF

log_success "Configuration written to ${CONFIG_FILE}"

# --- 8. Enable the service ---
if [[ "${IS_OPENRC}" == true ]]; then
	log_info "Enabling zram-generator OpenRC service..."
	if rc-service -l 2>/dev/null | grep -q "^zram-generator$"; then
		rc-update add zram-generator boot 2>/dev/null || true
		rc-service zram-generator start 2>/dev/null || true
		log_success "zram-generator enabled via OpenRC."
	else
		log_err "zram-generator service not found in OpenRC. You may need to install zram-generator-openrc."
	fi
else
	log_info "systemd-zram-setup will be enabled on next boot."
	log_info "Run 'systemctl enable systemd-zram-setup@zram0.service' manually if needed."
fi

log_info "ZRAM configuration complete. Changes apply on next reboot."
