#!/usr/bin/env bash
#
# performance_toggle.sh (v5.1 - Elite Edition)
#
# A hyper-reliable, Bash 5.0+ utility to terminate Wayland/Hyprland resources.
# Engineered for absolute state correctness, race-condition immunity, and safety.
#
# Requirements: bash 5.0+, gum, sudo, systemd, procps-ng, awk
#

# --- STRICT MODE ---
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# --- BASH 5.0+ ENFORCEMENT ---
if ((BASH_VERSINFO[0] < 5)); then
    printf 'Error: Execution halted. Bash 5.0+ required (found %s)\n' "$BASH_VERSION" >&2
    exit 1
fi

AUTO_MODE=false
if [[ "${1:-}" == "--auto" ]]; then
    AUTO_MODE=true
fi

# --- HEADLESS-SAFE TRAP ---
_cleanup() {
    local exit_code=$?
    trap - ERR EXIT

    if [[ "${1:-}" == "error" ]]; then
        printf '\n\033[1;31mFATAL: Execution failed on line %s (exit code: %d)\033[0m\n' \
            "${2:-unknown}" "$exit_code" >&2

        # Strict TTY validation prevents headless hanging in UWSM/keybind execution
        if [[ "$AUTO_MODE" != true && -r /dev/tty && -w /dev/tty ]]; then
            printf 'Press Enter to exit...' >/dev/tty
            read -r </dev/tty || true
        fi
    fi
}
trap '_cleanup error "$LINENO"' ERR
trap '_cleanup' EXIT

# --- RESOURCE CONFIGURATION ---

declare -ra DEFAULT_PROCESSES=("hyprsunset" "awww-daemon" "waybar" "blueman-manager")
declare -ra OPTIONAL_PROCESSES=("inotifywait" "wl-paste" "wl-copy" "firefox" "discord")

declare -ra DEFAULT_SYSTEM_SERVICES=("firewalld" "vsftpd" "waydroid-container" "logrotate.timer" "sshd")
declare -ra OPTIONAL_SYSTEM_SERVICES=("udisks2" "swayosd-libinput-backend" "warp-svc" "NetworkManager")

declare -ra DEFAULT_USER_SERVICES=("battery_notify" "blueman-applet" "hypridle" "hyprpolkitagent" "swaync" "gvfs-daemon" "waybar" "blueman-manager" "gvfs-metadata" "network_meter" "dusky_sliders" "dusky")
declare -ra OPTIONAL_USER_SERVICES=("gnome-keyring-daemon" "swayosd-server" "pipewire-pulse.socket" "pipewire.socket" "wireplumber" "pipewire")

declare -ra DEFAULT_SCRIPTS=("dusky_main.py" "dusky_stt_main.py")
declare -ra OPTIONAL_SCRIPTS=()

# --- DEPENDENCY VALIDATION ---
for dep in gum awk pgrep ps systemctl; do
    if ! command -v "$dep" &>/dev/null; then
        printf 'Error: Required dependency "%s" is missing.\n' "$dep" >&2
        exit 1
    fi
done

# --- CORE ENGINEERING FUNCTIONS ---

contains_element() {
    local match="$1"; shift
    local e
    for e in "$@"; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

# Safely identifies script PIDs. 
# Uses `-ww` to prevent line truncation. Filters out text editors/pagers from the `comm` field
# to prevent collateral damage (e.g., won't kill `nano dusky_main.py`).
get_script_pids() {
    local target="$1"
    local mypid="$$"
    
    ps -ww -eo pid=,comm=,args= | awk -v tgt="$target" -v me="$mypid" '
        $1 != me && index($0, tgt) {
            # If the executing binary is an editor or pager, ignore it.
            if ($2 ~ /^(nano|vim|vi|nvim|cat|less|more|tail|head|grep|awk)$/) next;
            print $1
        }
    '
}

is_active() {
    local name="$1" type="$2"
    case "$type" in
        proc)   pgrep -x "$name" &>/dev/null ;;
        sys)    systemctl is-active --quiet "$name" 2>/dev/null ;;
        user)   systemctl --user is-active --quiet "$name" 2>/dev/null ;;
        script) 
            local pids
            pids=$(get_script_pids "$name")
            [[ -n "$pids" ]]
            ;;
        *) return 1 ;;
    esac
}

gather_candidates() {
    local item
    for item in "${DEFAULT_PROCESSES[@]}" "${OPTIONAL_PROCESSES[@]}"; do
        is_active "$item" "proc" && printf 'proc:%s|%s (Process)\n' "$item" "$item"
    done
    for item in "${DEFAULT_SYSTEM_SERVICES[@]}" "${OPTIONAL_SYSTEM_SERVICES[@]}"; do
        is_active "$item" "sys" && printf 'sys:%s|%s (System Svc)\n' "$item" "$item"
    done
    for item in "${DEFAULT_USER_SERVICES[@]}" "${OPTIONAL_USER_SERVICES[@]}"; do
        is_active "$item" "user" && printf 'user:%s|%s (User Svc)\n' "$item" "$item"
    done
    for item in "${DEFAULT_SCRIPTS[@]}" "${OPTIONAL_SCRIPTS[@]}"; do
        is_active "$item" "script" && printf 'script:%s|%s (Script)\n' "$item" "$item"
    done
    return 0 # CRITICAL: Guarantees idempotence by overriding the last loop's short-circuit exit code.
}

is_default_item() {
    local name="$1" type="$2"
    case "$type" in
        proc)   contains_element "$name" "${DEFAULT_PROCESSES[@]}" ;;
        sys)    contains_element "$name" "${DEFAULT_SYSTEM_SERVICES[@]}" ;;
        user)   contains_element "$name" "${DEFAULT_USER_SERVICES[@]}" ;;
        script) contains_element "$name" "${DEFAULT_SCRIPTS[@]}" ;;
        *) return 1 ;;
    esac
}

# Unified PID tracking. Solves respawn race conditions by tracking the EXACT PIDs 
# grabbed at the moment of execution, utilizing native `kill -0` syscalls.
terminate_pids() {
    local -n target_pids=$1
    if ((${#target_pids[@]} == 0)); then return 0; fi

    kill -- "${target_pids[@]}" 2>/dev/null || true

    local i p
    local -a remaining_pids
    
    for i in {1..20}; do
        remaining_pids=()
        for p in "${target_pids[@]}"; do
            if kill -0 "$p" 2>/dev/null; then
                remaining_pids+=("$p")
            fi
        done
        
        # If the remaining list is empty, all processes have successfully died.
        ((${#remaining_pids[@]} == 0)) && return 0
        sleep 0.1
    done

    # Escalation: Force kill only the stubborn survivors
    kill -9 -- "${remaining_pids[@]}" 2>/dev/null || true
    sleep 0.3

    # Final Verification
    for p in "${remaining_pids[@]}"; do
        if kill -0 "$p" 2>/dev/null; then return 1; fi
    done
    return 0
}

perform_stop() {
    local type="$1" name="$2"
    local -a pids=()

    case "$type" in
        proc)
            mapfile -t pids < <(pgrep -x "$name" 2>/dev/null || true)
            terminate_pids pids
            ;;
        script)
            mapfile -t pids < <(get_script_pids "$name")
            terminate_pids pids
            ;;
        sys)
            if ! { ((EUID == 0)) && systemctl stop "$name" || sudo systemctl stop "$name"; } 2>/dev/null; then
                [[ "$(systemctl show --value --property LoadState "$name" 2>/dev/null || true)" == "not-found" ]] && printf 'Warning: Unit %s not found\n' "$name" >&2
                return 1
            fi
            sleep 0.2; ! is_active "$name" "sys"
            ;;
        user)
            if ! systemctl --user stop "$name" 2>/dev/null; then return 1; fi
            sleep 0.2; ! is_active "$name" "user"
            ;;
        *) return 1 ;;
    esac
}

# --- EXECUTION PIPELINE ---

mapfile -t CANDIDATES < <(gather_candidates)

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    gum style --border normal --padding "1 2" --border-foreground 212 "System Clean" "All monitored targets are inactive."
    printf '\n'
    trap - ERR EXIT
    [[ "$AUTO_MODE" == true ]] && exit 0
    exec "${SHELL:-/bin/bash}"
fi

declare -a SELECTED_ITEMS=()

if [[ "$AUTO_MODE" == true ]]; then
    for line in "${CANDIDATES[@]}"; do
        data="${line%%|*}" type="${data%%:*}" name="${data#*:}"
        is_default_item "$name" "$type" && SELECTED_ITEMS+=("$data")
    done
else
    declare -a OPTIONS_DISPLAY=() PRE_SELECTED_DISPLAY=()
    declare -A DATA_MAP=()

    for line in "${CANDIDATES[@]}"; do
        data="${line%%|*}" display="${line#*|}" type="${data%%:*}" name="${data#*:}"
        OPTIONS_DISPLAY+=("$display")
        DATA_MAP["$display"]="$data"
        is_default_item "$name" "$type" && PRE_SELECTED_DISPLAY+=("$display")
    done

    PRE_SELECTED_STR=$(IFS=,; printf '%s' "${PRE_SELECTED_DISPLAY[*]}")

    gum style --border double --padding "1 2" --border-foreground 57 "Performance Terminator"

    SELECTION_RESULT=$(gum choose --no-limit --height 15 --header "Select resources to FREE. (SPACE: toggle, ENTER: confirm)" --selected="$PRE_SELECTED_STR" "${OPTIONS_DISPLAY[@]}" || true)
    
    [[ -z "$SELECTION_RESULT" ]] && { printf 'Cancelled.\n'; exit 0; }

    while IFS= read -r line; do
        [[ -n "$line" ]] && SELECTED_ITEMS+=("${DATA_MAP[$line]}")
    done <<< "$SELECTION_RESULT"
fi

[[ ${#SELECTED_ITEMS[@]} -eq 0 ]] && { trap - ERR EXIT; [[ "$AUTO_MODE" == true ]] && exit 0; exec "${SHELL:-/bin/bash}"; }

# Sudo Authentication
for item in "${SELECTED_ITEMS[@]}"; do
    if [[ "$item" == sys:* && $EUID -ne 0 ]]; then
        printf 'System services selected. Authenticating...\n'
        ! sudo -v && { gum style --foreground 196 "Auth failed. Aborting."; exit 1; }
        break
    fi
done

declare -a SUCCESS_LIST=() FAIL_LIST=()
printf '\n'; gum style --bold "Terminating selected targets..."

for item in "${SELECTED_ITEMS[@]}"; do
    type="${item%%:*}" name="${item#*:}"
    printf ' • Stopping %s...' "$name"
    if perform_stop "$type" "$name"; then
        printf '\r \033[0;32m✔\033[0m Stopped %s     \n' "$name"
        SUCCESS_LIST+=("$type: $name")
    else
        printf '\r \033[0;31m✘\033[0m Failed %s      \n' "$name"
        FAIL_LIST+=("$type: $name")
    fi
done

REPORT=""
[[ ${#SUCCESS_LIST[@]} -gt 0 ]] && { REPORT+="$(gum style --foreground 82 "✔ Successfully Stopped:")\n"; for item in "${SUCCESS_LIST[@]}"; do REPORT+="  $item\n"; done; REPORT+="\n"; }
[[ ${#FAIL_LIST[@]} -gt 0 ]] && { REPORT+="$(gum style --foreground 196 "✘ Failed to Stop (Still Active):")\n"; for item in "${FAIL_LIST[@]}"; do REPORT+="  $item\n"; done; REPORT+="\n"; }

[[ "$AUTO_MODE" != true && -t 1 && -n "${TERM:-}" ]] && clear
gum style --border double --padding "1 2" --border-foreground 57 "Execution Complete"
printf '%b' "$REPORT"

trap - ERR EXIT

if [[ "$AUTO_MODE" == true ]]; then
    [[ ${#FAIL_LIST[@]} -gt 0 ]] && exit 1
    exit 0
fi

printf '%s\n' "-----------------------------------------------------"
printf '%s\n' "Session Active. Type 'exit' to close."
exec "${SHELL:-/bin/bash}"
