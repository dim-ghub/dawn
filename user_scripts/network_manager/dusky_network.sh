#!/usr/bin/env bash
# ==============================================================================
#  Dusky NETWORK- Arch Linux / Hyprland WiFi Manager
#  Engine: Dusky TUI Pattern v3.9.1 (Faithful Adaptation)
#  Target: Bash 5.0+ / Arch Linux / Hyprland / UWSM / Wayland
#  Dependencies: networkmanager (nmcli), coreutils, awk
#
#  v3.0.1 CHANGELOG:
#    - CRITICAL FIX: (( attempts++ )) returns 1 when attempts=0, killed by set -e.
#      Replaced with (( attempts += 1 )) and guarded all arithmetic.
#    - FIX: navigate() skip logic rewired to handle wrapping without infinite loop.
#    - FIX: Detail view info items are truly non-selectable; cursor always lands
#      on first actionable item.
#    - FIX: eval-based array assignment replaced with safe nameref pattern.
#    - FIX: All arithmetic expressions guarded against set -e false-zero exits.
#    - AUDIT: Full line-by-line trace analysis against bash -x output.
# ==============================================================================

set -euo pipefail
shopt -s extglob

# =============================================================================
# ▼ CONFIGURATION ▼
# =============================================================================

declare -r APP_TITLE="Dusky Network"
declare -r APP_VERSION="v3.0.1"

declare -ri MAX_DISPLAY_ROWS=14
declare -ri BOX_INNER_WIDTH=72
declare -ri ITEM_PADDING=36

declare -ri HEADER_ROWS=4
declare -ri TAB_ROW=3
declare -ri ITEM_START_ROW=$((HEADER_ROWS + 1))

declare -ra TABS=("Networks" "Saved" "Hotspot" "Status")

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
declare -ri TAB_COUNT=${#TABS[@]}
declare -a TAB_ZONES=()
declare ORIGINAL_STTY=""

declare -i CURRENT_VIEW=0
declare -i PARENT_ROW=0
declare -i PARENT_SCROLL=0
declare DETAIL_TITLE=""
declare DETAIL_CTX=""

# Per-tab item and display arrays
for ((_ti = 0; _ti < TAB_COUNT; _ti++)); do
	declare -ga "TAB_ITEMS_${_ti}=()"
	declare -ga "TAB_DISPLAY_${_ti}=()"
done
unset _ti

# Detail/drilldown arrays
declare -a DETAIL_ITEMS=()
declare -a DETAIL_DISPLAY=()
# Tracks which detail indices are actionable (not info/separator)
declare -a DETAIL_ACTIONABLE=()

# --- Network Data ---
declare -A SAVED_CONNS=()
declare -a SCAN_SSIDS=()
declare -a SCAN_SECURITY=()
declare -a SCAN_SIGNALS=()
declare -a SCAN_STATES=()
declare -a SCAN_UUIDS=()

declare -a SAVED_NAMES=()
declare -a SAVED_UUIDS_LIST=()
declare -a SAVED_AUTOCONNECT=()

# Cached status
declare CACHED_RADIO=""
declare CACHED_SSID=""
declare HOTSPOT_ACTIVE="no"
declare HOTSPOT_SSID=""
declare HOTSPOT_IF=""
declare -i DATA_LOADED=0

# ==============================================================================
#  SYSTEM HELPERS
# ==============================================================================

log_err() {
	printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
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

strip_ansi() {
	local v="$1"
	v="${v//$'\033'\[*([0-9;:?<=>])@([@A-Z\[\\\]^_\`a-z\{|\}~])/}"
	REPLY="$v"
}

notify() {
	local -r title="${1:-Notification}"
	local -r body="${2:-}"
	if command -v notify-send &>/dev/null; then
		notify-send -a "Network Architect" -u low -i network-wireless "$title" "$body" &
		disown "$!" 2>/dev/null || :
	fi
}

signal_to_bar() {
	local -i sig="${1:-0}"
	if ((sig >= 80)); then
		REPLY="▂▄▆█"
	elif ((sig >= 60)); then
		REPLY="▂▄▆_"
	elif ((sig >= 40)); then
		REPLY="▂▄__"
	elif ((sig >= 20)); then
		REPLY="▂___"
	else
		REPLY="____"
	fi
}

signal_color() {
	local -i sig="${1:-0}"
	if ((sig >= 70)); then
		REPLY="$C_GREEN"
	elif ((sig >= 40)); then
		REPLY="$C_YELLOW"
	else
		REPLY="$C_RED"
	fi
}

# ==============================================================================
#  INTERACTIVE MODE SWITCHING
# ==============================================================================

enter_interactive() {
	printf '%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" 2>/dev/null || :
	if [[ -n "${ORIGINAL_STTY:-}" ]]; then
		stty "$ORIGINAL_STTY" 2>/dev/null || :
	fi
}

leave_interactive() {
	ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
	stty -icanon -echo min 1 time 0 2>/dev/null
	printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"
}

run_with_feedback() {
	local -r msg="$1"
	shift
	printf '%s➜ %s...%s ' "$C_MAGENTA" "$msg" "$C_RESET"
	if "$@" &>/dev/null; then
		printf '%s[OK]%s\n' "$C_GREEN" "$C_RESET"
		return 0
	else
		printf '%s[FAILED]%s\n' "$C_RED" "$C_RESET"
		return 1
	fi
}

# ==============================================================================
#  NETWORKMANAGER CORE
# ==============================================================================

get_radio_status() { nmcli radio wifi 2>/dev/null || echo "unknown"; }

get_active_ssid() {
	nmcli --terse --fields active,ssid device wifi list 2>/dev/null |
		awk -F: '$1=="yes"{print $2;exit}'
}

find_wifi_device() {
	nmcli --terse --fields DEVICE,TYPE device status 2>/dev/null |
		awk -F: '$2=="wifi"{print $1;exit}'
}

refresh_cached_status() {
	CACHED_RADIO=$(get_radio_status)
	CACHED_SSID=$(get_active_ssid) || CACHED_SSID=""
	DATA_LOADED=1

	HOTSPOT_ACTIVE="no"
	HOTSPOT_SSID=""
	HOTSPOT_IF=$(find_wifi_device) || HOTSPOT_IF=""

	local line name type mode
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		type="${line##*:}"
		[[ "$type" != "802-11-wireless" ]] && continue
		name="${line%%:*}"
		mode=$(nmcli --terse --fields 802-11-wireless.mode connection show "$name" 2>/dev/null | awk -F: '{print $2}') || mode=""
		if [[ "$mode" == "ap" ]]; then
			HOTSPOT_ACTIVE="yes"
			HOTSPOT_SSID="$name"
			break
		fi
	done < <(nmcli --terse --fields NAME,UUID,TYPE connection show --active 2>/dev/null)
}

load_saved_connections() {
	SAVED_CONNS=()
	local line name uuid type
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		type="${line##*:}"
		[[ "$type" != "802-11-wireless" ]] && continue
		line="${line%:802-11-wireless}"
		if ((${#line} >= 37)); then
			uuid="${line: -36}"
			name="${line:0:$((${#line} - 37))}"
			if [[ -n "$name" && "$uuid" =~ ^[a-f0-9-]{36}$ ]]; then
				SAVED_CONNS["$name"]="$uuid"
			fi
		fi
	done < <(nmcli --terse --fields NAME,UUID,TYPE connection show 2>/dev/null)
}

forget_network() {
	local -r identifier="${1:?}"
	local -r id_type="${2:-uuid}"
	nmcli connection delete "$id_type" "$identifier" &>/dev/null
}

# ==============================================================================
#  SAFE ARRAY POPULATION HELPERS
# ==============================================================================

# These replace dangerous eval-based array assignment.
# Uses nameref to safely populate TAB_ITEMS_N and TAB_DISPLAY_N.

_set_tab_data() {
	local -i tab_idx=$1
	shift
	# Remaining args: pairs of (item display)
	local -n _items="TAB_ITEMS_${tab_idx}"
	local -n _display="TAB_DISPLAY_${tab_idx}"
	_items=()
	_display=()
	while (($# >= 2)); do
		_items+=("$1")
		_display+=("$2")
		shift 2
	done
}

# ==============================================================================
#  TAB DATA POPULATION
# ==============================================================================

populate_tab_networks() {
	load_saved_connections
	SCAN_SSIDS=()
	SCAN_SECURITY=()
	SCAN_SIGNALS=()
	SCAN_STATES=()
	SCAN_UUIDS=()

	local -a pairs=()
	local -A seen=()
	local in_use ssid security signal

	while IFS=: read -r in_use ssid security signal; do
		[[ -z "$ssid" ]] && continue
		[[ -v "seen[$ssid]" ]] && continue
		seen["$ssid"]=1
		signal="${signal//[^0-9]/}"
		[[ -z "$signal" ]] && signal="0"

		local state="New" icon="○"
		if [[ "$in_use" == "*" ]]; then
			state="Active"
			icon="●"
		elif [[ -v "SAVED_CONNS[$ssid]" ]]; then
			state="Saved"
			icon="◉"
		fi

		signal_to_bar "$signal"
		local bar="$REPLY"
		signal_color "$signal"
		local scol="$REPLY"

		local sec_short="${security:-Open}"
		[[ "$sec_short" == "--" ]] && sec_short="Open"

		local disp_line
		printf -v disp_line '%s %-6s %-22.22s %-10.10s %s%3s%% %s%s' \
			"$icon" "$state" "$ssid" "$sec_short" "$scol" "$signal" "$bar" "$C_RESET"

		SCAN_SSIDS+=("$ssid")
		SCAN_SECURITY+=("$sec_short")
		SCAN_SIGNALS+=("$signal")
		SCAN_STATES+=("$state")
		SCAN_UUIDS+=("${SAVED_CONNS[$ssid]:-}")

		pairs+=("$ssid" "$disp_line")
	done < <(nmcli --terse --fields IN-USE,SSID,SECURITY,SIGNAL device wifi list --rescan yes 2>/dev/null)

	_set_tab_data 0 "${pairs[@]}"
}

populate_tab_saved() {
	load_saved_connections
	SAVED_NAMES=()
	SAVED_UUIDS_LIST=()
	SAVED_AUTOCONNECT=()

	local -a pairs=()
	local line name uuid type autocon

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		type="${line##*:}"
		[[ "$type" != "802-11-wireless" ]] && continue
		line="${line%:802-11-wireless}"
		if ((${#line} >= 37)); then
			uuid="${line: -36}"
			name="${line:0:$((${#line} - 37))}"
			if [[ -n "$name" && "$uuid" =~ ^[a-f0-9-]{36}$ ]]; then
				autocon=$(nmcli --terse --fields connection.autoconnect connection show uuid "$uuid" 2>/dev/null | awk -F: '{print $2}') || autocon="yes"
				[[ -z "$autocon" ]] && autocon="yes"

				SAVED_NAMES+=("$name")
				SAVED_UUIDS_LIST+=("$uuid")
				SAVED_AUTOCONNECT+=("$autocon")

				local ac_display
				if [[ "$autocon" == "yes" ]]; then
					ac_display="${C_GREEN}auto${C_RESET}"
				else
					ac_display="${C_GREY}manual${C_RESET}"
				fi

				local is_active=""
				[[ "$name" == "$CACHED_SSID" ]] && is_active="${C_GREEN}● ${C_RESET}"

				local disp
				printf -v disp '%s%-28.28s  %s' "$is_active" "$name" "$ac_display"

				pairs+=("$name" "$disp")
			fi
		fi
	done < <(nmcli --terse --fields NAME,UUID,TYPE connection show 2>/dev/null)

	_set_tab_data 1 "${pairs[@]}"
}

populate_tab_hotspot() {
	local -a pairs=()

	if [[ "$HOTSPOT_ACTIVE" == "yes" ]]; then
		pairs+=(
			"Stop Hotspot" "${C_RED}■${C_RESET}  Stop current hotspot"
			"Show Hotspot Info" "${C_CYAN}ℹ${C_RESET}  View hotspot details & clients"
		)
	else
		pairs+=(
			"Start Hotspot (2.4 GHz)" "${C_GREEN}▶${C_RESET}  Create AP on 2.4 GHz band"
			"Start Hotspot (5 GHz)" "${C_GREEN}▶${C_RESET}  Create AP on 5 GHz band"
		)
	fi

	_set_tab_data 2 "${pairs[@]}"
}

populate_tab_status() {
	local -a pairs=()

	if [[ "$CACHED_RADIO" == "enabled" ]]; then
		pairs+=("Toggle Radio" "${C_GREEN}WiFi Radio: ON${C_RESET}  — select to disable")
	elif [[ "$CACHED_RADIO" == "disabled" ]]; then
		pairs+=("Toggle Radio" "${C_RED}WiFi Radio: OFF${C_RESET}  — select to enable")
	else
		pairs+=("Toggle Radio" "${C_YELLOW}WiFi Radio: ${CACHED_RADIO}${C_RESET}")
	fi

	if [[ -n "$CACHED_SSID" ]]; then
		pairs+=(
			"Connection Info" "${C_GREEN}●${C_RESET}  Connected: ${C_WHITE}${CACHED_SSID}${C_RESET}"
			"Disconnect" "${C_RED}✕${C_RESET}  Disconnect from ${CACHED_SSID}"
		)
	else
		pairs+=("Connection Info" "${C_GREY}○${C_RESET}  Not connected")
	fi

	local wifi_dev
	wifi_dev=$(find_wifi_device) || wifi_dev=""
	if [[ -n "$wifi_dev" ]]; then
		local ip_addr
		ip_addr=$(nmcli --terse --fields IP4.ADDRESS device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || ip_addr=""
		pairs+=("Device Info" "${C_CYAN}⚙${C_RESET}  Device: ${wifi_dev}  IP: ${ip_addr:-N/A}")
	fi

	local dns=""
	if [[ -n "$wifi_dev" ]]; then
		dns=$(nmcli --terse --fields IP4.DNS device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || dns=""
	fi
	if [[ -n "$dns" ]]; then
		pairs+=("DNS Info" "${C_CYAN}◆${C_RESET}  DNS: ${dns}")
	fi

	if [[ "$HOTSPOT_ACTIVE" == "yes" ]]; then
		pairs+=("Hotspot Status" "${C_YELLOW}⊛${C_RESET}  Hotspot active: ${HOTSPOT_SSID}")
	fi

	pairs+=("Refresh" "${C_MAGENTA}⟳${C_RESET}  Refresh all status information")

	_set_tab_data 3 "${pairs[@]}"
}

populate_current_tab() {
	case $CURRENT_TAB in
	0) populate_tab_networks ;;
	1) populate_tab_saved ;;
	2) populate_tab_hotspot ;;
	3) populate_tab_status ;;
	esac
}

populate_all_tabs() {
	refresh_cached_status
	local -i save_tab=$CURRENT_TAB
	local -i t
	for ((t = 0; t < TAB_COUNT; t++)); do
		CURRENT_TAB=$t
		populate_current_tab
	done
	CURRENT_TAB=$save_tab
}

# ==============================================================================
#  LOADING FRAME
# ==============================================================================

draw_loading_frame() {
	local -r msg="$1"
	local -r sub="${2:-}"
	local buf="" pad_buf=""
	local -i left_pad right_pad

	buf+="${CURSOR_HOME}"
	buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

	strip_ansi "$APP_TITLE"
	local -i t_len=${#REPLY}
	strip_ansi "$APP_VERSION"
	local -i v_len=${#REPLY}
	local -i vis_len=$((t_len + v_len + 1))
	left_pad=$(((BOX_INNER_WIDTH - vis_len) / 2))
	right_pad=$((BOX_INNER_WIDTH - vis_len - left_pad))
	((left_pad < 0)) && left_pad=0
	((right_pad < 0)) && right_pad=0

	printf -v pad_buf '%*s' "$left_pad" ''
	buf+="${C_MAGENTA}│${pad_buf}${C_WHITE}${APP_TITLE} ${C_CYAN}${APP_VERSION}${C_MAGENTA}"
	printf -v pad_buf '%*s' "$right_pad" ''
	buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

	printf -v pad_buf '%*s' "$BOX_INNER_WIDTH" ''
	buf+="${C_MAGENTA}│${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'
	buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'
	buf+="${CLR_EOL}"$'\n'

	strip_ansi "$msg"
	local -i m_len=${#REPLY}
	left_pad=$(((BOX_INNER_WIDTH - m_len - 3) / 2))
	((left_pad < 4)) && left_pad=4
	printf -v pad_buf '%*s' "$left_pad" ''
	buf+="${pad_buf}${C_MAGENTA}⟳  ${msg}${C_RESET}${CLR_EOL}"$'\n'

	if [[ -n "$sub" ]]; then
		strip_ansi "$sub"
		local -i s_len=${#REPLY}
		left_pad=$(((BOX_INNER_WIDTH - s_len) / 2))
		((left_pad < 4)) && left_pad=4
		printf -v pad_buf '%*s' "$left_pad" ''
		buf+="${pad_buf}${C_GREY}${sub}${C_RESET}${CLR_EOL}"$'\n'
	fi

	buf+="${CLR_EOS}"
	printf '%s' "$buf"
}

# ==============================================================================
#  UI RENDERING ENGINE
# ==============================================================================

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
	((max_scroll < 0)) && max_scroll=0
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

# Renders rich display lines with proper selection highlighting.
# For selected row: strips ANSI, pads, renders with INVERSE.
# For unselected: renders display string with trailing C_RESET.
render_display_list() {
	local -n _rdl_buf=$1
	local -n _rdl_display=$2
	local -i _rdl_vs=$3 _rdl_ve=$4
	local -i ri

	for ((ri = _rdl_vs; ri < _rdl_ve; ri++)); do
		local disp="${_rdl_display[ri]}"
		if ((ri == SELECTED_ROW)); then
			strip_ansi "$disp"
			local plain="$REPLY"
			local -i pad_len=$((ITEM_PADDING + 20))
			printf -v plain "%-${pad_len}s" "$plain"
			_rdl_buf+="${C_CYAN} ➤ ${C_INVERSE}${plain}${C_RESET}${CLR_EOL}"$'\n'
		else
			_rdl_buf+="    ${disp}${C_RESET}${CLR_EOL}"$'\n'
		fi
	done

	local -i rows_rendered=$((_rdl_ve - _rdl_vs))
	for ((ri = rows_rendered; ri < MAX_DISPLAY_ROWS; ri++)); do
		_rdl_buf+="${CLR_EOL}"$'\n'
	done
}

draw_main_view() {
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

	# Tab bar (Template Pattern)
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
	((pad_needed < 0)) && pad_needed=0
	if ((pad_needed > 0)); then
		printf -v pad_buf '%*s' "$pad_needed" ''
		tab_line+="${pad_buf}"
	fi
	tab_line+="${C_MAGENTA}│${C_RESET}"
	buf+="${tab_line}${CLR_EOL}"$'\n'
	buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

	# Status bar
	if ((DATA_LOADED)); then
		local status_str=""
		if [[ "$CACHED_RADIO" == "disabled" ]]; then
			status_str="${C_RED} 睊 Radio OFF${C_RESET}"
		elif [[ -n "$CACHED_SSID" ]]; then
			status_str="${C_GREEN} ● ${CACHED_SSID}${C_RESET}"
		else
			status_str="${C_GREY} ○ Disconnected${C_RESET}"
		fi
		[[ "$HOTSPOT_ACTIVE" == "yes" ]] && status_str+="  ${C_YELLOW}⊛ AP:${HOTSPOT_SSID}${C_RESET}"
		buf+=" ${status_str}${CLR_EOL}"$'\n'
	else
		buf+="${CLR_EOL}"$'\n'
	fi

	# Items
	local display_var="TAB_DISPLAY_${CURRENT_TAB}"
	local items_var="TAB_ITEMS_${CURRENT_TAB}"
	local -n _draw_display_ref="$display_var"
	local -n _draw_items_ref="$items_var"
	count=${#_draw_items_ref[@]}

	if ((count == 0)); then
		buf+="${CLR_EOL}"$'\n'
		case $CURRENT_TAB in
		0) buf+="${C_YELLOW}    No networks found. Radio may be off.${C_RESET}${CLR_EOL}"$'\n' ;;
		1) buf+="${C_YELLOW}    No saved connections.${C_RESET}${CLR_EOL}"$'\n' ;;
		*) buf+="${C_GREY}    No items.${C_RESET}${CLR_EOL}"$'\n' ;;
		esac
		local -i ri
		for ((ri = 1; ri < MAX_DISPLAY_ROWS; ri++)); do
			buf+="${CLR_EOL}"$'\n'
		done
		buf+="${CLR_EOL}"$'\n'
	else
		compute_scroll_window "$count"
		render_scroll_indicator buf "above" "$count" "$_vis_start"
		render_display_list buf _draw_display_ref "$_vis_start" "$_vis_end"
		render_scroll_indicator buf "below" "$count" "$_vis_end"
	fi

	local footer=""
	case $CURRENT_TAB in
	0) footer=" [Tab] Switch  [Enter] Connect  [r] Rescan  [q] Quit" ;;
	1) footer=" [Tab] Switch  [Enter] Manage  [r] Refresh  [q] Quit" ;;
	2) footer=" [Tab] Switch  [Enter] Action  [q] Quit" ;;
	3) footer=" [Tab] Switch  [Enter] Action  [r] Refresh  [q] Quit" ;;
	esac
	buf+=$'\n'"${C_CYAN}${footer}${C_RESET}${CLR_EOL}"$'\n'
	buf+="${CLR_EOS}"
	printf '%s' "$buf"
}

draw_detail_view() {
	local buf="" pad_buf=""
	local -i count pad_needed
	local -i left_pad right_pad vis_len
	local -i _vis_start _vis_end

	buf+="${CURSOR_HOME}"
	buf+="${C_MAGENTA}┌${H_LINE}┐${C_RESET}${CLR_EOL}"$'\n'

	local title=" ${DETAIL_TITLE} "
	strip_ansi "$title"
	local -i t_len=${#REPLY}
	left_pad=$(((BOX_INNER_WIDTH - t_len) / 2))
	right_pad=$((BOX_INNER_WIDTH - t_len - left_pad))
	((left_pad < 0)) && left_pad=0
	((right_pad < 0)) && right_pad=0

	printf -v pad_buf '%*s' "$left_pad" ''
	buf+="${C_MAGENTA}│${pad_buf}${C_YELLOW}${title}${C_MAGENTA}"
	printf -v pad_buf '%*s' "$right_pad" ''
	buf+="${pad_buf}│${C_RESET}${CLR_EOL}"$'\n'

	local breadcrumb=" « Back to ${TABS[CURRENT_TAB]}"
	strip_ansi "$breadcrumb"
	local -i b_len=${#REPLY}
	pad_needed=$((BOX_INNER_WIDTH - b_len))
	((pad_needed < 0)) && pad_needed=0
	printf -v pad_buf '%*s' "$pad_needed" ''
	buf+="${C_MAGENTA}│${C_CYAN}${breadcrumb}${C_RESET}${pad_buf}${C_MAGENTA}│${C_RESET}${CLR_EOL}"$'\n'
	buf+="${C_MAGENTA}└${H_LINE}┘${C_RESET}${CLR_EOL}"$'\n'

	count=${#DETAIL_DISPLAY[@]}

	if ((count == 0)); then
		buf+="${C_GREY}    No options available.${C_RESET}${CLR_EOL}"$'\n'
		local -i ri
		for ((ri = 1; ri < MAX_DISPLAY_ROWS + 2; ri++)); do
			buf+="${CLR_EOL}"$'\n'
		done
	else
		compute_scroll_window "$count"
		render_scroll_indicator buf "above" "$count" "$_vis_start"
		render_display_list buf DETAIL_DISPLAY "$_vis_start" "$_vis_end"
		render_scroll_indicator buf "below" "$count" "$_vis_end"
	fi

	buf+=$'\n'"${C_CYAN} [Esc/Shift+Tab] Back  [Enter] Select  [q] Quit${C_RESET}${CLR_EOL}"$'\n'
	buf+="${CLR_EOS}"
	printf '%s' "$buf"
}

draw_ui() {
	case $CURRENT_VIEW in
	0) draw_main_view ;;
	1) draw_detail_view ;;
	esac
}

# ==============================================================================
#  DETAIL VIEW BUILDERS
# ==============================================================================

# Adds an info (non-actionable) row to detail arrays
_detail_info() {
	DETAIL_ITEMS+=("$1")
	DETAIL_DISPLAY+=("$2")
	DETAIL_ACTIONABLE+=(0)
}

# Adds an actionable row to detail arrays
_detail_action() {
	DETAIL_ITEMS+=("$1")
	DETAIL_DISPLAY+=("$2")
	DETAIL_ACTIONABLE+=(1)
}

# Returns the index of the first actionable item in DETAIL_ACTIONABLE
_first_actionable_index() {
	local -i i
	for ((i = 0; i < ${#DETAIL_ACTIONABLE[@]}; i++)); do
		if ((DETAIL_ACTIONABLE[i] == 1)); then
			REPLY=$i
			return 0
		fi
	done
	REPLY=0
	return 0
}

open_detail() {
	local -r title="$1"
	DETAIL_TITLE="$title"
	PARENT_ROW=$SELECTED_ROW
	PARENT_SCROLL=$SCROLL_OFFSET
	CURRENT_VIEW=1
	SCROLL_OFFSET=0
	_first_actionable_index
	SELECTED_ROW=$REPLY
}

close_detail() {
	CURRENT_VIEW=0
	SELECTED_ROW=$PARENT_ROW
	SCROLL_OFFSET=$PARENT_SCROLL
	DETAIL_ITEMS=()
	DETAIL_DISPLAY=()
	DETAIL_ACTIONABLE=()
}

build_network_detail() {
	local -i idx=$1
	local ssid="${SCAN_SSIDS[idx]}"
	local state="${SCAN_STATES[idx]}"
	local uuid="${SCAN_UUIDS[idx]}"
	local sec="${SCAN_SECURITY[idx]}"
	local sig="${SCAN_SIGNALS[idx]}"

	DETAIL_ITEMS=()
	DETAIL_DISPLAY=()
	DETAIL_ACTIONABLE=()
	DETAIL_CTX="net:${idx}"

	signal_to_bar "$sig"
	local bar="$REPLY"
	signal_color "$sig"
	local scol="$REPLY"

	_detail_info "_info_ssid" "${C_WHITE}SSID:${C_RESET}  ${ssid}"
	_detail_info "_info_sec" "${C_WHITE}Security:${C_RESET}  ${sec}"
	_detail_info "_info_sig" "${C_WHITE}Signal:${C_RESET}  ${scol}${sig}% ${bar}${C_RESET}"
	_detail_info "_info_state" "${C_WHITE}Status:${C_RESET}  ${state}"
	_detail_info "---" "${C_GREY}────────────────────────────────────${C_RESET}"

	case "$state" in
	Active)
		_detail_action "Disconnect" "${C_RED}✕${C_RESET}  Disconnect from this network"
		_detail_action "Forget Network" "${C_YELLOW}✕${C_RESET}  Delete saved profile"
		_detail_action "Cancel" "${C_GREY}←${C_RESET}  Go back"
		;;
	Saved)
		_detail_action "Connect" "${C_GREEN}▶${C_RESET}  Connect using saved profile"
		_detail_action "Forget Network" "${C_YELLOW}✕${C_RESET}  Delete saved profile"
		_detail_action "Toggle Autoconnect" "${C_CYAN}⟳${C_RESET}  Toggle auto-connect on/off"
		_detail_action "Cancel" "${C_GREY}←${C_RESET}  Go back"
		;;
	*)
		_detail_action "Connect" "${C_GREEN}▶${C_RESET}  Connect (will prompt for password)"
		_detail_action "Cancel" "${C_GREY}←${C_RESET}  Go back"
		;;
	esac

	open_detail "$ssid"
}

build_saved_detail() {
	local -i idx=$1
	local name="${SAVED_NAMES[idx]}"
	local uuid="${SAVED_UUIDS_LIST[idx]}"
	local autocon="${SAVED_AUTOCONNECT[idx]}"

	DETAIL_ITEMS=()
	DETAIL_DISPLAY=()
	DETAIL_ACTIONABLE=()
	DETAIL_CTX="saved:${idx}"

	_detail_info "_info_name" "${C_WHITE}Name:${C_RESET}  ${name}"
	_detail_info "_info_uuid" "${C_WHITE}UUID:${C_RESET}  ${C_GREY}${uuid}${C_RESET}"

	local auto_disp
	if [[ "$autocon" == "yes" ]]; then
		auto_disp="${C_GREEN}yes${C_RESET}"
	else
		auto_disp="${C_RED}no${C_RESET}"
	fi
	_detail_info "_info_auto" "${C_WHITE}Autoconnect:${C_RESET}  ${auto_disp}"
	_detail_info "---" "${C_GREY}────────────────────────────────────${C_RESET}"

	_detail_action "Connect" "${C_GREEN}▶${C_RESET}  Connect to this network"

	if [[ "$name" == "$CACHED_SSID" ]]; then
		_detail_action "Disconnect" "${C_RED}✕${C_RESET}  Disconnect"
	fi

	_detail_action "Toggle Autoconnect" "${C_CYAN}⟳${C_RESET}  Toggle autoconnect (currently: ${autocon})"
	_detail_action "Forget Network" "${C_YELLOW}✕${C_RESET}  Permanently delete this profile"
	_detail_action "Cancel" "${C_GREY}←${C_RESET}  Go back"

	open_detail "$name"
}

# ==============================================================================
#  ACTION EXECUTION
# ==============================================================================

execute_detail_action() {
	local action="${DETAIL_ITEMS[SELECTED_ROW]}"

	# Guard: skip non-actionable
	if ((DETAIL_ACTIONABLE[SELECTED_ROW] == 0)); then
		return 0
	fi

	local ctx_type="${DETAIL_CTX%%:*}"
	local ctx_idx="${DETAIL_CTX#*:}"

	case "$action" in
	"Connect")
		if [[ "$ctx_type" == "net" ]]; then
			local ssid="${SCAN_SSIDS[ctx_idx]}"
			local uuid="${SCAN_UUIDS[ctx_idx]}"
			local state="${SCAN_STATES[ctx_idx]}"

			enter_interactive
			printf '\n'
			if [[ "$state" == "Saved" && -n "$uuid" ]]; then
				if run_with_feedback "Connecting to ${ssid}" nmcli connection up uuid "$uuid"; then
					printf '%s✓ Connected to %s%s\n' "$C_GREEN" "$ssid" "$C_RESET"
					notify "Wi-Fi" "Connected to ${ssid}"
				else
					printf '%s✗ Connection failed%s\n' "$C_RED" "$C_RESET"
					notify "Wi-Fi" "Failed: ${ssid}"
				fi
			else
				printf '%sPassword (empty for open network):%s ' "$C_CYAN" "$C_RESET"
				local password=""
				read -r password
				printf '\n'

				local -i ok=1
				if [[ -n "$password" ]]; then
					nmcli device wifi connect "$ssid" password "$password" &>/dev/null && ok=0 || :
				else
					nmcli device wifi connect "$ssid" &>/dev/null && ok=0 || :
				fi

				if ((ok == 0)); then
					printf '%s✓ Connected to %s%s\n' "$C_GREEN" "$ssid" "$C_RESET"
					notify "Wi-Fi" "Connected to ${ssid}"
				else
					printf '%s✗ Connection failed%s\n' "$C_RED" "$C_RESET"
					printf '%sBad password, out of range, or timeout.%s\n' "$C_GREY" "$C_RESET"
					notify "Wi-Fi" "Failed: ${ssid}"
				fi
			fi
			sleep 1
			leave_interactive

		elif [[ "$ctx_type" == "saved" ]]; then
			local uuid="${SAVED_UUIDS_LIST[ctx_idx]}"
			local name="${SAVED_NAMES[ctx_idx]}"
			enter_interactive
			printf '\n'
			if run_with_feedback "Connecting to ${name}" nmcli connection up uuid "$uuid"; then
				printf '%s✓ Connected%s\n' "$C_GREEN" "$C_RESET"
				notify "Wi-Fi" "Connected to ${name}"
			else
				printf '%s✗ Failed%s\n' "$C_RED" "$C_RESET"
			fi
			sleep 1
			leave_interactive
		fi
		close_detail
		draw_loading_frame "Refreshing..." "Updating network state"
		populate_all_tabs
		;;

	"Disconnect")
		local target_uuid="" target_name=""
		if [[ "$ctx_type" == "net" ]]; then
			target_uuid="${SCAN_UUIDS[ctx_idx]}"
			target_name="${SCAN_SSIDS[ctx_idx]}"
		elif [[ "$ctx_type" == "saved" ]]; then
			target_uuid="${SAVED_UUIDS_LIST[ctx_idx]}"
			target_name="${SAVED_NAMES[ctx_idx]}"
		fi
		enter_interactive
		printf '\n'
		if [[ -n "$target_uuid" ]]; then
			run_with_feedback "Disconnecting" nmcli connection down uuid "$target_uuid" || :
		else
			run_with_feedback "Disconnecting" nmcli connection down id "$target_name" || :
		fi
		notify "Wi-Fi" "Disconnected from ${target_name}"
		sleep 1
		leave_interactive
		close_detail
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		;;

	"Forget Network")
		local target_uuid="" target_name=""
		if [[ "$ctx_type" == "net" ]]; then
			target_uuid="${SCAN_UUIDS[ctx_idx]}"
			target_name="${SCAN_SSIDS[ctx_idx]}"
		elif [[ "$ctx_type" == "saved" ]]; then
			target_uuid="${SAVED_UUIDS_LIST[ctx_idx]}"
			target_name="${SAVED_NAMES[ctx_idx]}"
		fi
		enter_interactive
		printf '\n'
		printf '%sPermanently delete profile for %s? [y/N]%s ' "$C_YELLOW" "$target_name" "$C_RESET"
		local confirm=""
		read -n 1 -r confirm || :
		printf '\n'
		if [[ "$confirm" =~ ^[Yy]$ ]]; then
			if [[ -n "$target_uuid" ]]; then
				forget_network "$target_uuid" "uuid"
			else
				forget_network "$target_name" "id"
			fi
			printf '%s✓ Deleted%s\n' "$C_GREEN" "$C_RESET"
			notify "Wi-Fi" "Forgot ${target_name}"
			sleep 1
		fi
		leave_interactive
		close_detail
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		;;

	"Toggle Autoconnect")
		local target_uuid="" cur_auto="" new_auto=""
		if [[ "$ctx_type" == "saved" ]]; then
			target_uuid="${SAVED_UUIDS_LIST[ctx_idx]}"
			cur_auto="${SAVED_AUTOCONNECT[ctx_idx]}"
		elif [[ "$ctx_type" == "net" ]]; then
			target_uuid="${SCAN_UUIDS[ctx_idx]}"
			if [[ -n "$target_uuid" ]]; then
				cur_auto=$(nmcli --terse --fields connection.autoconnect connection show uuid "$target_uuid" 2>/dev/null | awk -F: '{print $2}') || cur_auto="yes"
			fi
		fi

		if [[ -n "$target_uuid" ]]; then
			if [[ "$cur_auto" == "yes" ]]; then new_auto="no"; else new_auto="yes"; fi
			enter_interactive
			printf '\n'
			if run_with_feedback "Setting autoconnect=${new_auto}" \
				nmcli connection modify uuid "$target_uuid" connection.autoconnect "$new_auto"; then
				printf '%s✓ Autoconnect set to %s%s\n' "$C_GREEN" "$new_auto" "$C_RESET"
			else
				printf '%s✗ Failed%s\n' "$C_RED" "$C_RESET"
			fi
			sleep 1
			leave_interactive
		fi
		close_detail
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		;;

	"Cancel")
		close_detail
		;;
	esac
}

execute_hotspot_action() {
	local -n _items_ref="TAB_ITEMS_2"
	((${#_items_ref[@]} == 0)) && return 0
	local action="${_items_ref[SELECTED_ROW]}"

	case "$action" in
	"Start Hotspot (2.4 GHz)" | "Start Hotspot (5 GHz)")
		local band="bg"
		[[ "$action" == *"5 GHz"* ]] && band="a"

		enter_interactive
		printf '\n'
		printf '%sHotspot SSID (default: MyHotspot):%s ' "$C_CYAN" "$C_RESET"
		local hs_ssid=""
		read -r hs_ssid || :
		[[ -z "$hs_ssid" ]] && hs_ssid="MyHotspot"

		printf '%sPassword (min 8 chars, empty=open):%s ' "$C_CYAN" "$C_RESET"
		local hs_pass=""
		read -r hs_pass || :

		if [[ -n "$hs_pass" && ${#hs_pass} -lt 8 ]]; then
			printf '%s✗ Password must be at least 8 characters%s\n' "$C_RED" "$C_RESET"
			sleep 2
			leave_interactive
			return 0
		fi

		printf '\n'
		local wifi_dev=""
		wifi_dev=$(find_wifi_device) || wifi_dev=""
		if [[ -z "$wifi_dev" ]]; then
			printf '%s✗ No WiFi device found%s\n' "$C_RED" "$C_RESET"
			sleep 2
			leave_interactive
			return 0
		fi

		local -a cmd=(nmcli device wifi hotspot ifname "$wifi_dev" ssid "$hs_ssid" band "$band")
		[[ -n "$hs_pass" ]] && cmd+=(password "$hs_pass")

		if run_with_feedback "Starting hotspot '${hs_ssid}'" "${cmd[@]}"; then
			printf '%s✓ Hotspot active!%s\n' "$C_GREEN" "$C_RESET"
			notify "Hotspot" "Started: ${hs_ssid}"
		else
			printf '%s✗ Failed. Adapter may not support AP mode or band.%s\n' "$C_RED" "$C_RESET"
			notify "Hotspot" "Failed to start"
		fi
		sleep 2
		leave_interactive
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;

	"Stop Hotspot")
		enter_interactive
		printf '\n'
		local wifi_dev=""
		wifi_dev=$(find_wifi_device) || wifi_dev=""
		if [[ -n "$wifi_dev" ]]; then
			run_with_feedback "Stopping hotspot" nmcli device disconnect "$wifi_dev" || :
			printf '%s✓ Hotspot stopped%s\n' "$C_GREEN" "$C_RESET"
			notify "Hotspot" "Stopped"
		else
			printf '%s✗ No WiFi device%s\n' "$C_RED" "$C_RESET"
		fi
		sleep 1
		leave_interactive
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;

	"Show Hotspot Info")
		enter_interactive
		printf '\n'
		printf '%s── Hotspot Information ──%s\n' "$C_MAGENTA" "$C_RESET"
		printf '%s   SSID:%s %s\n' "$C_CYAN" "$C_RESET" "$HOTSPOT_SSID"

		local wifi_dev=""
		wifi_dev=$(find_wifi_device) || wifi_dev=""
		if [[ -n "$wifi_dev" ]]; then
			local ip_addr=""
			ip_addr=$(nmcli --terse --fields IP4.ADDRESS device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || ip_addr=""
			printf '%s   Device:%s %s\n' "$C_CYAN" "$C_RESET" "$wifi_dev"
			printf '%s   IP:%s %s\n' "$C_CYAN" "$C_RESET" "${ip_addr:-N/A}"
		fi

		if command -v iw &>/dev/null && [[ -n "$wifi_dev" ]]; then
			local clients="0"
			clients=$(iw dev "$wifi_dev" station dump 2>/dev/null | grep -c "^Station") || clients="0"
			printf '%s   Clients:%s %s\n' "$C_CYAN" "$C_RESET" "$clients"
		fi

		printf '\n%sPress any key...%s' "$C_GREY" "$C_RESET"
		read -rsn1 || :
		leave_interactive
		;;
	esac
}

execute_status_action() {
	local -n _items_ref="TAB_ITEMS_3"
	((${#_items_ref[@]} == 0)) && return 0
	local action="${_items_ref[SELECTED_ROW]}"

	case "$action" in
	"Toggle Radio")
		enter_interactive
		printf '\n'
		if [[ "$CACHED_RADIO" == "enabled" ]]; then
			printf '%sTurn Wi-Fi OFF? [y/N]%s ' "$C_YELLOW" "$C_RESET"
			local reply=""
			read -n 1 -r reply || :
			printf '\n'
			if [[ "$reply" =~ ^[Yy]$ ]]; then
				run_with_feedback "Disabling radio" nmcli radio wifi off || :
				notify "Wi-Fi" "Radio disabled"
				sleep 1
			fi
		elif [[ "$CACHED_RADIO" == "disabled" ]]; then
			if run_with_feedback "Enabling radio" nmcli radio wifi on; then
				notify "Wi-Fi" "Radio enabled"
				sleep 2
			fi
		else
			printf '%s⚠ Cannot determine radio state%s\n' "$C_RED" "$C_RESET"
			sleep 1
		fi
		leave_interactive
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		;;

	"Connection Info")
		if [[ -n "$CACHED_SSID" ]]; then
			enter_interactive
			printf '\n'
			printf '%s── Connection Details ──%s\n' "$C_MAGENTA" "$C_RESET"
			printf '%s   SSID:%s %s\n' "$C_CYAN" "$C_RESET" "$CACHED_SSID"

			local wifi_dev=""
			wifi_dev=$(find_wifi_device) || wifi_dev=""
			if [[ -n "$wifi_dev" ]]; then
				local ip_addr="" gateway="" dns=""
				ip_addr=$(nmcli --terse --fields IP4.ADDRESS device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || ip_addr=""
				gateway=$(nmcli --terse --fields IP4.GATEWAY device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || gateway=""
				dns=$(nmcli --terse --fields IP4.DNS device show "$wifi_dev" 2>/dev/null | head -1 | awk -F: '{print $2}') || dns=""
				printf '%s   IP:%s %s\n' "$C_CYAN" "$C_RESET" "${ip_addr:-N/A}"
				printf '%s   Gateway:%s %s\n' "$C_CYAN" "$C_RESET" "${gateway:-N/A}"
				printf '%s   DNS:%s %s\n' "$C_CYAN" "$C_RESET" "${dns:-N/A}"

				local cur_signal=""
				cur_signal=$(nmcli --terse --fields active,signal device wifi list 2>/dev/null | awk -F: '$1=="yes"{print $2;exit}') || cur_signal=""
				if [[ -n "$cur_signal" ]]; then
					signal_to_bar "$cur_signal"
					local bar="$REPLY"
					signal_color "$cur_signal"
					local scol="$REPLY"
					printf '%s   Signal:%s %s%s%% %s%s\n' "$C_CYAN" "$C_RESET" "$scol" "$cur_signal" "$bar" "$C_RESET"
				fi
			fi

			printf '\n%sPress any key...%s' "$C_GREY" "$C_RESET"
			read -rsn1 || :
			leave_interactive
		fi
		;;

	"Disconnect")
		enter_interactive
		printf '\n'
		local active_uuid=""
		active_uuid=$(nmcli --terse --fields NAME,UUID,TYPE connection show --active 2>/dev/null |
			awk -F: '$3=="802-11-wireless"{print $2;exit}') || active_uuid=""
		if [[ -n "$active_uuid" ]]; then
			run_with_feedback "Disconnecting" nmcli connection down uuid "$active_uuid" || :
			notify "Wi-Fi" "Disconnected"
		else
			printf '%sNo active WiFi connection%s\n' "$C_GREY" "$C_RESET"
		fi
		sleep 1
		leave_interactive
		draw_loading_frame "Refreshing..." ""
		populate_all_tabs
		;;

	"Refresh")
		draw_loading_frame "Refreshing all..." "Querying NetworkManager"
		populate_all_tabs
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;

	"Device Info" | "DNS Info" | "Hotspot Status")
		# Info-only items — no action
		;;
	esac
}

# ==============================================================================
#  NAVIGATION
# ==============================================================================

get_current_count() {
	if ((CURRENT_VIEW == 1)); then
		REPLY=${#DETAIL_ITEMS[@]}
	else
		local -n _gcc_ref="TAB_ITEMS_${CURRENT_TAB}"
		REPLY=${#_gcc_ref[@]}
	fi
}

# Navigate with skip logic for detail view info items.
# CRITICAL: All arithmetic guarded against set -e.
navigate() {
	local -i dir=$1
	get_current_count
	local -i count=$REPLY
	((count == 0)) && return 0

	# Compute next position
	SELECTED_ROW=$(((SELECTED_ROW + dir + count) % count))

	# In detail view, skip non-actionable items
	if ((CURRENT_VIEW == 1 && ${#DETAIL_ACTIONABLE[@]} > 0)); then
		local -i attempts=0
		while ((attempts < count)); do
			if ((DETAIL_ACTIONABLE[SELECTED_ROW] == 1)); then
				break
			fi
			SELECTED_ROW=$(((SELECTED_ROW + dir + count) % count))
			# CRITICAL: += 1 not ++ to avoid set -e exit on (( 0++ )) returning 1
			attempts=$((attempts + 1))
		done
	fi
	return 0
}

navigate_page() {
	local -i dir=$1
	get_current_count
	local -i count=$REPLY
	((count == 0)) && return 0
	SELECTED_ROW=$((SELECTED_ROW + dir * MAX_DISPLAY_ROWS))
	if ((SELECTED_ROW < 0)); then SELECTED_ROW=0; fi
	if ((SELECTED_ROW >= count)); then SELECTED_ROW=$((count - 1)); fi

	# Clamp to actionable in detail view
	if ((CURRENT_VIEW == 1 && ${#DETAIL_ACTIONABLE[@]} > 0)); then
		if ((DETAIL_ACTIONABLE[SELECTED_ROW] == 0)); then
			local -i orig=$SELECTED_ROW
			# Search forward for nearest actionable
			local -i i
			for ((i = orig; i < count; i++)); do
				if ((DETAIL_ACTIONABLE[i] == 1)); then
					SELECTED_ROW=$i
					return 0
				fi
			done
			# Search backward
			for ((i = orig; i >= 0; i--)); do
				if ((DETAIL_ACTIONABLE[i] == 1)); then
					SELECTED_ROW=$i
					return 0
				fi
			done
		fi
	fi
	return 0
}

navigate_end() {
	local -i target=$1
	get_current_count
	local -i count=$REPLY
	((count == 0)) && return 0

	if ((target == 0)); then
		SELECTED_ROW=0
	else
		SELECTED_ROW=$((count - 1))
	fi

	# Clamp to actionable in detail view
	if ((CURRENT_VIEW == 1 && ${#DETAIL_ACTIONABLE[@]} > 0)); then
		if ((DETAIL_ACTIONABLE[SELECTED_ROW] == 0)); then
			if ((target == 0)); then
				_first_actionable_index
				SELECTED_ROW=$REPLY
			else
				local -i i
				for ((i = count - 1; i >= 0; i--)); do
					if ((DETAIL_ACTIONABLE[i] == 1)); then
						SELECTED_ROW=$i
						return 0
					fi
				done
			fi
		fi
	fi
	return 0
}

switch_tab() {
	local -i dir=${1:-1}
	CURRENT_TAB=$(((CURRENT_TAB + dir + TAB_COUNT) % TAB_COUNT))
	SELECTED_ROW=0
	SCROLL_OFFSET=0
}

set_tab() {
	local -i idx=$1
	if ((idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT)); then
		CURRENT_TAB=$idx
		SELECTED_ROW=0
		SCROLL_OFFSET=0
	fi
}

handle_enter_main() {
	local -n _items_ref="TAB_ITEMS_${CURRENT_TAB}"
	local -i count=${#_items_ref[@]}
	if ((count == 0 || SELECTED_ROW < 0 || SELECTED_ROW >= count)); then return 0; fi

	case $CURRENT_TAB in
	0) build_network_detail "$SELECTED_ROW" ;;
	1) build_saved_detail "$SELECTED_ROW" ;;
	2) execute_hotspot_action ;;
	3) execute_status_action ;;
	esac
	return 0
}

handle_enter_detail() {
	local -i count=${#DETAIL_ITEMS[@]}
	if ((count == 0 || SELECTED_ROW < 0 || SELECTED_ROW >= count)); then return 0; fi
	execute_detail_action
	return 0
}

handle_rescan() {
	case $CURRENT_TAB in
	0)
		[[ "$CACHED_RADIO" == "disabled" ]] && return 0
		draw_loading_frame "Scanning networks..." "This may take a few seconds"
		populate_tab_networks
		refresh_cached_status
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;
	1)
		draw_loading_frame "Refreshing saved..." ""
		populate_tab_saved
		refresh_cached_status
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;
	3)
		draw_loading_frame "Refreshing status..." ""
		populate_all_tabs
		SELECTED_ROW=0
		SCROLL_OFFSET=0
		;;
	esac
	return 0
}

# ==============================================================================
#  MOUSE HANDLING (Template Pattern)
# ==============================================================================

handle_mouse() {
	local input="$1"
	local -i button x y i start end
	local zone

	local body="${input#'[<'}"
	[[ "$body" == "$input" ]] && return 0
	local terminator="${body: -1}"
	[[ "$terminator" != "M" && "$terminator" != "m" ]] && return 0
	body="${body%[Mm]}"
	local field1="" field2="" field3=""
	IFS=';' read -r field1 field2 field3 <<<"$body"
	[[ ! "$field1" =~ ^[0-9]+$ ]] && return 0
	[[ ! "$field2" =~ ^[0-9]+$ ]] && return 0
	[[ ! "$field3" =~ ^[0-9]+$ ]] && return 0
	button=$field1
	x=$field2
	y=$field3

	# Scroll wheel
	if ((button == 64)); then
		navigate -1
		return 0
	fi
	if ((button == 65)); then
		navigate 1
		return 0
	fi
	[[ "$terminator" != "M" ]] && return 0

	# Tab row click
	if ((y == TAB_ROW)); then
		if ((CURRENT_VIEW == 0)); then
			for ((i = 0; i < TAB_COUNT; i++)); do
				zone="${TAB_ZONES[i]:-}"
				[[ -z "$zone" ]] && continue
				start="${zone%%:*}"
				end="${zone##*:}"
				if ((x >= start && x <= end)); then
					set_tab "$i"
					return 0
				fi
			done
		else
			close_detail
			return 0
		fi
	fi

	# Breadcrumb row click (row 2 in header = go back in detail)
	if ((CURRENT_VIEW == 1 && y == 3)); then
		close_detail
		return 0
	fi

	# Item area
	# Main: header(4) + status(1) + scroll_above(1) = row 7 is first item
	# Detail: header(4) + scroll_above(1) = row 6 is first item
	local -i effective_start
	if ((CURRENT_VIEW == 0)); then
		effective_start=$((ITEM_START_ROW + 2)) # +status +scroll_above
	else
		effective_start=$((ITEM_START_ROW + 1)) # +scroll_above
	fi

	if ((y >= effective_start && y < effective_start + MAX_DISPLAY_ROWS)); then
		local -i clicked_idx=$((y - effective_start + SCROLL_OFFSET))
		get_current_count
		local -i count=$REPLY

		if ((clicked_idx >= 0 && clicked_idx < count)); then
			# Skip non-actionable in detail view
			if ((CURRENT_VIEW == 1 && ${#DETAIL_ACTIONABLE[@]} > 0)); then
				if ((DETAIL_ACTIONABLE[clicked_idx] == 0)); then
					return 0
				fi
			fi

			if ((clicked_idx == SELECTED_ROW)); then
				# Same item clicked again → activate
				if ((CURRENT_VIEW == 0)); then
					handle_enter_main
				else
					handle_enter_detail
				fi
			else
				SELECTED_ROW=$clicked_idx
			fi
		fi
	fi
	return 0
}

# ==============================================================================
#  INPUT HANDLING (Template Pattern)
# ==============================================================================

read_escape_seq() {
	local -n _esc_out=$1
	_esc_out=""
	local char=""
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

handle_key_main() {
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
	g) navigate_end 0 ;;
	G) navigate_end 1 ;;
	$'\t') switch_tab 1 ;;
	r | R) handle_rescan ;;
	'' | $'\n') handle_enter_main ;;
	q | Q | $'\x03') exit 0 ;;
	esac
}

handle_key_detail() {
	local key="$1"
	case "$key" in
	'[A' | 'OA')
		navigate -1
		return
		;;
	'[B' | 'OB')
		navigate 1
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
	'[Z')
		close_detail
		return
		;;
	'['*'<'*[Mm])
		handle_mouse "$key"
		return
		;;
	esac

	case "$key" in
	ESC) close_detail ;;
	k | K) navigate -1 ;;
	j | J) navigate 1 ;;
	g) navigate_end 0 ;;
	G) navigate_end 1 ;;
	'' | $'\n') handle_enter_detail ;;
	$'\x7f' | $'\x08') close_detail ;;
	q | Q | $'\x03') exit 0 ;;
	esac
}

handle_input_router() {
	local key="$1"
	local escape_seq=""

	if [[ "$key" == $'\x1b' ]]; then
		if read_escape_seq escape_seq; then
			key="$escape_seq"
		else
			key="ESC"
		fi
	fi

	case $CURRENT_VIEW in
	0) handle_key_main "$key" ;;
	1) handle_key_detail "$key" ;;
	esac
}

# ==============================================================================
#  ENTRY POINT
# ==============================================================================

main() {
	if ((BASH_VERSINFO[0] < 5)); then
		log_err "Bash 5.0+ required"
		exit 1
	fi
	if [[ ! -t 0 ]]; then
		log_err "TTY required"
		exit 1
	fi

	local _dep
	for _dep in nmcli awk; do
		if ! command -v "$_dep" &>/dev/null; then
			log_err "Missing dependency: ${_dep}"
			exit 1
		fi
	done

	if command -v systemctl &>/dev/null; then
		if ! systemctl is-active --quiet NetworkManager.service; then
			log_err "NetworkManager not running. Start with: sudo systemctl start NetworkManager"
			exit 1
		fi
	else
		if ! pgrep -x NetworkManager >/dev/null; then
			log_err "NetworkManager not running. Start with: sudo rc-service NetworkManager start"
			exit 1
		fi
	fi

	ORIGINAL_STTY=$(stty -g 2>/dev/null) || ORIGINAL_STTY=""
	stty -icanon -echo min 1 time 0 2>/dev/null

	printf '%s%s%s%s' "$MOUSE_ON" "$CURSOR_HIDE" "$CLR_SCREEN" "$CURSOR_HOME"

	draw_loading_frame "Connecting to NetworkManager..." "Querying radio, connections, and networks"
	populate_all_tabs

	local key=""
	while true; do
		draw_ui
		IFS= read -rsn1 key || break
		handle_input_router "$key"
	done
}

main "$@"
