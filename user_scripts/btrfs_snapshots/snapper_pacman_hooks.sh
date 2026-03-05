#!/usr/bin/env bash
# Bash 5.3+ | Kernel Backup and EFI Sync Hooks
set -Eeuo pipefail
export LC_ALL=C
trap 'echo -e "\n\033[1;31m[FATAL]\033[0m Script failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || exit 1
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

execute() {
    local desc="$1"
    shift
    if [[ "$AUTO_MODE" == true ]]; then
        "$@"
    else
        printf '\n\033[1;34m[ACTION]\033[0m %s\n' "$desc"
        read -rp "Execute this step? [Y/n] " response || { echo -e "\nInput closed; aborting." >&2; exit 1; }
        if [[ "${response,,}" =~ ^(n|no)$ ]]; then echo "Skipped."; return 0; fi
        "$@"
    fi
}

execute "Create Pacman hook directory" sudo mkdir -p /etc/pacman.d/hooks

create_kernel_hook() {
    # Uses a robust staging and pair-rollback mechanism to prevent mismatched kernels
    cat << 'EOF' | sudo tee /etc/pacman.d/hooks/50-kernel-backup.hook >/dev/null
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = linux
Target = *-ucode

[Action]
Description = Backing up matched kernel/initramfs/microcode...
When = PreTransaction
Exec = /usr/bin/bash -c 'set -Eeuo pipefail; shopt -s nullglob; files=(/boot/vmlinuz-linux /boot/initramfs-linux.img /boot/*-ucode.img); [[ -f /boot/vmlinuz-linux && -f /boot/initramfs-linux.img ]] || exit 0; for f in "${files[@]}"; do cp "$f" "$f.tmp"; done; sync; for f in "${files[@]}"; do [[ -f "${f%/*}/${f##*/}-previous" ]] && cp "${f%/*}/${f##*/}-previous" "${f%/*}/${f##*/}-previous.bak"; done; has_err=0; for f in "${files[@]}"; do if ! mv "$f.tmp" "${f%/*}/${f##*/}-previous"; then has_err=1; break; fi; done; if (( has_err )); then echo "FATAL: Partial rename failure. Rolling back." >&2; for f in "${files[@]}"; do [[ -f "${f%/*}/${f##*/}-previous.bak" ]] && mv "${f%/*}/${f##*/}-previous.bak" "${f%/*}/${f##*/}-previous" 2>/dev/null || true; done; rm -f /boot/*.tmp /boot/*.bak; exit 1; fi; rm -f /boot/*.bak; sync; echo "Matched Kernel/Microcode backup complete."'
EOF
}
execute "Deploy safe, atomic-staged Kernel backup hook" create_kernel_hook

create_limine_hook() {
    cat << 'EOF' | sudo tee /etc/pacman.d/hooks/limine-update.hook >/dev/null
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = limine

[Action]
Description = Deploying updated Limine EFI binary to ESP...
When = PostTransaction
Depends = limine
Exec = /usr/bin/bash -c 'cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI.tmp && sync && mv /boot/EFI/BOOT/BOOTX64.EFI.tmp /boot/EFI/BOOT/BOOTX64.EFI && sync || { rm -f /boot/EFI/BOOT/BOOTX64.EFI.tmp; echo "FATAL: Limine EFI update failed." >&2; }'
EOF
}
execute "Deploy Limine update sync hook" create_limine_hook

enable_sync() {
    local unit=""
    if systemctl list-unit-files 'limine-snapper-sync.path' --no-legend | grep -q .; then
        unit="limine-snapper-sync.path"
    elif systemctl list-unit-files 'limine-snapper-sync.service' --no-legend | grep -q .; then
        unit="limine-snapper-sync.service"
    fi
    [[ -n "$unit" ]] || { echo "FATAL: limine-snapper-sync unit not found." >&2; return 1; }
    sudo systemctl enable --now "$unit"
}
execute "Enable the limine-snapper-sync daemon" enable_sync
