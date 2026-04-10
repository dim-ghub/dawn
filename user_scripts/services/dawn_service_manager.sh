#!/usr/bin/env bash
#===============================================================================
# DESCRIPTION:  Idempotent Declarative Unit State Manager (System & User scopes)
# PLATFORM:     Arch Linux · Wayland / Hyprland · systemd
# REQUIRES:     Bash 5.3+, systemctl, loginctl, runuser, id, flock
# USAGE:        ./sync-services.sh [--dry-run|--check]
#===============================================================================

# ── Resolve Absolute Script Path ─────────────────────────────────────────────
readonly SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# ── Privilege Escalation ─────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "${SCRIPT_PATH}" "$@"
    printf 'FATAL: Failed to escalate privileges via sudo.\n' >&2
    exit 1
fi

# ── Bash Version Enforcement ─────────────────────────────────────────────────
if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3) )); then
    printf 'FATAL: This script requires Bash 5.3 or higher.\n' >&2
    exit 1
fi

# ── Strict Mode ──────────────────────────────────────────────────────────────
set -euo pipefail

# ── Argument Parsing ─────────────────────────────────────────────────────────
DRY_RUN=0
while (( $# )); do
    case "$1" in
        --dry-run|--check) DRY_RUN=1; shift ;;
        -h|--help)
            printf 'Usage: %s [--dry-run|--check]\n' "${SCRIPT_PATH##*/}"
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\nUsage: %s [--dry-run|--check]\n' "$1" "${SCRIPT_PATH##*/}" >&2
            exit 1
            ;;
    esac
done
readonly DRY_RUN

# ── TTY-Aware ANSI Formatting ────────────────────────────────────────────────
if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' BLUE=$'\033[0;34m' RESET=$'\033[0m'
else
    readonly RED='' GREEN='' YELLOW='' BLUE='' RESET=''
fi

# ── Logging (Literal Format Strings) ─────────────────────────────────────────
log_info()    { printf '%s[INFO]%s    %s\n'    "${BLUE}"   "${RESET}" "$1"; }
log_success() { printf '%s[SUCCESS]%s %s\n'    "${GREEN}"  "${RESET}" "$1"; }
log_warn()    { printf '%s[WARN]%s    %s\n'    "${YELLOW}" "${RESET}" "$1"; }
log_error()   { printf '%s[ERROR]%s   %s\n'    "${RED}"    "${RESET}" "$1" >&2; }

# ── Dependency Validation ────────────────────────────────────────────────────
readonly REQUIRED_BINS=(systemctl loginctl runuser id flock)
for _bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "${_bin}" >/dev/null 2>&1; then
        log_error "Required binary '${_bin}' not found in PATH. Execution halted."
        exit 1
    fi
done
unset _bin

# ── Concurrency Guard ────────────────────────────────────────────────────────
readonly LOCK_FILE='/run/service-manager.lock'
exec 9>"${LOCK_FILE}" || {
    log_error "Cannot create lock file: ${LOCK_FILE}"
    exit 1
}
if ! flock -n 9; then
    log_error "Another instance is already running. Exiting."
    exit 1
fi

# ==============================================================================
# DECLARATIVE STATE CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
# Values: "true" = enable & start  |  "false" = disable & stop
# ==============================================================================

declare -A SYSTEM_SERVICES=(
#    eg:
#    ["NetworkManager.service"]="true"
#    ["bluetooth.service"]="true"


)

declare -A USER_SERVICES=(
#    eg:
#    ["hyprpaper.service"]="true"
#    ["waybar.service"]="true"

    ["hyprsunset.service"]="false"
)

# ==============================================================================
# WAYLAND / SYSTEMD ENVIRONMENT RESOLUTION
# ==============================================================================

ACTIVE_SESSION="$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null || true)"

if [[ -z "${ACTIVE_SESSION}" ]]; then
    while read -r _sid _rest; do
        [[ -z "${_sid}" ]] && continue
        _state="$(loginctl show-session "${_sid}" -p State --value 2>/dev/null || true)"
        if [[ "${_state}" == "active" ]]; then
            ACTIVE_SESSION="${_sid}"
            break
        fi
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
    unset _sid _rest _state
fi

ACTIVE_USER=''
ACTIVE_UID=''
USER_SESSION_AVAILABLE=0

if [[ -n "${ACTIVE_SESSION}" ]]; then
    ACTIVE_USER="$(loginctl show-session "${ACTIVE_SESSION}" -p Name --value 2>/dev/null || true)"
    if [[ -n "${ACTIVE_USER}" ]]; then
        ACTIVE_UID="$(id -u "${ACTIVE_USER}" 2>/dev/null || true)"
    fi
fi

if [[ -n "${ACTIVE_UID}" && -S "/run/user/${ACTIVE_UID}/bus" ]]; then
    USER_SESSION_AVAILABLE=1
fi

readonly ACTIVE_SESSION ACTIVE_USER ACTIVE_UID USER_SESSION_AVAILABLE

# ==============================================================================
# GLOBAL STATE & HELPERS
# ==============================================================================

COUNT_CHANGED=0
COUNT_OK=0
COUNT_SKIPPED=0
COUNT_FAILED=0

_load_state='not-found'
_file_state='unknown'
_active_state='unknown'

refresh_unit_state() {
    local _service=$1; shift

    _load_state='not-found'
    _file_state='unknown'
    _active_state='unknown'

    local _key _val
    while IFS='=' read -r _key _val; do
        case "${_key}" in
            LoadState)     _load_state="${_val}" ;;
            UnitFileState) _file_state="${_val}" ;;
            ActiveState)   _active_state="${_val}" ;;
        esac
    done < <("$@" show -p LoadState,UnitFileState,ActiveState -- "${_service}" 2>/dev/null)
}

run_action() {
    local description=$1; shift

    if (( DRY_RUN )); then
        log_info "[DRY-RUN] Would: ${description}"
        (( COUNT_CHANGED += 1 ))
        return 0
    fi

    local err_out
    if err_out=$("$@" 2>&1); then
        log_success "${description}"
        (( COUNT_CHANGED += 1 ))
    else
        log_error "Failed: ${description}: ${err_out}"
        (( COUNT_FAILED += 1 ))
    fi
    return 0
}

# ==============================================================================
# CORE ENGINE
# ==============================================================================

sync_unit() {
    local scope=$1 service=$2 target_state=$3
    local -a cmd_prefix

    if [[ "${target_state}" != "true" && "${target_state}" != "false" ]]; then
        log_warn "Invalid state '${target_state}' for ${service}. Must be 'true' or 'false'. Skipping."
        (( COUNT_SKIPPED += 1 ))
        return 0
    fi

    if [[ "${scope}" == "user" ]]; then
        cmd_prefix=(
            runuser -u "${ACTIVE_USER}" --
            env "XDG_RUNTIME_DIR=/run/user/${ACTIVE_UID}"
                "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${ACTIVE_UID}/bus"
            systemctl --user --no-pager --no-ask-password
        )
    else
        cmd_prefix=(systemctl --system --no-pager --no-ask-password)
    fi

    refresh_unit_state "${service}" "${cmd_prefix[@]}"
    local load_state="${_load_state}"
    local file_state="${_file_state}"
    local active_state="${_active_state}"

    if [[ "${load_state}" == "not-found" ]]; then
        log_warn "Unit ${service} (${scope}) not found — verify the name and that the package is installed."
        (( COUNT_SKIPPED += 1 ))
        return 0
    fi

    # ══════════════════════════════════════════════════════════════════════
    # TARGET STATE: TRUE  →  Enable & Start
    # ══════════════════════════════════════════════════════════════════════
    if [[ "${target_state}" == "true" ]]; then

        # [cite_start]Covers "masked" and "masked-runtime" [cite: 287, 288]
        if [[ "${file_state}" == masked* ]]; then
            if (( DRY_RUN )); then
                log_info "[DRY-RUN] Would unmask ${scope} unit: ${service}"
                (( COUNT_CHANGED += 1 ))
                file_state='disabled'
            else
                if "${cmd_prefix[@]}" unmask -- "${service}" >/dev/null 2>&1; then
                    log_success "Unmasked ${scope} unit: ${service}"
                    (( COUNT_CHANGED += 1 ))
                else
                    log_error "Failed to unmask ${service}. Skipping."
                    (( COUNT_FAILED += 1 ))
                    return 0
                fi
                refresh_unit_state "${service}" "${cmd_prefix[@]}"
                file_state="${_file_state}"
                active_state="${_active_state}"
            fi
        fi

        local needs_enable=0
        case "${file_state}" in
            # [cite_start]linked-runtime added to catch transient symlinks in /run/systemd/system/ [cite: 283, 284]
            disabled|bad|linked|linked-runtime)
                needs_enable=1
                ;;
            # [cite_start]alias, transient, static, indirect, generated states where [Install] enable is not applicable [cite: 286, 289, 291, 299, 302, 304]
            static|indirect|generated|transient|alias)
                log_info "${service} (${file_state}) — enable not applicable; managing active state only."
                ;;
            enabled|enabled-runtime)
                ;;
            *)
                log_warn "${service} has unexpected file state '${file_state}'."
                ;;
        esac

        local needs_start=0
        # [cite_start]Active states to consider "running": active, activating, reloading, and refreshing [cite: 24, 28, 31, 32]
        if [[ "${active_state}" != "active"     \
           && "${active_state}" != "activating" \
           && "${active_state}" != "reloading"  \
           && "${active_state}" != "refreshing" ]]; then
            needs_start=1
        fi

        if (( needs_enable && needs_start )); then
            run_action "Enable and start ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" enable --now -- "${service}"
        elif (( needs_enable )); then
            run_action "Enable ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" enable -- "${service}"
        elif (( needs_start )); then
            run_action "Start ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" start -- "${service}"
        else
            log_info "${service} is already enabled and active."
            (( COUNT_OK += 1 ))
        fi

    # ══════════════════════════════════════════════════════════════════════
    # TARGET STATE: FALSE  →  Disable & Stop
    # ══════════════════════════════════════════════════════════════════════
    else
        local needs_disable=0
        # [cite_start]Ensure symlinked (linked/linked-runtime) units are properly captured and destroyed on disable [cite: 281, 283, 284]
        if [[ "${file_state}" == enabled* || "${file_state}" == linked* ]]; then
            needs_disable=1
        fi

        local needs_stop=0
        # [cite_start]If the unit is active, activating, reloading, or refreshing, we must stop it [cite: 24, 28, 31, 32]
        if [[ "${active_state}" == "active"     \
           || "${active_state}" == "activating" \
           || "${active_state}" == "reloading"  \
           || "${active_state}" == "refreshing" ]]; then
            needs_stop=1
        fi

        if (( needs_disable && needs_stop )); then
            run_action "Disable and stop ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" disable --now -- "${service}"
        elif (( needs_disable )); then
            run_action "Disable ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" disable -- "${service}"
        elif (( needs_stop )); then
            run_action "Stop ${scope} unit: ${service}" \
                "${cmd_prefix[@]}" stop -- "${service}"
        else
            log_info "${service} is already disabled and inactive."
            (( COUNT_OK += 1 ))
        fi
    fi
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    if (( DRY_RUN )); then
        log_info "Running in DRY-RUN mode — no changes will be applied."
        printf '\n'
    fi

    log_info "Synchronizing system-level units..."
    for svc in "${!SYSTEM_SERVICES[@]}"; do
        sync_unit "system" "${svc}" "${SYSTEM_SERVICES[${svc}]}"
    done

    printf '\n'

    log_info "Synchronizing user-level units..."
    if (( USER_SESSION_AVAILABLE )); then
        for svc in "${!USER_SERVICES[@]}"; do
            sync_unit "user" "${svc}" "${USER_SERVICES[${svc}]}"
        done
    else
        log_warn "No active Wayland user session detected. Skipping all user-scope units."
        COUNT_SKIPPED=$(( COUNT_SKIPPED + ${#USER_SERVICES[@]} ))
    fi

    printf '\n'

    local summary="Changed: ${COUNT_CHANGED} | Already OK: ${COUNT_OK} | Skipped: ${COUNT_SKIPPED} | Failed: ${COUNT_FAILED}"
    if (( DRY_RUN )); then
        log_info "[DRY-RUN] ${summary}"
    else
        log_success "${summary}"
    fi
}

main

if (( COUNT_FAILED > 0 )); then
    exit 1
fi
exit 0
