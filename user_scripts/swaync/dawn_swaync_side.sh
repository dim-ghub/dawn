#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SwayNC Position Controller - Elite TUI v5.5 (Hardened & Bulletproof)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM / Wayland
#
# v5.5 CHANGELOG:
#   - UI SYNC: 100% parity with Master Template (76x14, Threshold 38).
#   - FIX: Excised invalid `in-t` animation modifiers. Strictly uses left/right/top/bottom.
#   - SECURITY (Data Loss Prevention): Implemented SIGTERM shielding (`trap '' TERM`) 
#     around `cat >` writes to prevent 0-byte truncations during debouncer kills, 
#     while preserving user symlinks/inodes (strictly rejecting `mv`).
# -----------------------------------------------------------------------------
# ▼ USAGE / CLI FLAGS ▼
# -----------------------------------------------------------------------------
# Legacy Usage (100% Backward Compatible):
#   -l, --left      Set X position to Left
#   -r, --right     Set X position to Right
#   -t, --toggle    Toggle (flip) X position between Left and Right
#
# Advanced Usage (v4.0+):
#   -x, --xpos      Set X position (left/center/right)
#   -y, --ypos      Set Y position (top/bottom)
#   -s, --status    Show current position
#   -h, --help      Show this help
#   (no args)       Launch interactive TUI
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

readonly SWAYNC_CONFIG="${HOME:?HOME is not set}/.config/swaync/config.json"
readonly HYPR_RULES="${HOME}/.config/hypr/source/window_rules.conf"

readonly APP_TITLE="SwayNC TUI Controller"
readonly APP_VERSION="v5.5 (Elite)"

# Dimensions & Layout (Synced 1:1 with Master TUI Template)
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=5
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$((HEADER_ROWS + 1))

# =============================================================================
# ▲ END OF CONFIGURATION ▲
# =============================================================================

# --- Pre-computed Constants ---
declare _h_line_buf
printf -v _h_line_buf '%*s' "$BOX_INNER_WIDTH" ''
declare -r H_LINE="${_h_line_buf// /─}"
unset _h_line_buf

# --- ANSI Constants ---
declare -r C_RESET=$'\033[0m'
declare -r C_CYAN=$'\033[1;36m'
declare -r C_GREEN=$'\033[1;32m'
declare -r C_MAGENTA=$'\033[1;35m'
declare -r C_RED=$'\033[1;31m'
declare -r C_YELLOW=$'\033[1;33m'
declare -r C_WHITE=$'\033[1;37m'
declare -r C_GREY=$'\033[1;30m'
declare -r C_BLUE=$'\033[1;34m'
declare -r C_INVERSE=$'\033[7m'
declare -r CLR_EOL=$'\033[K'
declare -r CLR_EOS=$'\033[J'
declare -r CLR_SCREEN=$'\033[2J'
declare -r CURSOR_HOME=$'\033[H'
declare -r CURSOR_HIDE=$'\033[?25l'
declare -r CURSOR_SHOW=$'\033[?25h'
declare -r MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
declare -r MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

declare -r ESC_READ_TIMEOUT=0.10

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare ORIGINAL_STTY=""
declare STATUS_MSG=""
declare STATUS_COLOR=""
declare -i NEEDS_REDRAW=1
declare -i TUI_RUNNING=0
declare _TMPFILE=""
declare -i _SAVE_PID=0

# Dynamic State Variables
declare CURRENT_POSITION_X=""
declare CURRENT_POSITION_Y=""
declare -i MARGIN_TOP=0 MARGIN_BOTTOM=0 MARGIN_LEFT=0 MARGIN_RIGHT=0
declare -i DIM_CC=0 DIM_NW=0
declare -i TMO_N=0 TMO_L=0 TMO_C=0

# Tab management
declare -i CURRENT_TAB=0
declare -i TAB_SCROLL_START=0
declare -ra TABS=("Position" "Margins" "Dimensions" "Timeouts")
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare LEFT_ARROW_ZONE=""
declare RIGHT_ARROW_ZONE=""

# Position options
declare -ra POS_X_OPTIONS=("left" "center" "right")
declare -ra POS_Y_OPTIONS=("bottom" "top")

# Menu Mappings (Nameref targets)
declare -ra TAB0_ITEMS=("Set Position X:" "Set Position Y:" "Refresh Status" "Quit")
declare -ra TAB0_ICONS=("↔" "↕" "↻" "✕")

declare -ra TAB1_ITEMS=("Margin Top:" "Margin Bottom:" "Margin Left:" "Margin Right:" "Back")
declare -ra TAB1_ICONS=("▲" "▼" "◀" "▶" "←")

declare -ra TAB2_ITEMS=("Center Width:" "Notif Width:" "Back")
declare -ra TAB2_ICONS=("◫" "◧" "←")

declare -ra TAB3_ITEMS=("Normal Timeout:" "Low Timeout:" "Critical Timeout:" "Back")
declare -ra TAB3_ICONS=("⏱" "⏱" "⏱" "←")

get_current_menu_count() {
    case "$CURRENT_TAB" in
        0) echo ${#TAB0_ITEMS[@]} ;;
        1) echo ${#TAB1_ITEMS[@]} ;;
        2) echo ${#TAB2_ITEMS[@]} ;;
        3) echo ${#TAB3_ITEMS[@]} ;;
    esac
}

# --- System Helpers ---

log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }
cli_die() { if ((TUI_RUNNING)); then set_status "ERROR" "$1" "red"; else log_err "$1"; exit 1; fi; }
cli_info() { printf '%s[INFO]%s %s\n' "${C_CYAN}" "$C_RESET" "$1"; }
cli_warn() { printf '%s[WARN]%s %s\n' "${C_YELLOW}" "$C_RESET" "$1" >&2; }
cli_success() { printf '%s[SUCCESS]%s %s\n' "${C_GREEN}" "$C_RESET" "$1"; }

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    [[ -n "${ORIGINAL_STTY:-}" ]] && stty "$ORIGINAL_STTY" 2>/dev/null || :
    [[ -n "${_TMPFILE:-}" && -f "$_TMPFILE" ]] && rm -f "$_TMPFILE" 2>/dev/null || :
    
    # Wait for background debouncer to finish saving to prevent data loss on immediate exit
    if (( _SAVE_PID > 0 )) && kill -0 "$_SAVE_PID" 2>/dev/null; then
        wait "$_SAVE_PID" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

check_dependencies() {
    command -v jq &>/dev/null || cli_die "'jq' is not installed"
    command -v awk &>/dev/null || cli_die "'awk' is not installed"
    [[ -w "$SWAYNC_CONFIG" ]] || cli_die "Config not writable: $SWAYNC_CONFIG"
    [[ -w "$HYPR_RULES" ]] || cli_die "Hyprland rules not writable: $HYPR_RULES"
}

# --- Core Logic & Debouncer ---

atomic_jq_update() {
    local config_file="$1"
    shift
    [[ -z "${_TMPFILE:-}" ]] && _TMPFILE=$(mktemp "${config_file}.tmp.XXXXXXXXXX")

    if ! jq "$@" "$config_file" > "$_TMPFILE" 2>/dev/null || [[ ! -s "$_TMPFILE" ]]; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        return 1
    fi

    # CRITICAL FIX: Shield the file write from SIGTERM to prevent 0-byte truncation
    # if the debouncer is killed exactly during execution, while preserving symlinks (no mv).
    trap '' TERM
    cat "$_TMPFILE" > "$config_file"
    trap - TERM

    rm -f "$_TMPFILE"
    _TMPFILE=""
    return 0
}

read_config_state() {
    # Highly optimized TSV pipeline parsing all properties in one shell call.
    local fallback="left\tbottom\t0\t5\t5\t0\t300\t350\t5\t3\t10"
    local state_str
    
    state_str=$(jq -r '[
        .positionX // "left",
        .positionY // "bottom",
        ."control-center-margin-top" // 0,
        ."control-center-margin-bottom" // 5,
        ."control-center-margin-left" // 5,
        ."control-center-margin-right" // 0,
        ."control-center-width" // 300,
        ."notification-window-width" // 350,
        .timeout // 5,
        ."timeout-low" // 3,
        ."timeout-critical" // 10
    ] | @tsv' "$SWAYNC_CONFIG" 2>/dev/null || echo -e "$fallback")

    IFS=$'\t' read -r \
        CURRENT_POSITION_X CURRENT_POSITION_Y \
        MARGIN_TOP MARGIN_BOTTOM MARGIN_LEFT MARGIN_RIGHT \
        DIM_CC DIM_NW TMO_N TMO_L TMO_C <<< "$state_str"
}

queue_save_and_reload() {
    if (( _SAVE_PID > 0 )); then
        kill "$_SAVE_PID" 2>/dev/null || :
    fi
    (
        trap 'rm -f "$_TMPFILE" 2>/dev/null || :' EXIT
        sleep 0.15
        
        atomic_jq_update "$SWAYNC_CONFIG" \
            --argjson mt "$MARGIN_TOP" \
            --argjson mb "$MARGIN_BOTTOM" \
            --argjson ml "$MARGIN_LEFT" \
            --argjson mr "$MARGIN_RIGHT" \
            --argjson cc "$DIM_CC" \
            --argjson nw "$DIM_NW" \
            --argjson tn "$TMO_N" \
            --argjson tl "$TMO_L" \
            --argjson tc "$TMO_C" \
            '. | ."control-center-margin-top" = $mt | ."control-center-margin-bottom" = $mb | ."control-center-margin-left" = $ml | ."control-center-margin-right" = $mr | ."control-center-width" = $cc | ."notification-window-width" = $nw | .timeout = $tn | ."timeout-low" = $tl | ."timeout-critical" = $tc'
        
        swaync-client --reload-config &>/dev/null || :
        swaync-client --reload-css &>/dev/null || :
    ) &
    _SAVE_PID=$!
}

apply_numeric_change() {
    local var_name="$1"
    local -i delta=$2
    local -i min_val=${3:-0}
    local -i max_val=${4:-9999}

    local -n ref="$var_name"
    local -i new_val=$((ref + delta))
    
    if ((new_val < min_val)); then new_val=$min_val; fi
    if ((new_val > max_val)); then new_val=$max_val; fi

    ref=$new_val
    queue_save_and_reload
}

apply_position_changes() {
    local axis="${1:-}"
    local target_value="${2:-}"

    if [[ "$axis" == "x" ]]; then
        if [[ ! "$target_value" =~ ^(left|center|right)$ ]]; then cli_die "Invalid X pos"; fi
    elif [[ "$axis" == "y" ]]; then
        if [[ ! "$target_value" =~ ^(top|bottom)$ ]]; then cli_die "Invalid Y pos"; fi
    else cli_die "Invalid axis: $axis"; fi

    read_config_state
    local current
    [[ "$axis" == "x" ]] && current="$CURRENT_POSITION_X" || current="$CURRENT_POSITION_Y"
    
    if [[ "$current" == "$target_value" ]]; then
        if ((TUI_RUNNING)); then set_status "INFO" "Already set to ${target_value^}" "cyan"; fi
        return 0
    fi

    if ((!TUI_RUNNING)); then cli_info "Switching to ${target_value^^}..."; fi

    local json_key="position${axis^^}"
    if ! atomic_jq_update "$SWAYNC_CONFIG" --arg val "$target_value" '."'"$json_key"'" = $val'; then
        cli_die "Failed to update SwayNC config"
    fi

    read_config_state
    local actual
    [[ "$axis" == "x" ]] && actual="$CURRENT_POSITION_X" || actual="$CURRENT_POSITION_Y"
    if [[ "$actual" != "$target_value" ]]; then
        cli_die "Verification failed! Config did not update."
    fi

    local final_x="${CURRENT_POSITION_X}"
    local final_y="${CURRENT_POSITION_Y}"

    # HYPRLAND ANIMATION FIX: Strict adherence to supported directional vectors (left, right, top, bottom).
    local anim_dir="$final_x"
    if [[ "$anim_dir" == "center" ]]; then
        anim_dir="$final_y"
    fi

    if grep -q 'name = swaync_slide' "$HYPR_RULES" 2>/dev/null; then
        _TMPFILE=$(mktemp "${HYPR_RULES}.tmp.XXXXXXXXXX")
        NEW_ANIM="animation = slide $anim_dir" awk '
            BEGIN { new_anim = ENVIRON["NEW_ANIM"] }
            /name = swaync_slide/ { in_block = 1 }
            in_block && /animation = slide .*/ { sub(/animation = slide .*/, new_anim) }
            /}/ && in_block { in_block = 0 }
            { print }
        ' "$HYPR_RULES" > "$_TMPFILE"

        if [[ -s "$_TMPFILE" ]]; then
            # SIGTERM shielding applied here as well for absolute safety
            trap '' TERM
            cat "$_TMPFILE" > "$HYPR_RULES"
            trap - TERM
        else
            cli_warn "Failed to generate Hyprland rules update"
        fi
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
    fi

    reload_services "$target_value"
    if ((TUI_RUNNING)); then set_status "OK" "Position ${axis^^} set to ${target_value^}" "green"; fi
    return 0
}

cycle_position() {
    local axis="$1"
    local -i dir=$2
    local -a options
    local current

    if [[ "$axis" == "x" ]]; then options=("${POS_X_OPTIONS[@]}"); current="$CURRENT_POSITION_X"
    else options=("${POS_Y_OPTIONS[@]}"); current="$CURRENT_POSITION_Y"; fi

    local -i current_idx=0 i
    for ((i = 0; i < ${#options[@]}; i++)); do
        if [[ "${options[i]}" == "$current" ]]; then current_idx=$i; break; fi
    done

    local -i new_idx=$(((current_idx + dir + ${#options[@]}) % ${#options[@]}))
    apply_position_changes "$axis" "${options[new_idx]}"
}

toggle_position() {
    read_config_state
    case "$CURRENT_POSITION_X" in
        left)  apply_position_changes "x" "right" ;;
        right|center) apply_position_changes "x" "left" ;;
        *) cli_die "Unknown current X position: '$CURRENT_POSITION_X'" ;;
    esac
}

reset_current_tab() {
    case "$CURRENT_TAB" in
        0)
            apply_position_changes "x" "left" >/dev/null 2>&1
            apply_position_changes "y" "bottom" >/dev/null 2>&1
            set_status "OK" "Position reset to Left/Bottom" "green"
            ;;
        1)
            MARGIN_TOP=0; MARGIN_BOTTOM=5; MARGIN_LEFT=5; MARGIN_RIGHT=0
            queue_save_and_reload
            set_status "OK" "Margins reset to default (T:0 B:5 L:5 R:0)" "green"
            ;;
        2)
            DIM_CC=300; DIM_NW=350
            queue_save_and_reload
            set_status "OK" "Dimensions reset to default (CC:300 NW:350)" "green"
            ;;
        3)
            TMO_N=5; TMO_L=3; TMO_C=10
            queue_save_and_reload
            set_status "OK" "Timeouts reset to default (5s, 3s, 10s)" "green"
            ;;
    esac
}

reload_services() {
    local target_side="${1:-config}"
    local -a warnings=()

    if command -v swaync-client &>/dev/null; then
        swaync-client --reload-config &>/dev/null || warnings+=("SwayNC config reload failed")
        swaync-client --reload-css &>/dev/null || warnings+=("SwayNC CSS reload failed")
    else
        warnings+=("swaync-client not found")
    fi

    if command -v hyprctl &>/dev/null; then
        hyprctl reload &>/dev/null || warnings+=("Hyprland reload failed")
    else
        warnings+=("hyprctl not found")
    fi

    if ((${#warnings[@]} > 0)); then
        if ((TUI_RUNNING)); then set_status "WARN" "${warnings[0]}" "yellow"
        else
            for w in "${warnings[@]}"; do cli_warn "$w"; done
        fi
    fi

    if ((!TUI_RUNNING)); then
        if [[ "$target_side" =~ ^(left|right|top|bottom)$ ]]; then
            cli_success "Position updated to ${target_side^^}"
        else
            cli_success "Configuration applied successfully"
        fi
    fi
}

# --- TUI Status Management ---

set_status() {
    local level="$1" msg="$2" color="${3:-cyan}"
    case "$color" in
        red) STATUS_COLOR="$C_RED" ;; green) STATUS_COLOR="$C_GREEN" ;;
        yellow) STATUS_COLOR="$C_YELLOW" ;; cyan) STATUS_COLOR="$C_CYAN" ;;
        *) STATUS_COLOR="$C_WHITE" ;;
    esac
    STATUS_MSG="${level}: ${msg}"
    NEEDS_REDRAW=1
}

# --- TUI Rendering Engine ---

compute_scroll_window() {
    local -i count=$1
    if ((count == 0)); then
        SELECTED_ROW=0; SCROLL_OFFSET=0; _vis_start=0; _vis_end=0; return
    fi
    if ((SELECTED_ROW < 0)); then SELECTED_ROW=0; fi
    if ((SELECTED_ROW >= count)); then SELECTED_ROW=$((count - 1)); fi
    if ((SELECTED_ROW < SCROLL_OFFSET)); then SCROLL_OFFSET=$SELECTED_ROW
    elif ((SELECTED_ROW >= SCROLL_OFFSET + MAX_DISPLAY_ROWS)); then
        SCROLL_OFFSET=$((SELECTED_ROW - MAX_DISPLAY_ROWS + 1))
    fi
    local -i max_scroll=$((count - MAX_DISPLAY_ROWS))
    if ((max_scroll < 0)); then max_scroll=0; fi
    if ((SCROLL_OFFSET > max_scroll)); then SCROLL_OFFSET=$max_scroll; fi
    _vis_start=$SCROLL_OFFSET
    _vis_end=$((SCROLL_OFFSET + MAX_DISPLAY_ROWS))
    if ((_vis_end > count)); then _vis_end=$count; fi
}

draw_ui() {
    local buf="" pad_buf=""
    local -i left_pad right_pad vis_len pad_needed
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$APP_VERSION"; local -i v_len=${#REPLY}
    vis_len=$((t_len + v_len + 1))
    left_pad=$(((BOX_INNER_WIDTH - vis_len) / 2))
    right_pad=$((BOX_INNER_WIDTH - vis_len - left_pad))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    # --- Scrollable Tab Rendering ---
    if (( TAB_SCROLL_START > CURRENT_TAB )); then TAB_SCROLL_START=$CURRENT_TAB; fi

    local tab_line
    local -i max_tab_width=$(( BOX_INNER_WIDTH - 6 ))
    
    LEFT_ARROW_ZONE=""
    RIGHT_ARROW_ZONE=""

    while true; do
        tab_line="${C_MAGENTA}│ "
        local -i current_col=3
        TAB_ZONES=()
        local -i used_len=0

        if (( TAB_SCROLL_START > 0 )); then
            tab_line+="${C_YELLOW}«${C_RESET} "
            LEFT_ARROW_ZONE="$current_col:$((current_col+1))"
            used_len=$(( used_len + 2 )); current_col=$(( current_col + 2 ))
        else
            tab_line+="  "
            used_len=$(( used_len + 2 )); current_col=$(( current_col + 2 ))
        fi

        local -i i zone_start
        for (( i = TAB_SCROLL_START; i < TAB_COUNT; i++ )); do
            local name="${TABS[i]}"
            local chunk_len=$(( ${#name} + 4 ))
            local reserve=0
            if (( i < TAB_COUNT - 1 )); then reserve=2; fi

            if (( used_len + chunk_len + reserve > max_tab_width )); then
                if (( i <= CURRENT_TAB )); then TAB_SCROLL_START=$(( TAB_SCROLL_START + 1 )); continue 2; fi
                tab_line+="${C_YELLOW}» ${C_RESET}"
                RIGHT_ARROW_ZONE="$current_col:$((current_col+1))"
                used_len=$(( used_len + 2 ))
                break
            fi

            zone_start=$current_col
            if (( i == CURRENT_TAB )); then tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
            else tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "; fi
            
            TAB_ZONES+=("${zone_start}:$(( zone_start + ${#name} + 1 ))")
            used_len=$(( used_len + chunk_len ))
            current_col=$(( current_col + chunk_len ))
        done

        local pad=$(( BOX_INNER_WIDTH - used_len - 1 ))
        if (( pad > 0 )); then printf -v pad_buf '%*s' "$pad" ''; tab_line+="$pad_buf"; fi
        tab_line+="${C_MAGENTA}│${C_RESET}"; break
    done
    
    buf+="${tab_line}${CLR_EOL}"$'\n'

    # --- Active Data Line ---
    local line_content=""
    case "$CURRENT_TAB" in
        0)
            local pos_color_x pos_color_y
            [[ "$CURRENT_POSITION_X" == "left" ]] && pos_color_x="$C_CYAN" || pos_color_x="$C_GREEN"
            [[ "$CURRENT_POSITION_X" == "center" ]] && pos_color_x="$C_YELLOW"
            [[ "$CURRENT_POSITION_Y" == "top" ]] && pos_color_y="$C_MAGENTA" || pos_color_y="$C_BLUE"
            line_content=" X:${pos_color_x}${CURRENT_POSITION_X^}${C_WHITE}  Y:${pos_color_y}${CURRENT_POSITION_Y^}${C_RESET}" ;;
        1)
            line_content=" T:${C_YELLOW}${MARGIN_TOP}${C_WHITE} B:${C_YELLOW}${MARGIN_BOTTOM}${C_WHITE} L:${C_YELLOW}${MARGIN_LEFT}${C_WHITE} R:${C_YELLOW}${MARGIN_RIGHT}${C_RESET}" ;;
        2)
            line_content=" CC Width:${C_YELLOW}${DIM_CC}${C_WHITE}  Notif Width:${C_YELLOW}${DIM_NW}${C_RESET}" ;;
        3)
            line_content=" N:${C_YELLOW}${TMO_N}s${C_WHITE}  L:${C_YELLOW}${TMO_L}s${C_WHITE}  C:${C_YELLOW}${TMO_C}s${C_RESET}" ;;
    esac

    strip_ansi "$line_content"; local -i c_len=${#REPLY}
    pad_needed=$((BOX_INNER_WIDTH - c_len))
    if ((pad_needed < 0)); then pad_needed=0; fi
    printf -v pad_buf '%*s' "$pad_needed" ''
    
    buf+="${C_MAGENTA}│${C_WHITE}${line_content}${pad_buf}${C_MAGENTA}│${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    # --- Nameref Driven Lists ---
    local -n current_items="TAB${CURRENT_TAB}_ITEMS"
    local -n current_icons="TAB${CURRENT_TAB}_ICONS"
    local -i current_count=$(get_current_menu_count)

    compute_scroll_window "$current_count"

    if ((SCROLL_OFFSET > 0)); then buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
    else buf+="${CLR_EOL}"$'\n'; fi

    local -i ri rows_rendered
    local item icon item_color padded_item active_mark

    for ((ri = _vis_start; ri < _vis_end; ri++)); do
        item="${current_items[ri]}"
        icon="${current_icons[ri]}"
        item_color="$C_WHITE"
        active_mark=""
        
        local max_len=$(( ITEM_PADDING - 1 ))
        if (( ${#item} > ITEM_PADDING )); then printf -v padded_item "%-${max_len}s…" "${item:0:max_len}"
        else printf -v padded_item "%-${ITEM_PADDING}s" "$item"; fi

        case "$CURRENT_TAB" in
            0)
                case "$ri" in
                    0) item_color="$C_CYAN"; active_mark="${C_GREEN}${CURRENT_POSITION_X^}${C_RESET}" ;;
                    1) item_color="$C_MAGENTA"; active_mark="${C_GREEN}${CURRENT_POSITION_Y^}${C_RESET}" ;;
                    3) item_color="$C_RED" ;;
                esac ;;
            1)
                case "$ri" in
                    0) item_color="$C_YELLOW"; active_mark="${C_YELLOW}${MARGIN_TOP}${C_RESET}" ;;
                    1) item_color="$C_BLUE"; active_mark="${C_YELLOW}${MARGIN_BOTTOM}${C_RESET}" ;;
                    2) item_color="$C_CYAN"; active_mark="${C_YELLOW}${MARGIN_LEFT}${C_RESET}" ;;
                    3) item_color="$C_GREEN"; active_mark="${C_YELLOW}${MARGIN_RIGHT}${C_RESET}" ;;
                    4) item_color="$C_GREY" ;;
                esac ;;
            2)
                case "$ri" in
                    0) item_color="$C_MAGENTA"; active_mark="${C_YELLOW}${DIM_CC}${C_RESET}" ;;
                    1) item_color="$C_CYAN"; active_mark="${C_YELLOW}${DIM_NW}${C_RESET}" ;;
                    2) item_color="$C_GREY" ;;
                esac ;;
            3)
                case "$ri" in
                    0) item_color="$C_GREEN"; active_mark="${C_YELLOW}${TMO_N}s${C_RESET}" ;;
                    1) item_color="$C_BLUE"; active_mark="${C_YELLOW}${TMO_L}s${C_RESET}" ;;
                    2) item_color="$C_RED"; active_mark="${C_YELLOW}${TMO_C}s${C_RESET}" ;;
                    3) item_color="$C_GREY" ;;
                esac ;;
        esac

        if ((ri == SELECTED_ROW)); then
            buf+="${C_CYAN} ➤ ${C_INVERSE} ${padded_item} ${C_RESET} ${active_mark}${CLR_EOL}"$'\n'
        else
            buf+="    ${item_color}${icon}${C_RESET} ${padded_item} ${active_mark}${CLR_EOL}"$'\n'
        fi
    done

    rows_rendered=$((_vis_end - _vis_start))
    for ((ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++)); do buf+="${CLR_EOL}"$'\n'; done

    if ((current_count > MAX_DISPLAY_ROWS)); then
        local position_info="[$((SELECTED_ROW + 1))/${current_count}]"
        if ((_vis_end < current_count)); then buf+="${C_GREY}    ▼ (more below) ${position_info}${CLR_EOL}${C_RESET}"$'\n'
        else buf+="${C_GREY}                   ${position_info}${CLR_EOL}${C_RESET}"$'\n'; fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi

    # Status & Help lines
    buf+=$'\n'
    if [[ -n "$STATUS_MSG" ]]; then buf+=" ${STATUS_COLOR}${STATUS_MSG}${C_RESET}${CLR_EOL}"$'\n'
    else buf+="${CLR_EOL}"$'\n'; fi

    buf+=$'\n'"${C_CYAN} [↑↓ j k] Nav  [←→ h l] Set  [Tab] Tabs  [r] Reset${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} [Enter] Select  [Backspace] Back  [q] Quit${C_RESET}${CLR_EOL}"$'\n'

    printf '%s' "$buf"
}

# --- TUI Input Handling ---

navigate() {
    local -i dir=$1 count=$(get_current_menu_count)
    if ((count == 0)); then return 0; fi
    SELECTED_ROW=$(((SELECTED_ROW + dir + count) % count))
    NEEDS_REDRAW=1
}

action_right() {
    local -n current_items="TAB${CURRENT_TAB}_ITEMS"
    if [[ "${current_items[SELECTED_ROW]}" == "Back" || "${current_items[SELECTED_ROW]}" == "Quit" ]]; then
        if [[ "${current_items[SELECTED_ROW]}" == "Quit" ]]; then exit 0; fi
        CURRENT_TAB=0; SELECTED_ROW=0; NEEDS_REDRAW=1; return
    fi

    case "$CURRENT_TAB" in
        0)
            case "$SELECTED_ROW" in
                0) cycle_position "x" 1 ;;
                1) cycle_position "y" 1 ;;
                2) read_config_state; set_status "OK" "Refreshed Data" "cyan" ;;
            esac ;;
        1)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "MARGIN_TOP" 1 0 999 ;;
                1) apply_numeric_change "MARGIN_BOTTOM" 1 0 999 ;;
                2) apply_numeric_change "MARGIN_LEFT" 1 0 999 ;;
                3) apply_numeric_change "MARGIN_RIGHT" 1 0 999 ;;
            esac ;;
        2)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "DIM_CC" 10 100 2000 ;;
                1) apply_numeric_change "DIM_NW" 10 100 2000 ;;
            esac ;;
        3)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "TMO_N" 1 1 120 ;;
                1) apply_numeric_change "TMO_L" 1 1 120 ;;
                2) apply_numeric_change "TMO_C" 1 1 120 ;;
            esac ;;
    esac
    NEEDS_REDRAW=1
}

action_left() {
    local -n current_items="TAB${CURRENT_TAB}_ITEMS"
    if [[ "${current_items[SELECTED_ROW]}" == "Back" || "${current_items[SELECTED_ROW]}" == "Quit" ]]; then
        if [[ "${current_items[SELECTED_ROW]}" == "Quit" ]]; then exit 0; fi
        CURRENT_TAB=0; SELECTED_ROW=0; NEEDS_REDRAW=1; return
    fi

    case "$CURRENT_TAB" in
        0)
            case "$SELECTED_ROW" in
                0) cycle_position "x" -1 ;;
                1) cycle_position "y" -1 ;;
                2) read_config_state; set_status "OK" "Refreshed Data" "cyan" ;;
            esac ;;
        1)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "MARGIN_TOP" -1 0 999 ;;
                1) apply_numeric_change "MARGIN_BOTTOM" -1 0 999 ;;
                2) apply_numeric_change "MARGIN_LEFT" -1 0 999 ;;
                3) apply_numeric_change "MARGIN_RIGHT" -1 0 999 ;;
            esac ;;
        2)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "DIM_CC" -10 100 2000 ;;
                1) apply_numeric_change "DIM_NW" -10 100 2000 ;;
            esac ;;
        3)
            case "$SELECTED_ROW" in
                0) apply_numeric_change "TMO_N" -1 1 120 ;;
                1) apply_numeric_change "TMO_L" -1 1 120 ;;
                2) apply_numeric_change "TMO_C" -1 1 120 ;;
            esac ;;
    esac
    NEEDS_REDRAW=1
}

read_escape_seq() {
    local -n _esc_out=$1
    _esc_out=""
    local char
    if ! IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; then return 1; fi
    _esc_out+="$char"
    if [[ "$char" == '[' || "$char" == 'O' ]]; then
        while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
            _esc_out+="$char"
            if [[ "$char" =~ [a-zA-Z~] ]]; then break; fi
        done
    fi
    return 0
}

handle_mouse() {
    local input="$1"
    local -i button x y
    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi
    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi
    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<<"$body"
    if [[ ! "$field1" =~ ^[0-9]+$ || ! "$field2" =~ ^[0-9]+$ || ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    if ((button == 64)); then navigate -1; return 0; fi
    if ((button == 65)); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    if ((y == TAB_ROW)); then
        local -i i start end
        if [[ -n "$LEFT_ARROW_ZONE" ]]; then
            start="${LEFT_ARROW_ZONE%%:*}"; end="${LEFT_ARROW_ZONE##*:}"
            if (( x >= start && x <= end )); then 
                CURRENT_TAB=$(( (CURRENT_TAB - 1 + TAB_COUNT) % TAB_COUNT )); SELECTED_ROW=0; SCROLL_OFFSET=0; NEEDS_REDRAW=1; return 0
            fi
        fi
        if [[ -n "$RIGHT_ARROW_ZONE" ]]; then
            start="${RIGHT_ARROW_ZONE%%:*}"; end="${RIGHT_ARROW_ZONE##*:}"
            if (( x >= start && x <= end )); then 
                CURRENT_TAB=$(( (CURRENT_TAB + 1) % TAB_COUNT )); SELECTED_ROW=0; SCROLL_OFFSET=0; NEEDS_REDRAW=1; return 0
            fi
        fi

        for ((i = 0; i < TAB_COUNT; i++)); do
            if [[ -z "${TAB_ZONES[i]:-}" ]]; then continue; fi
            start="${TAB_ZONES[i]%%:*}"; end="${TAB_ZONES[i]##*:}"
            if ((x >= start && x <= end)); then
                CURRENT_TAB=$(( i + TAB_SCROLL_START )); SELECTED_ROW=0; SCROLL_OFFSET=0; NEEDS_REDRAW=1; return 0
            fi
        done
    fi

    local -i effective_start=$((ITEM_START_ROW + 1))
    if ((y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS)); then
        local -i clicked_idx=$((y - effective_start + SCROLL_OFFSET))
        local -i count=$(get_current_menu_count)
        
        if ((clicked_idx >= 0 && clicked_idx < count)); then
            SELECTED_ROW=$clicked_idx
            NEEDS_REDRAW=1
            
            local -n current_items="TAB${CURRENT_TAB}_ITEMS"
            local item_name="${current_items[SELECTED_ROW]}"
            
            if [[ "$item_name" == "Quit" || "$item_name" == "Back" || "$item_name" == "Refresh Status" ]]; then
                if (( button == 0 )); then action_right; fi
            else
                if (( x > ADJUST_THRESHOLD )); then
                    if ((button == 0)); then action_right; else action_left; fi
                fi
            fi
        fi
    fi
    return 0
}

handle_input_router() {
    local key="$1" escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
            [[ "$key" == "" || "$key" == $'\n' ]] && key=$'\e\n'
        else key="ESC"; fi
    fi

    case "$key" in
        '[Z') CURRENT_TAB=$(((CURRENT_TAB - 1 + TAB_COUNT) % TAB_COUNT)); SELECTED_ROW=0; SCROLL_OFFSET=0; NEEDS_REDRAW=1; return ;;
        '[A' | 'OA') navigate -1; return ;;
        '[B' | 'OB') navigate 1; return ;;
        '[C' | 'OC') action_right; return ;;
        '[D' | 'OD') action_left; return ;;
        '['*'<'*[Mm]) handle_mouse "$key"; return ;;
    esac

    case "$key" in
        $'\t') CURRENT_TAB=$(((CURRENT_TAB + 1) % TAB_COUNT)); SELECTED_ROW=0; SCROLL_OFFSET=0; NEEDS_REDRAW=1 ;;
        k | K) navigate -1 ;;
        j | J) navigate 1 ;;
        l | L) action_right ;;
        h | H) action_left ;;
        r | R) reset_current_tab ;;
        '' | $'\n') action_right ;;
        $'\x7f' | $'\x08' | $'\e\n') action_left ;;
        q | Q | $'\x03') exit 0 ;;
    esac
}

# --- CLI Functions (Non-TUI) ---

show_status() {
    read_config_state
    printf 'Current position: X: %s%s%s  Y: %s%s%s\n' "${C_CYAN}" "${CURRENT_POSITION_X^}" "$C_RESET" "${C_MAGENTA}" "${CURRENT_POSITION_Y^}" "$C_RESET"
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTION]

Legacy Options (Backward Compatible):
  -l, --left      Set X position to Left
  -r, --right     Set X position to Right
  -t, --toggle    Toggle (flip) X position between Left and Right

Advanced Options (v4.0+):
  -x, --xpos      Set X position (left/center/right)
  -y, --ypos      Set Y position (top/bottom)
  -s, --status    Show current position
  -h, --help      Show this help

Running without arguments opens the Interactive TUI.

TUI Controls:
  ↑/↓, j/k      Navigate menu
  ←/→, h/l      Adjust value or Select
  Tab/Shift+Tab Switch tabs
  Enter         Execute action
  Backspace     Reverse action
  r             Reset current tab to defaults
  Mouse         Click text to select, click value to adjust
  q, Ctrl+C     Quit
EOF
}

# --- Main Entry Points ---

show_tui() {
    if ((BASH_VERSINFO[0] < 5)); then log_err "Bash 5.0+ required"; exit 1; fi
    if [[ ! -t 0 ]]; then log_err "TTY required for TUI mode"; exit 1; fi

    TUI_RUNNING=1
    read_config_state

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    set_status "OK" "Ready — Select an action" "cyan"

    local key
    while true; do
        if ((NEEDS_REDRAW)); then
            draw_ui
            NEEDS_REDRAW=0
        fi
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done
}

main() {
    check_dependencies
    if (($# == 0)); then show_tui; return; fi

    case "$1" in
        -l | --left) apply_position_changes "x" "left" ;;
        -r | --right) apply_position_changes "x" "right" ;;
        -t | --toggle) toggle_position ;;
        -x | --xpos)
            if [[ -z "${2:-}" ]]; then cli_die "Missing value for --xpos"; fi
            apply_position_changes "x" "$2" ;;
        -y | --ypos)
            if [[ -z "${2:-}" ]]; then cli_die "Missing value for --ypos"; fi
            apply_position_changes "y" "$2" ;;
        -s | --status) show_status ;;
        -h | --help) show_help ;;
        *) cli_die "Unknown option: '$1'. Use --help." ;;
    esac
}

main "$@"
