#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Power Master - v3.0.0 (Engine: Master v3.9.1)
# -----------------------------------------------------------------------------
# Target: systemd-logind / logind.conf
#
# v3.0.0 CHANGELOG:
#   - ENGINE: Adopted Master v3.9.1 TUI engine architecture.
#   - CRITICAL: Replaced sed-based writes with atomic awk processing.
#   - FIX: Preserves symlinks during write (cat > target instead of mv).
#   - FIX: Robust escape sequence reading with proper timeout/terminator.
#   - FIX: Tab cycling no longer risks crash (clean modulo arithmetic).
#   - FIX: Hardened integer coercion against octal interpretation errors.
#   - FIX: Secure temp file lifecycle management.
#   - STYLE: Consistent quoting, shared rendering helpers, CLR_EOS usage.
#   - FEATURE: Enter/Backspace adjust, Home/End/PgUp/PgDn navigation.
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ ANSI CONSTANTS ▼
# =============================================================================

declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# Increased timeout for SSH/remote reliability
declare -r ESC_READ_TIMEOUT=0.10
declare -r UNSET_MARKER='«unset»'

# =============================================================================
# ▼ AUTO-ELEVATION ▼
# =============================================================================

if [[ ${EUID} -ne 0 ]]; then
    printf '%s[PRIVILEGE ESCALATION]%s This script requires root to edit logind.conf.\n' \
        "${C_YELLOW}" "${C_RESET}"
    exec sudo -- "$0" "$@"
fi

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

declare -r CONFIG_FILE="/etc/systemd/logind.conf"
declare -r APP_TITLE="Dusky Power Manager"
declare -r APP_VERSION="v3.0.0"

declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

declare -ra TABS=("Power Keys" "Lid & Idle" "Session")

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# =============================================================================
# ▼ STATE MANAGEMENT ▼
# =============================================================================

declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -i UNSAVED_CHANGES=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# Temp file global
declare _TMPFILE=""

# Data Structures
declare -A ITEM_SCHEMA=()     # label -> "key|type|opts"
declare -A VALUE_CACHE=()     # label -> current UI value
declare -A FILE_CACHE=()      # key   -> original disk value
declare -A DEFAULTS=()        # label -> default value
declare -A TAB_REGISTRY=()    # "tab:row" -> label
declare -a TAB_ROW_COUNTS=()  # tab_idx -> row count

for (( _ti = 0; _ti < TAB_COUNT; _ti++ )); do
    TAB_ROW_COUNTS[_ti]=0
done
unset _ti

# =============================================================================
# ▼ SYSTEM HELPERS ▼
# =============================================================================

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    # Secure temp file cleanup
    if [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- String Helpers ---

# Robust ANSI stripping using extglob parameter expansion.
strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

# =============================================================================
# ▼ CORE ENGINE ▼
# =============================================================================

register() {
    local -i tab_idx=$1
    local label="$2"
    local config="$3"
    local default_val="${4:-}"

    local key type opts
    IFS='|' read -r key type opts <<< "$config"
    case "$type" in
        bool|int|float|cycle) ;;
        *)
            log_err "Invalid type '${type}' for '${label}'"
            exit 1
            ;;
    esac

    ITEM_SCHEMA["${label}"]="$config"
    if [[ -n "$default_val" ]]; then DEFAULTS["${label}"]="$default_val"; fi

    local -i row=${TAB_ROW_COUNTS[tab_idx]}
    TAB_REGISTRY["${tab_idx}:${row}"]="$label"
    (( TAB_ROW_COUNTS[tab_idx]++ )) || :

    VALUE_CACHE["${label}"]="$UNSET_MARKER"
}

init_items() {
    local acts="ignore,poweroff,reboot,halt,suspend,hibernate,hybrid-sleep,suspend-then-hibernate,lock"

    # Tab 0: Power Keys
    register 0 "Power Key"   "HandlePowerKey|cycle|${acts}"          "poweroff"
    register 0 "Reboot Key"  "HandleRebootKey|cycle|${acts}"         "reboot"
    register 0 "Suspend Key" "HandleSuspendKey|cycle|${acts}"        "suspend"
    register 0 "Long Press"  "HandlePowerKeyLongPress|cycle|${acts}" "ignore"

    # Tab 1: Lid & Idle
    register 1 "Lid Switch"   "HandleLidSwitch|cycle|${acts}"              "suspend"
    register 1 "Lid (Ext)"    "HandleLidSwitchExternalPower|cycle|${acts}" "suspend"
    register 1 "Lid (Docked)" "HandleLidSwitchDocked|cycle|${acts}"        "ignore"
    register 1 "Idle Action"  "IdleAction|cycle|${acts}"                   "ignore"
    register 1 "Idle Timeout" "IdleActionSec|cycle|15min,30min,45min,1h,2h,infinity" "30min"

    # Tab 2: Session
    register 2 "Kill User Procs" "KillUserProcesses|cycle|yes,no" "no"
    register 2 "Reserve VTs"     "ReserveVT|int|0 12"             "6"
}

parse_config() {
    local line key val
    FILE_CACHE=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_err "Config file not found: ${CONFIG_FILE}"
        return 1
    fi

    while IFS= read -r line || [[ -n "${line:-}" ]]; do
        [[ -z "$line" || "$line" == "["* ]] && continue

        if [[ "$line" =~ ^#?([A-Za-z]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%%#*}"
            val="${val// /}"
            FILE_CACHE["${key}"]="$val"
        fi
    done < "$CONFIG_FILE"
}

load_values_to_ui() {
    local -i tab row
    local label key type opts

    for (( tab = 0; tab < TAB_COUNT; tab++ )); do
        for (( row = 0; row < TAB_ROW_COUNTS[tab]; row++ )); do
            label="${TAB_REGISTRY["${tab}:${row}"]}"
            IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"

            if [[ -n "${FILE_CACHE[${key}]:-}" ]]; then
                VALUE_CACHE["${label}"]="${FILE_CACHE[${key}]}"
            else
                VALUE_CACHE["${label}"]="$UNSET_MARKER"
            fi
        done
    done
}

# =============================================================================
# ▼ VALUE MUTATION ▼
# =============================================================================

modify_value() {
    local label="$1"
    local -i direction=$2
    local key type opts current new_val
    local -a opt_arr

    IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"
    current="${VALUE_CACHE[${label}]}"

    # Handle UNSET values - use default as starting point
    if [[ "$current" == "$UNSET_MARKER" ]]; then
        current="${DEFAULTS[${label}]:-}"
        [[ -z "$current" ]] && return 0
    fi

    if [[ "$type" == "int" ]]; then
        local -i min max int_val
        min=${opts%% *}
        max=${opts##* }

        if [[ ! "$current" =~ ^-?[0-9]+$ ]]; then current=$min; fi

        # Hardened Base-10 coercion (Fixes 008/009 octal crash)
        local _stripped="${current#-}"
        if [[ -n "$_stripped" ]]; then
            int_val=$(( 10#$_stripped ))
        else
            int_val=0
        fi
        if [[ "$current" == -* ]]; then
            int_val=$(( -int_val ))
        fi

        int_val=$(( int_val + direction ))
        if (( int_val < min )); then int_val=$min; fi
        if (( int_val > max )); then int_val=$max; fi
        new_val=$int_val
    else
        IFS=',' read -r -a opt_arr <<< "$opts"
        local -i idx=0 arr_len=${#opt_arr[@]} i
        (( arr_len == 0 )) && return 0
        for (( i = 0; i < arr_len; i++ )); do
            if [[ "${opt_arr[i]}" == "$current" ]]; then idx=$i; break; fi
        done
        idx=$(( (idx + direction + arr_len) % arr_len ))
        new_val="${opt_arr[idx]}"
    fi

    if [[ "$current" != "$new_val" ]]; then
        VALUE_CACHE["${label}"]="$new_val"
        UNSAVED_CHANGES=1
    fi
}

reset_defaults() {
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    local -i row
    local label def_val

    for (( row = 0; row < count; row++ )); do
        label="${TAB_REGISTRY["${CURRENT_TAB}:${row}"]}"
        def_val="${DEFAULTS["${label}"]:-}"

        if [[ -n "$def_val" && "${VALUE_CACHE[${label}]}" != "$def_val" ]]; then
            VALUE_CACHE["${label}"]="$def_val"
            UNSAVED_CHANGES=1
        fi
    done
}

# =============================================================================
# ▼ ATOMIC CONFIGURATION SAVE (awk-based) ▼
# =============================================================================

save_config() {
    local -i tab row changes=0
    local label key type opts val
    local -A pending_keys=()

    # Collect changes
    for (( tab = 0; tab < TAB_COUNT; tab++ )); do
        for (( row = 0; row < TAB_ROW_COUNTS[tab]; row++ )); do
            label="${TAB_REGISTRY["${tab}:${row}"]}"
            IFS='|' read -r key type opts <<< "${ITEM_SCHEMA[${label}]}"
            val="${VALUE_CACHE[${label}]}"

            [[ "$val" == "$UNSET_MARKER" ]] && continue
            [[ "$val" == "${FILE_CACHE[${key}]:-}" ]] && continue

            pending_keys["$key"]="$val"
            (( changes++ )) || :
        done
    done

    (( changes == 0 )) && return 1

    # Create temp file
    if [[ -z "$_TMPFILE" ]]; then
        _TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX") || {
            log_err "Failed to create temp file"
            return 1
        }
    fi

    # Build awk assignment string: "key1=val1;key2=val2;..."
    local awk_pairs=""
    local k v
    for k in "${!pending_keys[@]}"; do
        v="${pending_keys[$k]}"
        if [[ -n "$awk_pairs" ]]; then awk_pairs+=";"; fi
        awk_pairs+="${k}=${v}"
    done

    if ! LC_ALL=C awk -v pairs="$awk_pairs" '
    BEGIN {
        n = split(pairs, arr, ";")
        for (i = 1; i <= n; i++) {
            eq = index(arr[i], "=")
            k = substr(arr[i], 1, eq - 1)
            v = substr(arr[i], eq + 1)
            changes[k] = v
            replaced[k] = 0
        }
        found_login = 0
        appended = 0
    }
    {
        line = $0

        # Detect [Login] section
        if (line ~ /^\[Login\]/) {
            found_login = 1
        } else if (line ~ /^\[/) {
            # Entering a different section - append any unreplaced keys before it
            if (found_login && !appended) {
                for (k in changes) {
                    if (!replaced[k]) {
                        print k "=" changes[k]
                        replaced[k] = 1
                    }
                }
                appended = 1
            }
            found_login = 0
        }

        # Try to match key=value lines (with optional leading #)
        did_replace = 0
        if (match(line, /^#?([A-Za-z]+)=/, m_arr)) {
            # Extract key manually for portability
            clean = line
            sub(/^#/, "", clean)
            eq = index(clean, "=")
            if (eq > 0) {
                k = substr(clean, 1, eq - 1)
                gsub(/[[:space:]]/, "", k)
                if (k in changes) {
                    print k "=" changes[k]
                    replaced[k] = 1
                    did_replace = 1
                }
            }
        }

        if (!did_replace) {
            print line
        }
    }
    END {
        # If we never left [Login] section, append remaining here
        if (!appended) {
            if (!found_login) {
                print ""
                print "[Login]"
            }
            for (k in changes) {
                if (!replaced[k]) {
                    print k "=" changes[k]
                }
            }
        }
    }
    ' "$CONFIG_FILE" > "$_TMPFILE"; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        log_err "Failed to process config with awk"
        return 1
    fi

    # CRITICAL: Use cat > target to preserve symlinks/inodes.
    # Do NOT use mv, as it breaks symlink chains.
    cat "$_TMPFILE" > "$CONFIG_FILE"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    # Update FILE_CACHE
    for k in "${!pending_keys[@]}"; do
        FILE_CACHE["$k"]="${pending_keys[$k]}"
    done

    UNSAVED_CHANGES=0
    pkill -HUP -x systemd-logind 2>/dev/null || :
    return 0
}

# =============================================================================
# ▼ UI RENDERING ENGINE ▼
# =============================================================================

# Computes scroll window and clamps SELECTED_ROW
# Sets: SCROLL_OFFSET, SELECTED_ROW, _vis_start, _vis_end
# Note: _vis_start/_vis_end resolved via Bash dynamic scoping
compute_scroll_window() {
    local -i count=$1
    if (( count == 0 )); then
        SELECTED_ROW=0; SCROLL_OFFSET=0
        _vis_start=0; _vis_end=0
        return
    fi

    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi

    if (( SELECTED_ROW < SCROLL_OFFSET )); then
        SCROLL_OFFSET=$SELECTED_ROW
    elif (( SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS )); then
        SCROLL_OFFSET=$(( SELECTED_ROW - MAX_DISPLAY_ROWS + 1 ))
    fi

    local -i max_scroll=$(( count - MAX_DISPLAY_ROWS ))
    if (( max_scroll < 0 )); then max_scroll=0; fi
    if (( SCROLL_OFFSET > max_scroll )); then SCROLL_OFFSET=$max_scroll; fi

    _vis_start=$SCROLL_OFFSET
    _vis_end=$(( SCROLL_OFFSET + MAX_DISPLAY_ROWS ))
    if (( _vis_end > count )); then _vis_end=$count; fi
}

# Renders scroll indicators (above/below items)
render_scroll_indicator() {
    local -n _rsi_buf=$1
    local position="$2"
    local -i count=$3 boundary=$4

    if [[ "$position" == "above" ]]; then
        if (( SCROLL_OFFSET > 0 )); then
            _rsi_buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    else
        if (( count > MAX_DISPLAY_ROWS )); then
            local position_info="[$(( SELECTED_ROW + 1 ))/${count}]"
            if (( boundary < count )); then
                _rsi_buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            else
                _rsi_buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'
            fi
        else
            _rsi_buf+="${CLR_EOL}"$'\n'
        fi
    fi
}

draw_ui() {
    local buf="" pad_buf="" padded_item=""
    local -i i current_col=3 zone_start len count pad_needed
    local -i left_pad right_pad vis_len
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    # Title bar with save status
    local status_txt="$APP_VERSION"
    local status_clr="$C_CYAN"
    if (( UNSAVED_CHANGES )); then
        status_txt="UNSAVED"
        status_clr="$C_YELLOW"
    fi

    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$status_txt"; local -i s_len=${#REPLY}
    vis_len=$(( t_len + s_len + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${status_clr}${status_txt}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # Tab bar
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()

    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name="${TABS[i]}"
        len=${#name}
        zone_start=$current_col
        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi
        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        current_col=$(( current_col + len + 4 ))
    done

    pad_needed=$(( BOX_INNER_WIDTH - current_col + 2 ))
    if (( pad_needed < 0 )); then pad_needed=0; fi

    if (( pad_needed > 0 )); then
        printf -v pad_buf '%*s' "$pad_needed" ''
        tab_line+="${pad_buf}"
    fi
    tab_line+="${C_MAGENTA}│${C_RESET}"

    buf+="${tab_line}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # Items
    count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    compute_scroll_window "$count"

    # Scroll indicator: above
    render_scroll_indicator buf "above" "$count" "$_vis_start"

    # Item rows
    local item val display
    for (( i = _vis_start; i < _vis_end; i++ )); do
        item="${TAB_REGISTRY["${CURRENT_TAB}:${i}"]}"
        val="${VALUE_CACHE[${item}]}"

        case "$val" in
            yes|true)          display="${C_GREEN}YES${C_RESET}" ;;
            no|false)          display="${C_RED}NO${C_RESET}" ;;
            "$UNSET_MARKER")   display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
            poweroff)          display="${C_RED}${val}${C_RESET}" ;;
            suspend)           display="${C_CYAN}${val}${C_RESET}" ;;
            ignore)            display="${C_GREY}${val}${C_RESET}" ;;
            *)                 display="${C_WHITE}${val}${C_RESET}" ;;
        esac

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:${ITEM_PADDING}}"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    # Fill empty rows
    local -i rows_rendered=$(( _vis_end - _vis_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    # Scroll indicator: below
    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+=$'\n'"${C_CYAN} [Tab] Switch  [r]eset  [s] Save  [←/→ h/l] Adjust  [Enter] Toggle  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    printf '%s' "$buf"
}

# =============================================================================
# ▼ INPUT HANDLING ▼
# =============================================================================

navigate() {
    local -i dir=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_page() {
    local -i dir=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

navigate_end() {
    local -i target=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    if (( count == 0 )); then return 0; fi
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
}

adjust() {
    local -i dir=$1
    local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
    if (( count == 0 )); then return 0; fi
    modify_value "${TAB_REGISTRY["${CURRENT_TAB}:${SELECTED_ROW}"]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    CURRENT_TAB=$(( (CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
    load_values_to_ui
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        load_values_to_ui
    fi
}

handle_mouse() {
    local input="$1"
    local -i button x y i start end
    local type zone

    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    # Scroll wheel
    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    # Tab clicks
    if (( y == TAB_ROW )); then
        for (( i = 0; i < TAB_COUNT; i++ )); do
            zone="${TAB_ZONES[i]}"
            start="${zone%%:*}"
            end="${zone##*:}"
            if (( x >= start && x <= end )); then set_tab "$i"; return 0; fi
        done
    fi

    # Item clicks
    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))
        local -i count=${TAB_ROW_COUNTS[CURRENT_TAB]}
        if (( clicked_idx >= 0 && clicked_idx < count )); then
            SELECTED_ROW=$clicked_idx
            if (( x > ADJUST_THRESHOLD )); then
                if (( button == 0 )); then
                    adjust 1
                else
                    adjust -1
                fi
            fi
        fi
    fi
    return 0
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then
        return 1
    fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

# --- Input Router ---

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
            # Alt+Enter detection
            if [[ "$key" == "" || "$key" == $'\n' ]]; then
                key=$'\e\n'
            fi
        else
            # Bare ESC - no action in single-view mode
            return 0
        fi
    fi

    case "$key" in
        '[Z')                switch_tab -1; return ;;
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC')           adjust 1; return ;;
        '[D'|'OD')           adjust -1; return ;;
        '[5~')               navigate_page -1; return ;;
        '[6~')               navigate_page 1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    case "$key" in
        k|K)            navigate -1 ;;
        j|J)            navigate 1 ;;
        l|L)            adjust 1 ;;
        h|H)            adjust -1 ;;
        g)              navigate_end 0 ;;
        G)              navigate_end 1 ;;
        $'\t')          switch_tab 1 ;;
        r|R)            reset_defaults ;;
        s|S)            save_config || : ;;
        ''|$'\n')       adjust 1 ;;
        # Reverse Action (Backspace or Alt+Enter)
        $'\x7f'|$'\x08'|$'\e\n') adjust -1 ;;
        q|Q|$'\x03')    exit 0 ;;
    esac
}

# =============================================================================
# ▼ MAIN ▼
# =============================================================================

main() {
    if (( BASH_VERSINFO[0] < 5 )); then
        log_err "Bash 5.0+ required (found: ${BASH_VERSION})"
        exit 1
    fi
    if [[ ! -t 0 ]]; then log_err "TTY required"; exit 1; fi
    if [[ ! -f "$CONFIG_FILE" ]]; then log_err "Config not found: $CONFIG_FILE"; exit 1; fi
    if [[ ! -w "$CONFIG_FILE" ]]; then log_err "Config not writable: $CONFIG_FILE"; exit 1; fi

    local _dep
    for _dep in awk pkill; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Missing dependency: ${_dep}"
            exit 1
        fi
    done

    init_items
    parse_config || exit 1
    load_values_to_ui

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done

    # Unsaved changes prompt
    if (( UNSAVED_CHANGES )); then
        printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
        clear
        printf '%sUnsaved changes detected. Save? [Y/n] %s' "$C_YELLOW" "$C_RESET"
        local yn=""
        read -r -n 1 yn
        printf '\n'
        [[ ! "$yn" =~ ^[Nn]$ ]] && save_config
    fi
}

main "$@"
