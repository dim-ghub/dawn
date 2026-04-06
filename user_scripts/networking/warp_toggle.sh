#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: warp-toggle.sh
# Description: Robust toggle for Cloudflare WARP with UWSM/Hyprland notifications.
#              Automatically handles TOS acceptance if pending.
#              Soft-fails if WARP is not installed (prevents orchestrator errors).
#              also supports --disconnect and --connect flags
#              Maintains state file at ~/.config/dawn/settings/warp_state
# Author: Elite DevOps
# Environment: Arch Linux / Hyprland / UWSM
# Dependencies: warp-cli, libnotify (notify-send) [optional], util-linux (script)
# -----------------------------------------------------------------------------

# --- Strict Mode ---
set -euo pipefail

# --- Configuration ---
readonly APP_NAME="Cloudflare WARP"
readonly TIMEOUT_SEC=10
readonly ICON_CONN="network-vpn"
readonly ICON_DISC="network-offline"
readonly ICON_WAIT="network-transmit-receive"
readonly ICON_ERR="dialog-error"
readonly STATE_FILE="$HOME/.config/dawn/settings/warp_state"

# --- Runtime Checks ---
# Cache notify-send availability
HAS_NOTIFY=0
command -v notify-send &>/dev/null && HAS_NOTIFY=1
readonly HAS_NOTIFY

# --- Styling ---
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m' C_BOLD=$'\033[1m'
    readonly C_GREEN=$'\033[1;32m' C_BLUE=$'\033[1;34m'
    readonly C_RED=$'\033[1;31m' C_YELLOW=$'\033[1;33m'
else
    readonly C_RESET='' C_BOLD='' C_GREEN='' C_BLUE='' C_RED='' C_YELLOW=''
fi

# --- Logging ---
log_info()    { printf "%s[INFO]%s %s\n" "$C_BLUE" "$C_RESET" "${1:-}"; }
log_success() { printf "%s[OK]%s   %s\n" "$C_GREEN" "$C_RESET" "${1:-}"; }
log_warn()    { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "${1:-}" >&2; }
log_error()   { printf "%s[ERR]%s  %s\n" "$C_RED" "$C_RESET" "${1:-}" >&2; }

# --- State Management ---
update_state_file() {
    local state="${1:-False}"
    local dir
    dir=$(dirname "$STATE_FILE")
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
    
    # Write atomically to avoid race conditions with bar/widgets reading it
    echo "$state" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- Notification Helper ---
notify_user() {
    (( HAS_NOTIFY )) || return 0
    local title="${1:-Notification}"
    local message="${2:-}"
    local urgency="${3:-low}"
    local icon="${4:-$ICON_WAIT}"
    notify-send -u "$urgency" -a "$APP_NAME" -i "$icon" -- "$title" "$message" 2>/dev/null || true
}

# --- Core Logic ---

ensure_tos_accepted() {
    # Check 1: Does 'warp-cli status' run cleanly and output "Status update"?
    # If it fails (exit code != 0) OR doesn't contain "Status update", we assume TOS is blocking.
    if ! warp-cli status 2>&1 | grep -q "Status update"; then
        log_info "Valid status not found (Possible pending TOS). Attempting auto-acceptance..."

        # Temporarily disable pipefail so 'echo' closing the pipe doesn't crash the script
        set +o pipefail
        
        # PTY TRICK: Emulate a terminal using 'script' so warp-cli accepts the piped 'y'
        # We redirect all output to /dev/null to keep it clean
        if { sleep 0.5; echo "y"; } | script -q -c "warp-cli status" /dev/null >/dev/null 2>&1; then
            log_success "TOS acceptance sequence completed."
        else
            log_warn "TOS acceptance sequence ran but returned an error."
        fi
        
        set -o pipefail
    fi
}

get_warp_status() {
    local output status
    # Capture stderr too just in case, but we mainly want stdout
    output=$(warp-cli status 2>&1) || return 1
    
    # Check if the command actually gave us a status update
    if [[ ! "$output" =~ "Status update" ]]; then
        return 1
    fi

    # Robust awk to extract the status value
    status=$(awk -F': ' '/Status update/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
        print $2
        exit
    }' <<< "$output")

    if [[ -n "$status" ]]; then
        printf '%s' "$status"
        return 0
    fi
    return 1
}

wait_for_connection() {
    local timer=0 
    local current_state
    
    log_info "Initiating connection sequence..."
    notify_user "Connecting..." "Establishing secure tunnel." "normal" "$ICON_WAIT"

    if ! warp-cli connect &>/dev/null; then
        log_error "Failed to send connect command."
        notify_user "Error" "Failed to send connect command." "critical" "$ICON_ERR"
        # Ensure state reflects failure (disconnected)
        update_state_file "False"
        return 1
    fi

    while (( timer < TIMEOUT_SEC )); do
        current_state=$(get_warp_status) || current_state="Unknown"

        if [[ "$current_state" == "Connected" ]]; then
            log_success "WARP is now Connected."
            notify_user "Connected" "Secure tunnel active." "normal" "$ICON_CONN"
            update_state_file "True"
            return 0
        fi

        sleep 1
        (( ++timer ))
    done

    log_error "Connection timed out after ${TIMEOUT_SEC}s."
    notify_user "Timeout" "Failed to connect within ${TIMEOUT_SEC} seconds." "critical" "$ICON_ERR"
    # Ensure state reflects failure/unknown
    update_state_file "False"
    return 1
}

disconnect_warp() {
    log_info "Disconnecting..."
    if warp-cli disconnect &>/dev/null; then
        log_success "Disconnected successfully."
        notify_user "Disconnected" "Secure tunnel closed." "low" "$ICON_DISC"
        update_state_file "False"
        return 0
    else
        log_error "Failed to disconnect."
        notify_user "Error" "Failed to disconnect WARP." "critical" "$ICON_ERR"
        # We don't update state to False here because the disconnect failed
        return 1
    fi
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTIONS]

Options:
  (no args)      Toggle connection state
  --connect      Force connection (idempotent)
  --disconnect   Force disconnection (idempotent)
  -h, --help     Show this message
EOF
}

main() {
    # 1. Dependency Check (Soft Fail)
    # If warp-cli is missing, warn and exit 0 to keep orchestrator happy.
    if ! command -v warp-cli &>/dev/null; then
        log_warn "warp-cli not found. Skipping WARP toggle."
        exit 0
    fi

    # 2. Ensure TOS is accepted BEFORE checking status
    ensure_tos_accepted

    # 3. Argument Parsing
    local action="toggle"
    while (( $# > 0 )); do
        case "$1" in
            --connect)    action="connect" ;;
            --disconnect) action="disconnect" ;;
            -h|--help)    show_help; exit 0 ;;
            *)            log_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
        shift
    done

    # 4. Get Status
    local status
    status=$(get_warp_status) || status="Unknown"

    # 5. Execution Logic
    case "$action" in
        "connect")
            if [[ "$status" == "Connected" ]]; then
                log_success "Already Connected. No action taken."
                # Ensure state file is synced even if no action taken
                update_state_file "True"
            else
                wait_for_connection
            fi
            ;;
        "disconnect")
            if [[ "$status" == "Disconnected" ]]; then
                log_success "Already Disconnected. No action taken."
                # Ensure state file is synced even if no action taken
                update_state_file "False"
            else
                disconnect_warp
            fi
            ;;
        "toggle")
            log_info "Current Status: ${C_BOLD}${status}${C_RESET}"
            case "$status" in
                "Connected"|"Connecting")
                    disconnect_warp
                    ;;
                "Disconnected")
                    wait_for_connection
                    ;;
                *)
                    log_warn "Unknown status detected: '$status'. Attempting to connect."
                    wait_for_connection
                    ;;
            esac
            ;;
    esac
}

main "$@"
