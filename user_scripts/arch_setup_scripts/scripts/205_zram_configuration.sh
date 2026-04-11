#!/usr/bin/env bash
# ==============================================================================
# Zram Configuration for OpenRC
# ==============================================================================
# Context: Artix Linux (OpenRC) / Hyprland
# Logic:   Dynamic configuration based on available RAM (<=8GB vs >8GB)
# Note:    zram-generator binary works on OpenRC but needs a custom init
#          script since there is no zram-generator-openrc package.
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

# --- 2. Ensure zram-generator is installed ---
if ! pacman -Qq zram-generator >/dev/null 2>&1; then
	log_info "Installing zram-generator..."
	pacman -S --noconfirm zram-generator || {
		log_err "Failed to install zram-generator."
		exit 1
	}
fi

# --- 3. Configuration file ---
CONFIG_FILE="/etc/systemd/zram-generator.conf"
MOUNT_POINT="/mnt/zram1"

log_info "Detected config path: ${CONFIG_FILE}"

# Create the config directory if it doesn't exist
CONFIG_DIR="$(dirname "${CONFIG_FILE}")"
if [[ ! -d "${CONFIG_DIR}" ]]; then
	mkdir -p "${CONFIG_DIR}"
	log_info "Created config directory: ${CONFIG_DIR}"
fi

# --- 4. Memory Calculation ---
TOTAL_MEM_KB=""
while read -r key value _unit; do
	if [[ "$key" == "MemTotal:" ]]; then
		TOTAL_MEM_KB=$value
		break
	fi
done </proc/meminfo

TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
log_info "Detected System RAM: ${TOTAL_MEM_MB} MB"

# --- 5. Logic Determination ---
if ((TOTAL_MEM_MB <= 8192)); then
	ZRAM_SIZE_VAL="ram"
	log_info "RAM is <= 8GB. Setting zram-size to full 'ram'."
else
	ZRAM_SIZE_VAL="ram - 2000"
	log_info "RAM is > 8GB. Setting zram-size to 'ram - 2000'."
fi

# --- 6. Write zram-generator config ---
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

# --- 7. Create OpenRC init script for zram-generator ---
# Since there is no zram-generator-openrc package, we create a service
# that runs zram-generator at boot and stops it on shutdown.

INIT_SCRIPT="/etc/init.d/zram-generator"

if [[ ! -f "${INIT_SCRIPT}" ]]; then
	log_info "Creating OpenRC init script for zram-generator..."

	cat >"${INIT_SCRIPT}" <<'OPENRC_EOF'
#!/sbin/openrc-run

name="zram-generator"
description="Create zram devices at boot"
command="/usr/bin/zram-generator"
command_args="--setup"
start_stop_daemon_args="--background"

depend() {
	need localmount
	before bootmisc
}

start_pre() {
	# zram-generator --setup reads /etc/systemd/zram-generator.conf
	# and creates the configured zram devices
	zram-generator --setup
}

stop() {
	# Swap off any zram swap devices before shutdown
	local zram_dev
	for zram_dev in /dev/zram*; do
		[[ -b "${zram_dev}" ]] || continue
		swapoff "${zram_dev}" 2>/dev/null || true
		# Reset the zram device
		echo 1 > "/sys/block/$(basename "${zram_dev}")/reset" 2>/dev/null || true
	done
}
OPENRC_EOF

	chmod +x "${INIT_SCRIPT}"
	log_success "Created ${INIT_SCRIPT}"
else
	log_info "OpenRC init script already exists: ${INIT_SCRIPT}"
fi

# --- 8. Enable the service ---
if rc-service -l 2>/dev/null | grep -q "^zram-generator$"; then
	rc-update add zram-generator boot 2>/dev/null || true
	log_success "zram-generator enabled at boot via OpenRC."
else
	log_warn "zram-generator init script not recognized by rc-service."
	log_info "You may need to run: rc-update add zram-generator boot"
fi

log_info "ZRAM configuration complete. Changes apply on next reboot."
