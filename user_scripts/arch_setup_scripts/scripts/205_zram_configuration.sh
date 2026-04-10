#!/usr/bin/env bash
# Zram Configuration for OpenRC
# -----------------------------------------------------------------------------
# Elite Artix Linux ZRAM Configurator
# Context: Hyprland / OpenRC Environment
# Logic: Dynamic configuration based on available RAM (<=8GB vs >8GB)
# -----------------------------------------------------------------------------

# strict mode
set -euo pipefail

# --- Styles ---
BOLD=$'\033[1m'
GREEN=$'\033[32m'
BLUE=$'\033[34m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
NC=$'\033[0m' # No Color

# --- 1. Root Privilege Escalation ---
if [[ $EUID -ne 0 ]]; then
	printf "${YELLOW}[Info] script not run as root. Escalating privileges...${NC}\n"
	exec sudo "$0" "$@"
fi

# --- 2. Setup Variables ---
CONFIG_FILE="/etc/systemd/zram-generator.conf"
MOUNT_POINT="/mnt/zram1"

log_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}[SUCCESS]${NC} %s\n" "$1"; }
log_err() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; }

# --- 3. Memory Calculation (Pure Bash) ---
while read -r key value unit; do
	if [[ "$key" == "MemTotal:" ]]; then
		TOTAL_MEM_KB=$value
		break
	fi
done </proc/meminfo

TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))

log_info "Detected System RAM: ${TOTAL_MEM_MB} MB"

# --- 4. Logic Determination ---
if ((TOTAL_MEM_MB <= 8192)); then
	ZRAM_SIZE_VAL="ram"
	log_info "RAM is <= 8GB. Setting zram-size to full 'ram'."
else
	ZRAM_SIZE_VAL="ram - 2000"
	log_info "RAM is > 8GB. Setting zram-size to 'ram - 2000'."
fi

# --- 5. Execution ---

if [[ ! -d "$MOUNT_POINT" ]]; then
	mkdir -p "$MOUNT_POINT"
	log_info "Created mount point: $MOUNT_POINT"
fi

cat >"$CONFIG_FILE" <<EOF
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

log_info "ZRAM configuration complete. Changes apply on next reboot."
