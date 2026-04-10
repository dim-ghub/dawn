#!/usr/bin/env bash

set -euo pipefail
shopt -s extglob

# CRITICAL FIX: The "Locale Bomb"
# Force standard C locale for numeric operations.
export LC_NUMERIC=C

# =============================================================================
# ▼ USER CONFIGURATION ▼
# =============================================================================

declare -r CONFIG_FILE="${HOME}/.config/hypr/hypridle.conf"
declare -r APP_TITLE="Dusky Hypridle"
declare -r APP_VERSION="v3.9.1"

# Dimensions & Layout
declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=76
declare -ri ADJUST_THRESHOLD=40
declare -ri ITEM_PADDING=32

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$((HEADER_ROWS + 1))

declare -ra TABS=("Power States" "Warnings")

# "Never" Constant (2 Billion Seconds ≈ 63 Years)
declare -ri NEVER_VAL=2000000000

# Item Registration
register_items() {
	# --- Tab 0: Power States (The Important Stuff) ---
	# Note: 'max' acts as the 'Soft Max'. Crossing it triggers 'Never'.
	register 0 "1. Auto Lock (s)" 'timeout|int|listener:3|30|7200|30' "300"
	register 0 "2. Screen Off (s)" 'timeout|int|listener:4|30|7200|30' "330"
	register 0 "3. Suspend (s)" 'timeout|int|listener:5|60|14400|60' "600"

	# --- Tab 1: Warnings (The Minor Stuff) ---
	register 1 "4. Kbd Backlight (s)" 'timeout|int|listener:1|10|3600|10' "140"
	register 1 "5. Screen Dim (s)" 'timeout|int|listener:2|10|3600|10' "150"
}

# Post-Write Hook
post_write_action() {
	DIRTY_STATE=1
}

# =============================================================================
# ▲ END OF USER CONFIGURATION ▲
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
declare -r UNSET_MARKER='«unset»'

# --- State Management ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
declare -i SCROLL_OFFSET=0
declare -i DIRTY_STATE=0
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

# Temp file global
declare _TMPFILE=""

# --- Data Structures ---
declare -A ITEM_MAP=()
declare -A VALUE_CACHE=()
declare -A CONFIG_CACHE=()
declare -A DEFAULTS=()

# Initialize Tab arrays
for ((_ti = 0; _ti < TAB_COUNT; _ti++)); do
	declare -ga "TAB_ITEMS_${_ti}=()"
done
unset _ti

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

	# [CRITICAL LOGIC] Bulletproof Reload Strategy
	if ((DIRTY_STATE == 1)); then
		printf "%s[INFO]%s Changes detected. Restarting hypridle...\n" "$C_CYAN" "$C_RESET"

		# 2. Kill any manual instances to prevent duplicates
		killall hypridle 2>/dev/null || :

		# 3. Attempt service restart (systemd or OpenRC)
		if command -v systemctl >/dev/null 2>&1; then
			systemctl --user reset-failed hypridle.service 2>/dev/null || :
			if systemctl --user restart hypridle.service 2>/dev/null; then
				sleep 0.2
				if systemctl --user is-active --quiet hypridle.service; then
					printf "%s[OK]%s Service restarted successfully.\n" "$C_GREEN" "$C_RESET"
					return
				fi
			fi
		elif command -v rc-service >/dev/null 2>&1; then
			if rc-service hypridle restart 2>/dev/null; then
				sleep 0.2
				if pgrep -x hypridle >/dev/null 2>&1; then
					printf "%s[OK]%s Service restarted successfully.\n" "$C_GREEN" "$C_RESET"
					return
				fi
			fi
		fi

		# 4. SAFETY NET: Fallback to manual process
		printf "%s[WARN]%s Service restart failed. Falling back to manual process...\n" "$C_YELLOW" "$C_RESET"

		if
			hypridle >/dev/null 2>&1 &
			disown
		then
			printf "%s[OK]%s Manual fallback active.\n" "$C_GREEN" "$C_RESET"
		else
			printf "%s[FAIL]%s Could not start hypridle manually.\n" "$C_RED" "$C_RESET"
		fi
	fi
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

# --- Core Engine ---

register() {
	local -i tab_idx=$1
	local label="$2" config="$3" default_val="${4:-}"
	local key type block min max step
	IFS='|' read -r key type block min max step <<<"$config"

	case "$type" in
	bool | int | float | cycle | menu) ;;
	*)
		log_err "Invalid type for '${label}': ${type}"
		exit 1
		;;
	esac

	ITEM_MAP["${tab_idx}::${label}"]="$config"
	if [[ -n "$default_val" ]]; then DEFAULTS["${tab_idx}::${label}"]="$default_val"; fi
	local -n _reg_tab_ref="TAB_ITEMS_${tab_idx}"
	_reg_tab_ref+=("$label")
}

# [SPECIALIZED] Parser for Hypridle (Counts identical listener blocks)
populate_config_cache() {
	CONFIG_CACHE=()
	local key_part value_part

	while IFS='=' read -r key_part value_part || [[ -n "${key_part:-}" ]]; do
		if [[ -z "${key_part:-}" ]]; then continue; fi
		CONFIG_CACHE["$key_part"]="$value_part"
	done < <(LC_ALL=C awk '
        BEGIN { depth = 0 }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            # Strip inline comments for structural parsing
            clean = line
            sub(/[[:space:]]+#.*$/, "", clean)

            if (match(clean, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_raw = substr(clean, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_raw)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", block_raw)

                # Count duplicate blocks (e.g., listener)
                block_counts[block_raw]++
                current_block_id = block_raw ":" block_counts[block_raw]

                depth++
                block_stack[depth] = current_block_id
            }

            if (clean ~ /=/) {
                eq_pos = index(clean, "=")
                if (eq_pos > 0) {
                    key = substr(clean, 1, eq_pos - 1)
                    val = substr(clean, eq_pos + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    # Strip trailing inline comment from value
                    sub(/[[:space:]]+#.*$/, "", val)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    if (key != "") {
                        current_block = (depth > 0) ? block_stack[depth] : ""
                        print key "|" current_block "=" val
                    }
                }
            }

            # Count closing braces on the CLEANED line
            n = gsub(/\}/, "}", clean)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
    ' "$CONFIG_FILE")
}

# [SPECIALIZED] Atomic Writer for Hypridle (Handles listener:N notation)
write_value_to_file() {
	local key="$1" new_val="$2" block_ref="${3:-}"
	local current_val="${CONFIG_CACHE["$key|$block_ref"]:-}"
	if [[ "$current_val" == "$new_val" ]]; then return 0; fi

	# Create temp file
	if [[ -z "$_TMPFILE" ]]; then
		_TMPFILE=$(mktemp "${CONFIG_FILE}.tmp.XXXXXXXXXX")
	fi

	if [[ -n "$block_ref" ]]; then
		# Block-scoped write: listener:N notation
		local block_name="${block_ref%%:*}"
		local -i target_idx="${block_ref##*:}"
		[[ "$target_idx" == "$block_name" ]] && target_idx=1

		if ! LC_ALL=C awk -v target_block="$block_name" -v target_idx="$target_idx" \
			-v target_key="$key" -v new_value="$new_val" '
        BEGIN {
            depth = 0
            in_target = 0
            target_depth = 0
            replaced = 0
            current_block_count = 0
        }
        {
            line = $0
            clean = line
            sub(/^[[:space:]]*#.*/, "", clean)
            sub(/[[:space:]]+#.*$/, "", clean)

            # Track block opens
            tmpline = clean
            while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                block_str = substr(tmpline, RSTART, RLENGTH)
                sub(/[[:space:]]*\{/, "", block_str)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", block_str)
                depth++
                block_stack[depth] = block_str

                if (block_str == target_block) {
                    current_block_count++
                    if (current_block_count == target_idx && !in_target) {
                        in_target = 1
                        target_depth = depth
                    }
                }
                tmpline = substr(tmpline, RSTART + RLENGTH)
            }

            do_replace = 0
            if (in_target && clean ~ /=/) {
                eq_pos = index(clean, "=")
                if (eq_pos > 0) {
                    k = substr(clean, 1, eq_pos - 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                    if (k == target_key) {
                        do_replace = 1
                    }
                }
            }

            if (do_replace) {
                eq = index(line, "=")
                before_eq = substr(line, 1, eq)
                rest = substr(line, eq + 1)
                match(rest, /^[[:space:]]*/)
                space_after = substr(rest, RSTART, RLENGTH)
                print before_eq space_after new_value
                replaced = 1
            } else {
                print line
            }

            # Count closing braces on cleaned line
            n = gsub(/\}/, "}", clean)
            while (n > 0 && depth > 0) {
                if (in_target && depth == target_depth) {
                    in_target = 0
                    target_depth = 0
                }
                depth--
                n--
            }
        }
        END { exit (replaced ? 0 : 1) }
        ' "$CONFIG_FILE" >"$_TMPFILE"; then
			rm -f "$_TMPFILE" 2>/dev/null || :
			_TMPFILE=""
			return 1
		fi
	else
		# Global (no block) write
		if ! LC_ALL=C awk -v target_key="$key" -v new_value="$new_val" '
        BEGIN {
            depth = 0
            replaced = 0
        }
        {
            line = $0
            clean = line
            sub(/^[[:space:]]*#.*/, "", clean)
            sub(/[[:space:]]+#.*$/, "", clean)

            tmpline = clean
            while (match(tmpline, /[a-zA-Z0-9_.:-]+[[:space:]]*\{/)) {
                depth++
                tmpline = substr(tmpline, RSTART + RLENGTH)
            }

            do_replace = 0
            if (depth == 0 && clean ~ /=/) {
                eq_pos = index(clean, "=")
                if (eq_pos > 0) {
                    k = substr(clean, 1, eq_pos - 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                    if (k == target_key) {
                        do_replace = 1
                    }
                }
            }

            if (do_replace) {
                eq = index(line, "=")
                before_eq = substr(line, 1, eq)
                rest = substr(line, eq + 1)
                match(rest, /^[[:space:]]*/)
                space_after = substr(rest, RSTART, RLENGTH)
                print before_eq space_after new_value
                replaced = 1
            } else {
                print line
            }

            n = gsub(/\}/, "}", clean)
            while (n > 0 && depth > 0) { depth--; n-- }
        }
        END { exit (replaced ? 0 : 1) }
        ' "$CONFIG_FILE" >"$_TMPFILE"; then
			rm -f "$_TMPFILE" 2>/dev/null || :
			_TMPFILE=""
			return 1
		fi
	fi

	# CRITICAL: Use cat > target to preserve symlinks/inodes.
	cat "$_TMPFILE" >"$CONFIG_FILE"
	rm -f "$_TMPFILE"
	_TMPFILE=""

	CONFIG_CACHE["$key|$block_ref"]="$new_val"
	return 0
}

load_tab_values() {
	local -n _ltv_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local item key type block val

	for item in "${_ltv_items_ref[@]}"; do
		IFS='|' read -r key type block _ _ _ <<<"${ITEM_MAP["${CURRENT_TAB}::${item}"]}"
		val="${CONFIG_CACHE["$key|$block"]:-}"
		if [[ -z "$val" ]]; then
			VALUE_CACHE["${CURRENT_TAB}::${item}"]="$UNSET_MARKER"
		else
			VALUE_CACHE["${CURRENT_TAB}::${item}"]="$val"
		fi
	done
}

modify_value() {
	local label="$1"
	local -i direction=$2
	local key type block min max step current new_val

	IFS='|' read -r key type block min max step <<<"${ITEM_MAP["${CURRENT_TAB}::${label}"]}"
	current="${VALUE_CACHE["${CURRENT_TAB}::${label}"]:-}"

	if [[ "$current" == "$UNSET_MARKER" || -z "$current" ]]; then
		current="${DEFAULTS["${CURRENT_TAB}::${label}"]:-}"
		[[ -z "$current" ]] && current="${min:-0}"
	fi

	case "$type" in
	int)
		if [[ ! "$current" =~ ^-?[0-9]+$ ]]; then current="${min:-0}"; fi

		# Hardened Base-10 coercion (Fixes 008/009 octal crash)
		local -i int_val=0
		local _stripped="${current#-}"
		if [[ -n "$_stripped" ]]; then
			int_val=$((10#$_stripped))
		fi
		if [[ "$current" == -* ]]; then
			int_val=$((-int_val))
		fi

		local -i int_step=${step:-1}
		local -i soft_max=${max:-$NEVER_VAL}

		# v3.4 FEATURE: "Never" Logic for Timeouts
		if ((direction > 0)); then
			# Increase
			if ((int_val >= NEVER_VAL)); then
				new_val=$NEVER_VAL
			else
				int_val=$((int_val + int_step))
				# Check soft max
				if [[ -n "$max" ]] && ((int_val > soft_max)); then
					new_val=$NEVER_VAL
				else
					new_val=$int_val
				fi
			fi
		else
			# Decrease
			if ((int_val >= NEVER_VAL)); then
				# Jump back from Never to Soft Max
				if [[ -n "$max" ]]; then new_val=$soft_max; else new_val=$((NEVER_VAL - int_step)); fi
			else
				int_val=$((int_val - int_step))
				if [[ -n "$min" ]]; then
					local -i min_i=0
					local _min_s="${min#-}"
					min_i=$((10#${_min_s:-0}))
					[[ "$min" == -* ]] && min_i=$((-min_i))
					if ((int_val < min_i)); then int_val=$min_i; fi
				fi
				new_val=$int_val
			fi
		fi
		;;
	cycle)
		local -a opts
		IFS=',' read -r -a opts <<<"$min"
		local -i count=${#opts[@]} idx=0 i
		((count == 0)) && return 0
		for ((i = 0; i < count; i++)); do
			if [[ "${opts[i]}" == "$current" ]]; then
				idx=$i
				break
			fi
		done
		idx=$(((idx + direction + count) % count))
		new_val="${opts[idx]}"
		;;
	*) return 0 ;;
	esac

	if write_value_to_file "$key" "$new_val" "$block"; then
		VALUE_CACHE["${CURRENT_TAB}::${label}"]="$new_val"
		post_write_action
	fi
}

# v3.4 FEATURE: Toggle Never
toggle_never() {
	local -n _tn_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	if ((${#_tn_items_ref[@]} == 0)); then return 0; fi

	local label="${_tn_items_ref[SELECTED_ROW]}"
	local key type block min max step current new_val

	IFS='|' read -r key type block min max step <<<"${ITEM_MAP["${CURRENT_TAB}::${label}"]}"

	# Only applies to 'int' types
	if [[ "$type" != "int" ]]; then return 0; fi

	current="${VALUE_CACHE["${CURRENT_TAB}::${label}"]:-}"
	if [[ "$current" == "$UNSET_MARKER" || -z "$current" ]]; then
		current="${DEFAULTS["${CURRENT_TAB}::${label}"]:-}"
		[[ -z "$current" ]] && current="${min:-0}"
	fi

	# Logic: If current is Never, revert to default. Otherwise, set to Never.
	if [[ "$current" =~ ^[0-9]+$ ]] && ((10#$current >= NEVER_VAL)); then
		new_val="${DEFAULTS["${CURRENT_TAB}::${label}"]:-}"
		[[ -z "$new_val" ]] && new_val="${min:-0}"
	else
		new_val=$NEVER_VAL
	fi

	if write_value_to_file "$key" "$new_val" "$block"; then
		VALUE_CACHE["${CURRENT_TAB}::${label}"]="$new_val"
		post_write_action
	fi
}

reset_defaults() {
	local -n _rd_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local item def_val key type block
	local -i any_written=0

	for item in "${_rd_items_ref[@]}"; do
		def_val="${DEFAULTS["${CURRENT_TAB}::${item}"]:-}"
		if [[ -n "$def_val" ]]; then
			IFS='|' read -r key type block _ _ _ <<<"${ITEM_MAP["${CURRENT_TAB}::${item}"]}"
			if write_value_to_file "$key" "$def_val" "$block"; then
				VALUE_CACHE["${CURRENT_TAB}::${item}"]="$def_val"
				any_written=1
			fi
		fi
	done

	((any_written)) && post_write_action
	return 0
}

# --- UI Rendering Engine ---

compute_scroll_window() {
	local -i count=$1
	if ((count == 0)); then
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		_vis_start=0
		_vis_end=0
		return
	fi

	if ((SELECTED_ROW < 0)); then SELECTED_ROW=0; fi
	if ((SELECTED_ROW >= count)); then SELECTED_ROW=$((count - 1)); fi

	if ((SELECTED_ROW < SCROLL_OFFSET)); then
		SCROLL_OFFSET=$SELECTED_ROW
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

render_scroll_indicator() {
	local -n _rsi_buf=$1
	local position="$2"
	local -i count=$3 boundary=$4

	if [[ "$position" == "above" ]]; then
		if ((SCROLL_OFFSET > 0)); then
			_rsi_buf+="${C_GREY}    ▲ (more above)${CLR_EOL}${C_RESET}"$'\n'
		else
			_rsi_buf+="${CLR_EOL}"$'\n'
		fi
	else
		if ((count > MAX_DISPLAY_ROWS)); then
			local position_info="[$((SELECTED_ROW + 1))/${count}]"
			if ((boundary < count)); then
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
	local buf="" pad_buf=""
	local -i i current_col=3 zone_start len count pad_needed
	local -i left_pad right_pad vis_len
	local -i _vis_start _vis_end

	buf+="${CURSOR_HOME}"
	buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

	strip_ansi "$APP_TITLE"
	local -i t_len=${#REPLY}
	strip_ansi "$APP_VERSION"
	local -i v_len=${#REPLY}
	vis_len=$((t_len + v_len + 1))
	left_pad=$(((BOX_INNER_WIDTH - vis_len) / 2))
	right_pad=$((BOX_INNER_WIDTH - vis_len - left_pad))

	printf -v pad_buf '%*s' "$left_pad" ''
	buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
	printf -v pad_buf '%*s' "$right_pad" ''
	buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

	local tab_line="${C_MAGENTA}│ "
	TAB_ZONES=()

	for ((i = 0; i < TAB_COUNT; i++)); do
		local name="${TABS[i]}"
		len=${#name}
		zone_start=$current_col
		if ((i == CURRENT_TAB)); then
			tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
		else
			tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
		fi
		TAB_ZONES+=("${zone_start}:$((zone_start + len + 1))")
		current_col=$((current_col + len + 4))
	done

	pad_needed=$((BOX_INNER_WIDTH - current_col + 2))
	if ((pad_needed < 0)); then pad_needed=0; fi

	if ((pad_needed > 0)); then
		printf -v pad_buf '%*s' "$pad_needed" ''
		tab_line+="${pad_buf}"
	fi
	tab_line+="${C_MAGENTA}│${C_RESET}"

	buf+="${tab_line}${CLR_EOL}"$'\n'
	buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

	# Items
	local -n _draw_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	count=${#_draw_items_ref[@]}

	compute_scroll_window "$count"
	render_scroll_indicator buf "above" "$count" "$_vis_start"

	local item val display padded_item
	for ((i = _vis_start; i < _vis_end; i++)); do
		item="${_draw_items_ref[i]}"
		val="${VALUE_CACHE["${CURRENT_TAB}::${item}"]:-${UNSET_MARKER}}"

		case "$val" in
		"$UNSET_MARKER") display="${C_YELLOW}⚠ UNSET${C_RESET}" ;;
		*)
			if [[ "$val" =~ ^[0-9]+$ ]] && ((10#$val >= NEVER_VAL)); then
				display="${C_YELLOW}Never${C_RESET}"
			else
				display="${C_WHITE}${val}${C_RESET}"
			fi
			;;
		esac

		printf -v padded_item "%-${ITEM_PADDING}s" "${item:0:${ITEM_PADDING}}"
		if ((i == SELECTED_ROW)); then
			buf+="${C_CYAN} ➤ ${C_INVERSE}${padded_item}${C_RESET} : ${display}${CLR_EOL}"$'\n'
		else
			buf+="    ${padded_item} : ${display}${CLR_EOL}"$'\n'
		fi
	done

	# Fill empty rows
	local -i rows_rendered=$((_vis_end - _vis_start))
	for ((i = rows_rendered; i < MAX_DISPLAY_ROWS; i++)); do
		buf+="${CLR_EOL}"$'\n'
	done

	render_scroll_indicator buf "below" "$count" "$_vis_end"

	# v3.4: [n] Never in menu
	buf+=$'\n'"${C_CYAN} [Tab] Tab  [r] Reset  [n] Never  [←/→ h/l] Adj  [↑/↓ j/k] Nav  [q] Quit${C_RESET}${CLR_EOL}"$'\n'

	# Visual Dirty Indicator
	if ((DIRTY_STATE == 1)); then
		buf+="${C_YELLOW} ● Pending Restart${C_RESET}${CLR_EOL}${CLR_EOS}"
	else
		buf+="${C_GREY} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
	fi

	printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
	local -i dir=$1
	local -n _nav_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local -i count=${#_nav_items_ref[@]}
	if ((count == 0)); then return 0; fi
	SELECTED_ROW=$(((SELECTED_ROW + dir + count) % count))
}

navigate_page() {
	local -i dir=$1
	local -n _navp_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local -i count=${#_navp_items_ref[@]}
	if ((count == 0)); then return 0; fi
	SELECTED_ROW=$((SELECTED_ROW + dir * MAX_DISPLAY_ROWS))
	if ((SELECTED_ROW < 0)); then SELECTED_ROW=0; fi
	if ((SELECTED_ROW >= count)); then SELECTED_ROW=$((count - 1)); fi
}

navigate_end() {
	local -i target=$1
	local -n _nave_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local -i count=${#_nave_items_ref[@]}
	if ((count == 0)); then return 0; fi
	if ((target == 0)); then SELECTED_ROW=0; else SELECTED_ROW=$((count - 1)); fi
}

adjust() {
	local -i dir=$1
	local -n _adj_items_ref="TAB_ITEMS_${CURRENT_TAB}"
	if ((${#_adj_items_ref[@]} == 0)); then return 0; fi
	modify_value "${_adj_items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
	local -i dir=${1:-1}
	CURRENT_TAB=$(((CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT))
	SELECTED_ROW=0
	SCROLL_OFFSET=0
	load_tab_values
}

set_tab() {
	local -i idx=$1
	if ((idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT)); then
		CURRENT_TAB=$idx
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		load_tab_values
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
	IFS=';' read -r field1 field2 field3 <<<"$body"
	if [[ ! "$field1" =~ ^[0-9]+$ ]]; then return 0; fi
	if [[ ! "$field2" =~ ^[0-9]+$ ]]; then return 0; fi
	if [[ ! "$field3" =~ ^[0-9]+$ ]]; then return 0; fi
	button=$field1
	x=$field2
	y=$field3

	if ((button == 64)); then
		navigate -1
		return 0
	fi
	if ((button == 65)); then
		navigate 1
		return 0
	fi
	if [[ "$terminator" != "M" ]]; then return 0; fi

	if ((y == TAB_ROW)); then
		for ((i = 0; i < TAB_COUNT; i++)); do
			zone="${TAB_ZONES[i]}"
			start="${zone%%:*}"
			end="${zone##*:}"
			if ((x >= start && x <= end)); then
				set_tab "$i"
				return 0
			fi
		done
	fi

	local -i effective_start=$((ITEM_START_ROW + 1))
	if ((y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS)); then
		local -i clicked_idx=$((y - effective_start + SCROLL_OFFSET))
		local -n _mouse_items_ref="TAB_ITEMS_${CURRENT_TAB}"
		local -i count=${#_mouse_items_ref[@]}
		if ((clicked_idx >= 0 && clicked_idx < count)); then
			SELECTED_ROW=$clicked_idx
			if ((x > ADJUST_THRESHOLD)); then
				if ((button == 0)); then adjust 1; else adjust -1; fi
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

handle_key() {
	local key="$1"
	case "$key" in
	'[Z')
		switch_tab -1
		return
		;;
	'[A' | 'OA')
		navigate -1
		return
		;;
	'[B' | 'OB')
		navigate 1
		return
		;;
	'[C' | 'OC')
		adjust 1
		return
		;;
	'[D' | 'OD')
		adjust -1
		return
		;;
	'[5~')
		navigate_page -1
		return
		;;
	'[6~')
		navigate_page 1
		return
		;;
	'[H' | '[1~')
		navigate_end 0
		return
		;;
	'[F' | '[4~')
		navigate_end 1
		return
		;;
	'['*'<'*[Mm])
		handle_mouse "$key"
		return
		;;
	esac

	case "$key" in
	k | K) navigate -1 ;;
	j | J) navigate 1 ;;
	l | L) adjust 1 ;;
	h | H) adjust -1 ;;
	g) navigate_end 0 ;;
	G) navigate_end 1 ;;
	n | N) toggle_never ;;
	$'\t') switch_tab 1 ;;
	r | R) reset_defaults ;;
	'' | $'\n') adjust 1 ;;
	$'\x7f' | $'\x08' | $'\e\n') adjust -1 ;;
	q | Q | $'\x03') exit 0 ;;
	esac
}

handle_input_router() {
	local key="$1"
	local escape_seq=""

	if [[ "$key" == $'\x1b' ]]; then
		if read_escape_seq escape_seq; then
			key="$escape_seq"
			if [[ "$key" == "" || "$key" == $'\n' ]]; then
				key=$'\e\n'
			fi
		else
			# Bare ESC - no action in this single-view TUI
			return
		fi
	fi

	handle_key "$key"
}

# --- Main ---

main() {
	if ((BASH_VERSINFO[0] < 5)); then
		log_err "Bash 5.0+ required (found ${BASH_VERSION})"
		exit 1
	fi
	if [[ ! -t 0 ]]; then
		log_err "TTY required"
		exit 1
	fi
	if [[ ! -f "$CONFIG_FILE" ]]; then
		log_err "Config file not found at $CONFIG_FILE"
		log_err "Please ensure hypridle is installed and config is generated."
		exit 1
	fi
	if [[ ! -w "$CONFIG_FILE" ]]; then
		log_err "Config not writable: $CONFIG_FILE"
		exit 1
	fi

	local _dep
	for _dep in awk; do
		if ! command -v "$_dep" &>/dev/null; then
			log_err "Missing dependency: ${_dep}"
			exit 1
		fi
	done

	# Pre-flight check: resurrect dead service
	if command -v systemctl >/dev/null 2>&1; then
		if systemctl --user is-failed --quiet hypridle.service 2>/dev/null; then
			systemctl --user reset-failed hypridle.service 2>/dev/null || :
		fi
	elif command -v rc-service >/dev/null 2>&1; then
		if ! pgrep -x hypridle >/dev/null 2>&1; then
			rc-service hypridle start 2>/dev/null || hypridle &>/dev/null &
		fi
	fi

	register_items
	populate_config_cache

	ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
	stty -icanon -echo min 1 time 0 2>/dev/null

	printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
	load_tab_values

	local key
	while true; do
		draw_ui
		IFS= read -rsn1 key || break
		handle_input_router "$key"
	done
}

main "$@"
