#!/usr/bin/env bash
# Bash 5.3+ | Snapper Subvolume Isolation and Limit Enforcement
set -Eeuo pipefail
export LC_ALL=C
trap 'echo -e "\n\033[1;31m[FATAL]\033[0m Script failed at line $LINENO. Command: $BASH_COMMAND" >&2' ERR

AUTO_MODE=false
[[ "${1:-}" == "--auto" ]] && AUTO_MODE=true

sudo -v || exit 1
( while true; do sudo -n -v 2>/dev/null; sleep 240; done ) &
SUDO_PID=$!
trap 'kill $SUDO_PID 2>/dev/null || true' EXIT

[[ "$(stat -f -c %T /)" == "btrfs" ]] || { echo "FATAL: Root filesystem is not BTRFS." >&2; exit 1; }

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

unmount_snapshots() {
    sudo umount /.snapshots 2>/dev/null || true
    sudo umount /home/.snapshots 2>/dev/null || true
    sudo rmdir /.snapshots /home/.snapshots 2>/dev/null || true
}
execute "Unmount existing snapshot directories" unmount_snapshots

create_configs() {
    sudo snapper -c root get-config &>/dev/null || sudo snapper -c root create-config /
    sudo snapper -c home get-config &>/dev/null || sudo snapper -c home create-config /home
}
execute "Generate default Snapper configs" create_configs

isolate_subvolumes() {
    # Validate required structures before destructive operations
    if ! grep -qE '^\s*[^#].*\s+/.snapshots\s+' /etc/fstab; then
        echo "FATAL: No fstab entry found for /.snapshots. Ensure @snapshots is mapped." >&2
        return 1
    fi

    for snap_dir in /.snapshots /home/.snapshots; do
        if mountpoint -q "$snap_dir" 2>/dev/null; then
            echo "INFO: $snap_dir is currently mounted. Skipping subvolume deletion to protect data."
            continue
        fi
        
        if sudo btrfs subvolume show "$snap_dir" &>/dev/null; then
            # Delete children via subvolid to bypass relative path VFS mangling
            sudo btrfs subvolume list -o "$snap_dir" | awk '{print $2}' | sort -rn | while IFS= read -r id; do
                [[ -n "$id" ]] && sudo btrfs subvolume delete --subvolid "$id" / 2>/dev/null || true
            done
            sudo btrfs subvolume delete "$snap_dir"
        fi
    done
    
    sudo mkdir -p /.snapshots /home/.snapshots
    
    sudo mount /.snapshots
    findmnt /home/.snapshots &>/dev/null || sudo mount /home/.snapshots 2>/dev/null || true
    
    if ! findmnt /.snapshots &>/dev/null; then
        echo "FATAL: /.snapshots mount failed." >&2
        return 1
    fi
    sudo chmod 750 /.snapshots
    findmnt /home/.snapshots &>/dev/null && sudo chmod 750 /home/.snapshots || true
}
execute "Destroy nested subvolumes and mount top-level @snapshots" isolate_subvolumes

tune_snapper() {
    for conf in root home; do
        if sudo snapper -c "$conf" get-config &>/dev/null; then
            # 0.0 floats explicitly required by newer snapper schemas
            sudo snapper -c "$conf" set-config TIMELINE_CREATE="no" NUMBER_LIMIT="10" NUMBER_LIMIT_IMPORTANT="5" SPACE_LIMIT="0.0" FREE_LIMIT="0.0"
        fi
    done
    sudo btrfs quota disable / 2>/dev/null || true
}
execute "Enforce count-based retention limits" tune_snapper

configure_snap_pac() {
    if [[ -f /etc/snap-pac.ini ]] && sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '.'; then
        if sed -n '/^\[home\]/,/^\[/p' /etc/snap-pac.ini | grep -q '^\s*snapshot\s*='; then
            sudo sed -i '/^\[home\]/,/^\[/{s/^\s*snapshot\s*=.*/snapshot = no/}' /etc/snap-pac.ini
        else
            sudo sed -i '/^\[home\]/a snapshot = no' /etc/snap-pac.ini
        fi
    else
        printf '\n[home]\nsnapshot = no\n' | sudo tee -a /etc/snap-pac.ini >/dev/null
    fi
}
execute "Configure snap-pac to ignore /home" configure_snap_pac

enable_timers() {
    sudo systemctl disable --now snapper-timeline.timer 2>/dev/null || true
    sudo systemctl enable --now snapper-cleanup.timer
}
execute "Enable Snapper cleanup timer" enable_timers
