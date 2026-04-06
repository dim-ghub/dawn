#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Firefox Theme Manager - Master v1.5.0
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / Wayland (Bash 5.3.9+)
# Architecture: Cache-and-Probe with Idempotent Deployment & Matugen Sync
# -----------------------------------------------------------------------------

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ SYSTEM CONFIGURATION ▼
# =============================================================================

declare -r APP_TITLE="Dusky Firefox Themer"
declare -r APP_VERSION="v1.5.0 (Stable)"

declare -r REPO_URL="https://github.com/dim-ghub/dawn-websites/archive/refs/heads/main.tar.gz"
declare -r CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dawn_themer"

# Category Mapping Array (Target -> Tab Name)
declare -A THEME_CATEGORIES=(
    ["youtube.css"]="Video"
    ["twitch.css"]="Video"
    ["vimeo.css"]="Video"
    ["reddit.css"]="Social"
    ["twitter.css"]="Social"
    ["x.css"]="Social"
    ["github.css"]="Dev"
    ["gitlab.css"]="Dev"
    ["stackoverflow.css"]="Dev"
    ["wikipedia.css"]="Reference"
    ["wikiwand.css"]="Reference"
    ["wiki.nixos.org.css"]="Reference"
)

# =============================================================================
# ▼ BROWSER CONFIGURATION ▼
# =============================================================================

# Set to "auto" to intelligently detect installed browsers based on priority,
# or force a specific one (e.g., "firefox", "zen", "librewolf").
declare -r PREFERRED_BROWSER="auto"

# Optional: Hardcode a specific profile directory name (e.g., "dd7ma16i.default-release").
# If left empty ("") or the folder is not found, the script gracefully falls back
# to autonomous discovery based on the browser engine.
declare -r PREFERRED_PROFILE_DIR=""

# Define base configuration directories for Gecko-based engines
declare -A BROWSER_PATHS=(
    ["firefox"]="$HOME/.mozilla/firefox"
    ["zen"]="$HOME/.config/zen"
    ["zen_alt"]="$HOME/.zen"
    ["librewolf"]="$HOME/.librewolf"
)

# Precedence order when PREFERRED_BROWSER="auto"
declare -ra BROWSER_PRIORITY=("firefox" "zen" "zen_alt" "librewolf")

# =============================================================================
# ▼ UI CONFIGURATION ▼
# =============================================================================

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=38
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$(( HEADER_ROWS + 1 ))

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
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -a TABS=()
declare -i TAB_COUNT=0
declare -a TAB_ZONES=()
declare -i TAB_SCROLL_START=0
declare ORIGINAL_STTY=""
declare FF_PROFILE=""
declare STATUS_MESSAGE=""

declare -i TERM_ROWS=0
declare -i TERM_COLS=0
declare -ri MIN_TERM_COLS=$(( BOX_INNER_WIDTH + 2 ))
declare -ri MIN_TERM_ROWS=$(( HEADER_ROWS + MAX_DISPLAY_ROWS + 5 ))

# --- Click Zones for Arrows ---
declare LEFT_ARROW_ZONE=""
declare RIGHT_ARROW_ZONE=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()

# --- System Helpers ---

log_err() {
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

log_warn() {
    printf '%s[WARNING]%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2
}

set_status() {
    declare -g STATUS_MESSAGE="$1"
}

clear_status() {
    declare -g STATUS_MESSAGE=""
}

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET" 2>/dev/null || :
    if [[ -n "${ORIGINAL_STTY:-}" ]]; then
        stty "$ORIGINAL_STTY" 2>/dev/null || :
    fi
    printf '\n' 2>/dev/null || :
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

update_terminal_size() {
    local size
    if size=$(stty size < /dev/tty 2>/dev/null); then
        TERM_ROWS=${size%% *}
        TERM_COLS=${size##* }
    else
        TERM_ROWS=0
        TERM_COLS=0
    fi
}

terminal_size_ok() {
    (( TERM_COLS >= MIN_TERM_COLS && TERM_ROWS >= MIN_TERM_ROWS ))
}

draw_small_terminal_notice() {
    printf '%s%s' "$CURSOR_HOME" "$CLR_SCREEN"
    printf '%sTerminal too small%s\n' "$C_RED" "$C_RESET"
    printf '%sNeed at least:%s %d cols × %d rows\n' "$C_YELLOW" "$C_RESET" "$MIN_TERM_COLS" "$MIN_TERM_ROWS"
    printf '%sCurrent size:%s %d cols × %d rows\n' "$C_WHITE" "$C_RESET" "$TERM_COLS" "$TERM_ROWS"
    printf '%sResize the terminal, then continue. Press q to quit.%s%s' "$C_CYAN" "$C_RESET" "$CLR_EOS"
}

strip_ansi() {
    local v="$1"
    v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
    REPLY="$v"
}

# --- Core Logic Engine ---

resolve_browser_profile() {
    local base_dir=""
    local b_name

    if [[ "${PREFERRED_BROWSER:-auto}" != "auto" ]] && [[ -n "${BROWSER_PATHS[$PREFERRED_BROWSER]:-}" ]]; then
        base_dir="${BROWSER_PATHS[$PREFERRED_BROWSER]}"
    else
        for b_name in "${BROWSER_PRIORITY[@]}"; do
            if [[ -d "${BROWSER_PATHS[$b_name]}" ]]; then
                base_dir="${BROWSER_PATHS[$b_name]}"
                break
            fi
        done
    fi

    # Benign exit: Do not fail the script if no browser is installed.
    if [[ -z "$base_dir" || ! -d "$base_dir" ]]; then
        log_warn "No supported browser installation found (checked priority: ${BROWSER_PRIORITY[*]})."
        FF_PROFILE=""
        return 0
    fi

    local profile_path=""
    
    if [[ -n "${PREFERRED_PROFILE_DIR:-}" && -d "$base_dir/$PREFERRED_PROFILE_DIR" ]]; then
        profile_path="$base_dir/$PREFERRED_PROFILE_DIR"
    fi
    
    if [[ -z "$profile_path" ]]; then
        profile_path=$(find "$base_dir" -maxdepth 1 -type d -name "*.default-release" | head -n 1)
        [[ -z "$profile_path" ]] && profile_path=$(find "$base_dir" -maxdepth 1 -type d -name "*.default" | head -n 1)
    fi
    
    [[ -z "$profile_path" ]] && profile_path=$(find "$base_dir" -maxdepth 1 -type d -name "*.Default*" | head -n 1)
    [[ -z "$profile_path" ]] && profile_path=$(find "$base_dir" -maxdepth 2 -type f -name "prefs.js" -exec dirname {} \; | head -n 1)

    # Benign exit: Browser is installed but no profile initialized yet.
    if [[ -z "$profile_path" ]]; then
        log_warn "Could not determine active browser profile in $base_dir."
        FF_PROFILE=""
        return 0
    fi

    FF_PROFILE="$profile_path"
}

ensure_matugen_integration() {
    [[ -z "$FF_PROFILE" ]] && return 0
    
    local matugen_cfg="$HOME/.config/matugen/config.toml"
    [[ -f "$matugen_cfg" && -w "$matugen_cfg" ]] || return 0

    local tmp_cfg
    tmp_cfg=$(mktemp)

    export HOOK_CMD="    ln -nfs \"$HOME/.config/matugen/generated/firefox_websites.css\" \"${FF_PROFILE}/chrome/colors.css\""

    LC_ALL=C awk '
    BEGIN {
        # Dynamically define quotes to safely bypass Bash string collisions
        triple_sq = sprintf("%c%c%c", 39, 39, 39)
        triple_dq = "\"\"\""
    }
    { lines[++n] = $0 }
    END {
        start = 0; end = n; out_idx = 0; is_commented = 0;
        
        # Scan for target template block 
        for (i=1; i<=n; i++) {
            if (lines[i] ~ /^[[:space:]]*#?[[:space:]]*\[templates\.firefox_websites\]/) {
                start = i
                is_commented = (lines[i] ~ /^[[:space:]]*#/) ? 1 : 0
                for (j=i+1; j<=n; j++) {
                    if (lines[j] ~ /^[[:space:]]*#?[[:space:]]*\[/) { end = j - 1; break; }
                    if (j == n) { end = n; break; }
                }
                break
            }
        }

        # Forcefully clean any existing post_hook inside the block bounds
        if (start) {
            for (i=start; i<=end; i++) {
                if (lines[i] ~ /^[[:space:]]*#?[[:space:]]*output_path/) {
                    out_idx = i
                }
            }
            if (!out_idx) out_idx = start # Fallback insertion point
            
            for (i=start; i<=end; i++) {
                if (lines[i] ~ /^[[:space:]]*#?[[:space:]]*post_hook[[:space:]]*=/) {
                    hook_start = i
                    hook_end = i
                    
                    has_sq = index(lines[i], triple_sq)
                    has_dq = index(lines[i], triple_dq)
                    
                    if (has_sq > 0 || has_dq > 0) {
                        quote_type = (has_sq > 0) ? triple_sq : triple_dq
                        c = 0; rem = lines[i]
                        while (idx = index(rem, quote_type)) { c++; rem = substr(rem, idx + 3) }
                        if (c % 2 != 0) {
                            for (j=i+1; j<=end; j++) {
                                if (index(lines[j], quote_type) > 0) { hook_end = j; break; }
                            }
                        }
                    }
                    for (j=hook_start; j<=hook_end; j++) lines[j] = "\033DEL\033"
                    break
                }
            }
        }

        # Reconstruct file with the unconditionally enforced hook
        prefix = is_commented ? "# " : ""
        for (i=1; i<=n; i++) {
            if (lines[i] == "\033DEL\033") continue
            print lines[i]
            if (i == out_idx) {
                print prefix "post_hook = " triple_sq
                print prefix ENVIRON["HOOK_CMD"]
                print prefix triple_sq
            }
        }
    }
    ' "$matugen_cfg" > "$tmp_cfg"

    if ! cmp -s "$matugen_cfg" "$tmp_cfg"; then
        chmod --reference="$matugen_cfg" "$tmp_cfg" 2>/dev/null || true
        mv -f "$tmp_cfg" "$matugen_cfg"
    else
        rm -f "$tmp_cfg"
    fi
}

sync_cache() {
    printf '%s[*] Syncing cache from %s...%s\n' "$C_CYAN" "$REPO_URL" "$C_RESET"
    mkdir -p "$CACHE_DIR"
    local tmp_tar
    tmp_tar=$(mktemp)
    
    if ! curl -sL "$REPO_URL" -o "$tmp_tar"; then
        log_err "Failed to download repository."
        rm -f "$tmp_tar"
        exit 1
    fi
    
    # Overwrites existing templates with fresh sync
    rm -f "$CACHE_DIR"/*.css 2>/dev/null || :
    
    local tmp_dir
    tmp_dir=$(mktemp -d)
    tar -xzf "$tmp_tar" -C "$tmp_dir"
    
    find "$tmp_dir" -type f -name "*.css" -exec cp {} "$CACHE_DIR/" \;
    
    rm -f "$tmp_tar"
    rm -rf "$tmp_dir"
    printf '%s[*] Sync complete. Repository extracted to %s.%s\n' "$C_GREEN" "$CACHE_DIR" "$C_RESET"
    sleep 1
}

probe_cache() {
    local -a files=()
    if [[ -d "$CACHE_DIR" ]]; then
        mapfile -t files < <(find "$CACHE_DIR" -maxdepth 1 -type f -name "*.css" -printf "%f\n" | sort)
    fi
    
    if (( ${#files[@]} == 0 )); then
        log_err "No themes found in cache. Run with --sync to fetch."
        exit 1
    fi
    
    local file cat
    declare -A temp_cat_map
    
    for file in "${files[@]}"; do
        cat="${THEME_CATEGORIES[$file]:-Uncategorized}"
        temp_cat_map[$cat]+="$file|"
    done
    
    TABS=()
    local c
    for c in "${!temp_cat_map[@]}"; do
        TABS+=("$c")
    done
    mapfile -t TABS < <(printf "%s\n" "${TABS[@]}" | sort)
    
    TAB_COUNT=${#TABS[@]}
    
    local -i i
    for (( i = 0; i < TAB_COUNT; i++ )); do
        declare -ga "TAB_ITEMS_${i}=()"
    done
    
    local user_content=""
    [[ -n "$FF_PROFILE" ]] && user_content="$FF_PROFILE/chrome/userContent.css"
    local state="false"
    
    for (( i = 0; i < TAB_COUNT; i++ )); do
        cat="${TABS[i]}"
        IFS='|' read -ra cat_files <<< "${temp_cat_map[$cat]}"
        for file in "${cat_files[@]}"; do
            [[ -z "$file" ]] && continue
            state="false"
            if [[ -n "$user_content" && -f "$user_content" ]] && grep -qF "@import url(\"websites/$file\");" "$user_content" >/dev/null; then
                state="true"
            fi
            
            ITEM_MAP="${i}::${file}"="${file}"
            VALUE_CACHE["${i}::${file}"]="$state"
            local -n _reg_tab_ref="TAB_ITEMS_${i}"
            _reg_tab_ref+=("$file")
        done
    done
}

deploy_changes() {
    local mode="${1:-}"

    # Safely exit with success if no browser exists
    if [[ -z "$FF_PROFILE" ]]; then
        local msg="No compatible browser detected. Skipping deployment."
        if [[ "$mode" != "--headless" ]]; then
            set_status "$msg"
        else
            log_warn "$msg"
        fi
        return 0
    fi
    
    if [[ "$mode" != "--headless" ]]; then
        set_status "Deploying to Browser Profile..."
        draw_ui
    else
        printf '%s[*] Deploying to Browser Profile...%s\n' "$C_CYAN" "$C_RESET"
    fi
    
    local chrome_dir="$FF_PROFILE/chrome"
    local websites_dir="$chrome_dir/websites"
    local user_content="$chrome_dir/userContent.css"
    
    mkdir -p "$websites_dir"
    touch "$user_content"
    
    local item key val
    local -a to_import=()
    local -i i
    
    for (( i=0; i<TAB_COUNT; i++ )); do
        local -n _items="TAB_ITEMS_${i}"
        for item in "${_items[@]}"; do
            val="${VALUE_CACHE["${i}::${item}"]}"
            key="${item}"
            if [[ "$val" == "true" ]]; then
                cp -f "$CACHE_DIR/$key" "$websites_dir/"
                to_import+=("@import url(\"websites/$key\");")
            else
                rm -f "$websites_dir/$key" 2>/dev/null || :
            fi
        done
    done

    # Strict Idempotent standard: strip old theme imports, prepend new ones
    local tmp_css
    tmp_css=$(mktemp)
    
    # 1. Always enforce colors.css at the absolute top for Matugen integration
    printf '@import url("colors.css");\n' > "$tmp_css"
    
    # 2. Write the new website imports directly below colors.css
    if (( ${#to_import[@]} > 0 )); then
        printf "%s\n" "${to_import[@]}" >> "$tmp_css"
    fi
    
    # 3. Append existing content (excluding legacy dawn imports and old colors.css imports)
    grep -vE '^[[:space:]]*@import url\("?(websites/[^"]+\.css|colors\.css)"?\);' "$user_content" >> "$tmp_css" || true
    
    # 4. Replace atomically
    mv -f "$tmp_css" "$user_content"
    
    if [[ -x "$HOME/user_scripts/theme_matugen/theme_ctl.sh" ]]; then
        "$HOME/user_scripts/theme_matugen/theme_ctl.sh" refresh || true
    fi
    
    if [[ "$mode" != "--headless" ]]; then
        set_status "Deployment successful!"
    fi
}

# --- Context Helpers ---

get_active_context() {
    REPLY_CTX="${CURRENT_TAB}"
    REPLY_REF="TAB_ITEMS_${CURRENT_TAB}"
}

modify_value() {
    local label="$1"
    local REPLY_REF REPLY_CTX
    get_active_context

    local current="${VALUE_CACHE["${REPLY_CTX}::${label}"]:-false}"
    local new_val="true"
    if [[ "$current" == "true" ]]; then new_val="false"; fi

    VALUE_CACHE["${REPLY_CTX}::${label}"]="$new_val"
    set_status "Modified '${label}'. Press [Enter] to Deploy."
}

reset_defaults() {
    local item
    local -i i
    for (( i=0; i<TAB_COUNT; i++ )); do
        local -n _items="TAB_ITEMS_${i}"
        for item in "${_items[@]}"; do
            VALUE_CACHE["${i}::${item}"]="false"
        done
    done
    set_status "Selections cleared. Press [Enter] to Deploy."
}

# --- UI Rendering Engine ---

compute_scroll_window() {
    local -i count=$1
    if (( count == 0 )); then
        SELECTED_ROW=0
        SCROLL_OFFSET=0
        _vis_start=0
        _vis_end=0
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

render_item_list() {
    local -n _ril_buf=$1
    local -n _ril_items=$2
    local _ril_ctx="$3"
    local -i _ril_vs=$4 _ril_ve=$5

    local -i ri
    local item val display padded_item

    for (( ri = _ril_vs; ri < _ril_ve; ri++ )); do
        item="${_ril_items[ri]}"
        val="${VALUE_CACHE["${_ril_ctx}::${item}"]:-false}"

        case "$val" in
            true)  display="${C_GREEN}[■] ENABLED${C_RESET}" ;;
            false) display="${C_GREY}[ ] DISABLED${C_RESET}" ;;
            *)     display="${C_YELLOW}⚠ UNKNOWN${C_RESET}" ;;
        esac

        local -i max_len=$(( ITEM_PADDING - 1 ))
        if (( ${#item} > ITEM_PADDING )); then
            printf -v padded_item "%-${max_len}s…" "${item:0:max_len}"
        else
            printf -v padded_item "%-${ITEM_PADDING}s" "$item"
        fi

        if (( ri == SELECTED_ROW )); then
            _ril_buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            _ril_buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
        fi
    done

    local -i rows_rendered=$(( _ril_ve - _ril_vs ))
    for (( ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++ )); do
        _ril_buf+="${CLR_EOL}"$'\n'
    done
}

draw_ui() {
    update_terminal_size

    if ! terminal_size_ok; then
        draw_small_terminal_notice
        return
    fi

    local buf="" pad_buf=""
    local -i i current_col=3 zone_start count
    local -i left_pad right_pad vis_len
    local -i _vis_start _vis_end

    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

    strip_ansi "$APP_TITLE"; local -i t_len=${#REPLY}
    strip_ansi "$APP_VERSION"; local -i v_len=${#REPLY}
    vis_len=$(( t_len + v_len + 1 ))
    left_pad=$(( (BOX_INNER_WIDTH - vis_len) / 2 ))
    right_pad=$(( BOX_INNER_WIDTH - vis_len - left_pad ))

    printf -v pad_buf '%*s' "$left_pad" ''
    buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
    printf -v pad_buf '%*s' "$right_pad" ''
    buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

    if (( TAB_SCROLL_START > CURRENT_TAB )); then
        TAB_SCROLL_START=$CURRENT_TAB
    fi
    if (( TAB_SCROLL_START < 0 )); then
        TAB_SCROLL_START=0
    fi

    local tab_line
    local -i max_tab_width=$(( BOX_INNER_WIDTH - 6 ))

    LEFT_ARROW_ZONE=""
    RIGHT_ARROW_ZONE=""

    while true; do
        tab_line="${C_MAGENTA}│ "
        current_col=3
        TAB_ZONES=()
        local -i used_len=0

        if (( TAB_SCROLL_START > 0 )); then
            tab_line+="${C_YELLOW}«${C_RESET} "
            LEFT_ARROW_ZONE="$current_col:$(( current_col + 1 ))"
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        else
            tab_line+="  "
            used_len=$(( used_len + 2 ))
            current_col=$(( current_col + 2 ))
        fi

        for (( i = TAB_SCROLL_START; i < TAB_COUNT; i++ )); do
            local name="${TABS[i]}"
            local display_name="$name"
            local -i tab_name_len=${#name}
            local -i chunk_len=$(( tab_name_len + 4 ))
            local -i reserve=0

            if (( i < TAB_COUNT - 1 )); then reserve=2; fi

            if (( used_len + chunk_len + reserve > max_tab_width )); then
                if (( i < CURRENT_TAB || (i == CURRENT_TAB && TAB_SCROLL_START < CURRENT_TAB) )); then
                    TAB_SCROLL_START=$(( TAB_SCROLL_START + 1 ))
                    continue 2
                fi

                if (( i == CURRENT_TAB )); then
                    local -i avail_label=$(( max_tab_width - used_len - reserve - 4 ))
                    if (( avail_label < 1 )); then avail_label=1; fi

                    if (( tab_name_len > avail_label )); then
                        if (( avail_label == 1 )); then
                            display_name="…"
                        else
                            display_name="${name:0:avail_label-1}…"
                        fi
                        tab_name_len=${#display_name}
                        chunk_len=$(( tab_name_len + 4 ))
                    fi

                    zone_start=$current_col
                    tab_line+="${C_CYAN}${C_INVERSE} ${display_name} ${C_RESET}${C_MAGENTA}│ "
                    TAB_ZONES+=("${zone_start}:$(( zone_start + tab_name_len + 1 ))")
                    used_len=$(( used_len + chunk_len ))
                    current_col=$(( current_col + chunk_len ))

                    if (( i < TAB_COUNT - 1 )); then
                        tab_line+="${C_YELLOW}» ${C_RESET}"
                        RIGHT_ARROW_ZONE="$current_col:$(( current_col + 1 ))"
                        used_len=$(( used_len + 2 ))
                    fi
                    break
                fi

                tab_line+="${C_YELLOW}» ${C_RESET}"
                RIGHT_ARROW_ZONE="$current_col:$(( current_col + 1 ))"
                used_len=$(( used_len + 2 ))
                break
            fi

            zone_start=$current_col
            if (( i == CURRENT_TAB )); then
                tab_line+="${C_CYAN}${C_INVERSE} ${display_name} ${C_RESET}${C_MAGENTA}│ "
            else
                tab_line+="${C_GREY} ${display_name} ${C_MAGENTA}│ "
            fi

            TAB_ZONES+=("${zone_start}:$(( zone_start + tab_name_len + 1 ))")
            used_len=$(( used_len + chunk_len ))
            current_col=$(( current_col + chunk_len ))
        done

        local -i pad=$(( BOX_INNER_WIDTH - used_len - 1 ))
        if (( pad > 0 )); then
            printf -v pad_buf '%*s' "$pad" ''
            tab_line+="$pad_buf"
        fi

        tab_line+="${C_MAGENTA}│${C_RESET}"
        break
    done

    buf+="${tab_line}${CLR_EOL}"$'\n'
    buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

    local items_var="TAB_ITEMS_${CURRENT_TAB}"
    local -n _draw_items_ref="$items_var"
    count=${#_draw_items_ref[@]}

    compute_scroll_window "$count"
    render_scroll_indicator buf "above" "$count" "$_vis_start"
    render_item_list buf _draw_items_ref "${CURRENT_TAB}" "$_vis_start" "$_vis_end"
    render_scroll_indicator buf "below" "$count" "$_vis_end"

    buf+=$'\n'"${C_CYAN} [Tab] Category  [Space/←/→] Toggle  [r] Clear All  [Enter] Deploy  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
    if [[ -n "$STATUS_MESSAGE" ]]; then
        buf+="${C_CYAN} Status:  ${C_RED}${STATUS_MESSAGE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    elif [[ -z "$FF_PROFILE" ]]; then
        buf+="${C_CYAN} Profile: ${C_YELLOW}None detected${C_RESET}${CLR_EOL}${CLR_EOS}"
    else
        buf+="${C_CYAN} Profile: ${C_WHITE}${FF_PROFILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    fi
    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _nav_items_ref="$REPLY_REF"
    local -i count=${#_nav_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( (SELECTED_ROW + dir + count) % count ))
}

navigate_page() {
    local -i dir=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _navp_items_ref="$REPLY_REF"
    local -i count=${#_navp_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    SELECTED_ROW=$(( SELECTED_ROW + dir * MAX_DISPLAY_ROWS ))
    if (( SELECTED_ROW < 0 )); then SELECTED_ROW=0; fi
    if (( SELECTED_ROW >= count )); then SELECTED_ROW=$(( count - 1 )); fi
}

navigate_end() {
    local -i target=$1
    local REPLY_REF REPLY_CTX
    get_active_context
    local -n _nave_items_ref="$REPLY_REF"
    local -i count=${#_nave_items_ref[@]}
    if (( count == 0 )); then return 0; fi
    if (( target == 0 )); then
        SELECTED_ROW=0
    else
        SELECTED_ROW=$(( count - 1 ))
    fi
}

switch_tab() {
    local -i dir=${1:-1}
    CURRENT_TAB=$(( (CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT ))
    SELECTED_ROW=0
    SCROLL_OFFSET=0
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        SCROLL_OFFSET=0
    fi
}

handle_mouse() {
    local input="$1"
    local -i button x y i start end
    local zone

    local body="${input#'[<'}"
    if [[ "$body" == "$input" ]]; then return 0; fi

    local terminator="${body: -1}"
    if [[ "$terminator" != "M" && "$terminator" != "m" ]]; then return 0; fi

    body="${body%[Mm]}"
    local field1 field2 field3
    IFS=';' read -r field1 field2 field3 <<< "$body"
    if [[ ! "$field1" =~ ^[0-9]+$ || ! "$field2" =~ ^[0-9]+$ || ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi

    button=$field1
    x=$field2
    y=$field3

    if (( button == 64 )); then navigate -1; return 0; fi
    if (( button == 65 )); then navigate 1; return 0; fi
    if [[ "$terminator" != "M" ]]; then return 0; fi

    if (( y == TAB_ROW )); then
        if [[ -n "$LEFT_ARROW_ZONE" ]]; then
            start="${LEFT_ARROW_ZONE%%:*}"
            end="${LEFT_ARROW_ZONE##*:}"
            if (( x >= start && x <= end )); then switch_tab -1; return 0; fi
        fi

        if [[ -n "$RIGHT_ARROW_ZONE" ]]; then
            start="${RIGHT_ARROW_ZONE%%:*}"
            end="${RIGHT_ARROW_ZONE##*:}"
            if (( x >= start && x <= end )); then switch_tab 1; return 0; fi
        fi

        for (( i = 0; i < TAB_COUNT; i++ )); do
            if [[ -z "${TAB_ZONES[i]:-}" ]]; then continue; fi
            zone="${TAB_ZONES[i]}"
            start="${zone%%:*}"
            end="${zone##*:}"
            if (( x >= start && x <= end )); then
                set_tab "$(( i + TAB_SCROLL_START ))"
                return 0
            fi
        done
    fi

    local -i effective_start=$(( ITEM_START_ROW + 1 ))
    if (( y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS )); then
        local -i clicked_idx=$(( y - effective_start + SCROLL_OFFSET ))
        local -n _mouse_items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#_mouse_items_ref[@]}

        if (( clicked_idx >= 0 && clicked_idx < count )); then
            SELECTED_ROW=$clicked_idx
            if (( x > ADJUST_THRESHOLD )); then
                modify_value "${_mouse_items_ref[SELECTED_ROW]}"
            fi
        fi
    fi
    return 0
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

handle_input_router() {
    local key="$1"
    local escape_seq=""

    if [[ "$key" == $'\x1b' ]]; then
        if read_escape_seq escape_seq; then
            key="$escape_seq"
            if [[ "$key" == "" || "$key" == $'\n' ]]; then key=$'\e\n'; fi
        else
            key="ESC"
        fi
    fi

    if ! terminal_size_ok; then
        case "$key" in q|Q|$'\x03') exit 0 ;; esac
        return 0
    fi

    local -n _active_tab="TAB_ITEMS_${CURRENT_TAB}"
    local active_item=""
    if (( ${#_active_tab[@]} > 0 && SELECTED_ROW >= 0 && SELECTED_ROW < ${#_active_tab[@]} )); then
        active_item="${_active_tab[SELECTED_ROW]}"
    fi

    case "$key" in
        '[Z')                switch_tab -1; return ;;
        '[A'|'OA')           navigate -1; return ;;
        '[B'|'OB')           navigate 1; return ;;
        '[C'|'OC'|'[D'|'OD') [[ -n "$active_item" ]] && modify_value "$active_item"; return ;;
        '[5~')               navigate_page -1; return ;;
        '[6~')               navigate_page 1; return ;;
        '[H'|'[1~')          navigate_end 0; return ;;
        '[F'|'[4~')          navigate_end 1; return ;;
        '['*'<'*[Mm])        handle_mouse "$key"; return ;;
    esac

    case "$key" in
        k|K)               navigate -1 ;;
        j|J)               navigate 1 ;;
        l|L|h|H|' ')       [[ -n "$active_item" ]] && modify_value "$active_item" ;;
        g)                 navigate_end 0 ;;
        G)                 navigate_end 1 ;;
        $'\t')             switch_tab 1 ;;
        r|R)               reset_defaults ;;
        ''|$'\n')          deploy_changes ;;
        $'\x7f'|$'\x08'|$'\e\n') [[ -n "$active_item" ]] && modify_value "$active_item" ;;
        q|Q|$'\x03')       exit 0 ;;
    esac
}

run_autonomous_all() {
    local -i i
    local item
    
    printf '%s[*] Autonomously enabling all available site themes...%s\n' "$C_CYAN" "$C_RESET"
    
    for (( i=0; i<TAB_COUNT; i++ )); do
        local -n _items="TAB_ITEMS_${i}"
        for item in "${_items[@]}"; do
            VALUE_CACHE["${i}::${item}"]="true"
        done
    done
    
    deploy_changes "--headless"
    printf '%s[*] Processing complete.%s\n' "$C_GREEN" "$C_RESET"
    exit 0
}

main() {
    if (( BASH_VERSINFO[0] < 5 )); then
        log_err "Bash 5.0+ required"
        exit 1
    fi

    local do_sync=0
    local do_all=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sync) do_sync=1 ;;
            --all)  do_all=1 ;;
            --help|-h)
                printf "Usage: %s [FLAG]\n\n" "${0##*/}"
                printf "Options:\n"
                printf "  --sync      Download/sync latest themes from GitHub.\n"
                printf "  --all       Autonomously enable all available site themes.\n"
                printf "  --help      Show this help menu.\n"
                exit 0
                ;;
        esac
        shift
    done

    if (( do_sync )); then
        sync_cache
    fi

    resolve_browser_profile
    ensure_matugen_integration
    probe_cache

    if (( do_all )); then
        run_autonomous_all
    fi

    if [[ ! -t 0 ]]; then log_err "TTY required for interactive mode."; exit 1; fi

    ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
    stty -icanon -echo min 1 time 0 2>/dev/null

    printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
    trap 'draw_ui' WINCH

    local key
    while true; do
        draw_ui
        if ! IFS= read -rsn1 key; then continue; fi
        handle_input_router "$key"
    done
}

main "$@"
