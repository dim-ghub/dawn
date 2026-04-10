#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Hyprlock Manager v4.3.0
# -----------------------------------------------------------------------------
# Source A: Dusky TUI Engine v3.9.1 (Rendering, Input, Safety)
# Source B: Hyprlock Theme Manager v2.0.0 (Logic, Discovery)
#
# v4.3.0 CHANGELOG:
#   - CRITICAL: Replaced sed-based source write with atomic awk processing.
#   - FIX: Preserves symlinks during write (cat > target instead of mv).
#   - FIX: Mouse click row targeting now accounts for scroll indicator offset.
#   - FIX: Mouse field validation prevents crashes on malformed sequences.
#   - FIX: Empty theme list guard on Enter/click apply.
#   - FIX: ESC_READ_TIMEOUT increased to 0.10 for SSH/remote reliability.
#   - FIX: Secure temp file cleanup in cleanup().
#   - FIX: Added TTY check before interactive startup.
#   - CLEAN: Removed sed dependency and escape helpers (no longer needed).
#
# FEATURES:
#   - Pure Theme Switching (No tabs)
#   - Tilde (~) Path Preservation
#   - Full Vim/Arrow/Page Navigation
#   - Configurable Mouse Hitbox
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

# Paths
declare -r HYPR_DIR="${HOME}/.config/hypr"
declare -r CONFIG_FILE="${HYPR_DIR}/hyprlock.conf"
declare -r THEMES_DIR="${HYPR_DIR}/hyprlock_themes"

# UI Settings
declare -r APP_TITLE="Dusky Hyprlock Manager"
declare -r APP_VERSION="v4.3.0"

# Dimensions
declare -ri MAX_DISPLAY_ROWS=12
declare -ri BOX_INNER_WIDTH=80
declare -ri ITEM_PADDING=50
declare -ri HEADER_ROWS=4
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 0 ))

# MOUSE CONTROL
# 82 = Full width. Set to ~38 to restrict clicks to the text area.
declare -ri MOUSE_HITBOX_LIMIT=82

# =============================================================================
# ▲ END USER CONFIGURATION ▲
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

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i SCROLL_OFFSET=0
declare -i PREVIEW_ENABLED=0
declare ORIGINAL_STTY=""

# Temp file global
declare _TMPFILE=""

# --- Data Structures ---
declare -a THEME_LIST=()
declare -A THEME_PATHS=()
declare ACTIVE_THEME=""

# --- System Helpers ---

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

# --- Initialization & Logic ---

init_themes() {
    local config_file dir name
    THEME_LIST=()

    if [[ ! -d "$THEMES_DIR" ]]; then
        return
    fi

    while IFS= read -r -d '' config_file; do
        dir="${config_file%/*}"
        name=""
        if [[ -f "${dir}/theme.json" ]] && command -v jq &>/dev/null; then
            name=$(jq -r '.name // empty' "${dir}/theme.json" 2>/dev/null) || true
        fi
        [[ -z "$name" ]] && name="${dir##*/}"

        THEME_LIST+=("$name")
        THEME_PATHS["$name"]="$dir"
    done < <(find "$THEMES_DIR" -mindepth 2 -maxdepth 2 -name "hyprlock.conf" -print0 | sort -z)
}

detect_active_theme() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi

    local source_path resolved_path
    source_path=$(grep '^[[:space:]]*source[[:space:]]*=' "$CONFIG_FILE" | head -n1 | cut -d'=' -f2-)

    source_path="${source_path#"${source_path%%[![:space:]]*}"}"
    source_path="${source_path%"${source_path##*[![:space:]]}"}"

    if [[ "$source_path" == "~"* ]]; then
        resolved_path="${HOME}${source_path:1}"
    else
        resolved_path="$source_path"
    fi

    local name path
    ACTIVE_THEME=""
    for name in "${THEME_LIST[@]}"; do
        path="${THEME_PATHS[$name]}/hyprlock.conf"
        if [[ "$path" == "$resolved_path" ]]; then
            ACTIVE_THEME="$name"
            return
        fi
    done
}

apply_theme() {
    local theme_name="$1"
    local theme_dir="${THEME_PATHS[$theme_name]:-}"
    [[ -z "$theme_dir" ]] && return

    local source_path="${theme_dir}/hyprlock.conf"
    if [[ ! -r "$source_path" ]]; then return; fi

    local tilde_path="${source_path/#"$HOME"/\~}"

    # Create temp file
    if [[ -z "$_TMPFILE" ]]; then
        _TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX")
    fi

    if ! LC_ALL=C awk -v new_source="$tilde_path" '
    {
        line = $0
        clean = line
        sub(/^[[:space:]]*#.*/, "", clean)

        if (clean ~ /^[[:space:]]*source[[:space:]]*=/) {
            # Preserve leading whitespace
            match(line, /^[[:space:]]*/)
            leading = substr(line, RSTART, RLENGTH)
            eq = index(line, "=")
            before_eq = substr(line, 1, eq)
            rest = substr(line, eq + 1)
            match(rest, /^[[:space:]]*/)
            space_after = substr(rest, RSTART, RLENGTH)
            print before_eq space_after new_source
            replaced = 1
        } else {
            print line
        }
    }
    ' "$CONFIG_FILE" > "$_TMPFILE"; then
        rm -f "$_TMPFILE" 2>/dev/null || :
        _TMPFILE=""
        return 1
    fi

    # CRITICAL: Use cat > target to preserve symlinks/inodes.
    cat "$_TMPFILE" > "$CONFIG_FILE"
    rm -f "$_TMPFILE"
    _TMPFILE=""

    ACTIVE_THEME="$theme_name"
}

# --- Scroll Window (Template Engine) ---

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

# --- Scroll Indicators (Template Engine) ---

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

# --- UI Rendering ---

draw_ui() {
    local buf="" pad_buf="" padded_item="" item display
    local -i i count rows_rendered
    local -i visible_len left_pad right_pad
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    visible_len=$(( ${#APP_TITLE} + ${#APP_VERSION} + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - visible_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - visible_len - left_pad ))
    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    buf+="${C_MAGENTA}├${H_LINE}┤${C_RESET}${CLR_EOL}"$'\n'

    count=${#THEME_LIST[@]}

    compute_scroll_window "$count"
    render_scroll_indicator buf "above" "$count" "$_vis_start"

    for (( i = _vis_start; i < _vis_end; i++ )); do
        item="${THEME_LIST[i]}"
        if [[ "$item" == "$ACTIVE_THEME" ]]; then
            display="${C_GREEN}● ACTIVE${C_RESET}"
        else
            display="${C_GREY}○${C_RESET}"
        fi

        printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:${ITEM_PADDING}}"
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} ${display}${CLR_EOL}"$'\n'
        else
            buf+="    ${padded_item} ${display}${CLR_EOL}"$'\n'
        fi
    done

    rows_rendered=$(( _vis_end - _vis_start ))
    for (( i = rows_rendered; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'
    buf+="${C_CYAN} [Ent] Apply  [p] Preview  [j/k] Nav  [g/G] Top/Bot  [q] Quit${C_RESET}${CLR_EOL}"$'\n'

    if (( PREVIEW_ENABLED )); then
        local theme_name="${THEME_LIST[SELECTED_ROW]}"
        local conf="${THEME_PATHS[$theme_name]}/hyprlock.conf"
        buf+="${C_MAGENTA}── Preview: ${C_WHITE}${theme_name}${C_MAGENTA} ──${C_RESET}${CLR_EOL}"$'\n'
        if [[ -r "$conf" ]]; then
            local p_line; local -i pcount=0
            while (( pcount < 6 )) && IFS= read -r p_line; do
                buf+="  ${C_GREY}${p_line:0:76}${C_RESET}${CLR_EOL}"$'\n'
                (( pcount++ )) || true
            done < "$conf"
        else
            buf+="  ${C_RED}(No config found)${C_RESET}${CLR_EOL}"$'\n'
        fi
    else
        buf+="${CLR_EOL}"$'\n'
    fi
    buf+="${CLR_EOS}"
    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_page() {
    local -i dir=$1
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

navigate_end() {
    local -i target=$1
    local -i count=${#THEME_LIST[@]}
    (( count == 0 )) && return 0
    if (( target == 0 )); then SELECTED_ROW=0; else SELECTED_ROW=$(( count - 1 )); fi
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
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
    if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
    button=$field1; x=$field2; y=$field3

    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    if (( x > MOUSE_HITBOX_LIMIT )); then return 0; fi

    # Account for scroll indicator row between header and items
    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))
        local -i count=${#THEME_LIST[@]}
        if (( clicked_idx >= 0 && clicked_idx < count )); then
            SELECTED_ROW=$clicked_idx
            if (( button == 0 )); then
                apply_theme "${THEME_LIST[SELECTED_ROW]}"
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

# --- Input Router (Template Pattern) ---

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
        else
            # Bare ESC pressed — no action in this view
            return
        fi
    fi

    case "$key" in
        '[A'|'OA')           navigate -1 ;;
        '[B'|'OB')           navigate 1 ;;
        '[5~')               navigate_page -1 ;;
        '[6~')               navigate_page 1 ;;
        '[H'|'[1~')          navigate_end 0 ;;
        '[F'|'[4~')          navigate_end 1 ;;
        '['*'<'*[Mm])        handle_mouse "$key" ;;
        k|K)                 navigate -1 ;;
        j|J)                 navigate 1 ;;
        g)                   navigate_end 0 ;;
        G)                   navigate_end 1 ;;
        $'\r'|'')
            if (( ${#THEME_LIST[@]} > 0 )); then
                apply_theme "${THEME_LIST[SELECTED_ROW]}"
            fi
            ;;
        p|P)                 PREVIEW_ENABLED=$(( 1 - PREVIEW_ENABLED )) ;;
        q|Q|$'\x03')         exit 0 ;;
    esac
}

# --- Main ---

main() {
    if (( BASH_VERSINFO[0] < 5 )); then log_err "Bash 5.0+ required"; exit 1; fi
    if [[ ! -t 0 ]]; then log_err "TTY required"; exit 1; fi

    local _dep
    for _dep in awk find sort grep; do
        if ! command -v "$_dep" &>/dev/null; then
            log_err "Missing dependency: ${_dep}"; exit 1
        fi
    done

    init_themes
    detect_active_theme

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

    local key
    while true; do
        draw_ui
        IFS= read -rsn1 key || break
        handle_input_router "$key"
    done
}

main "$@"
