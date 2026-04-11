#!/usr/bin/env bash
# ==============================================================================
#  ARCH LINUX MASTER CONDUCTOR
# ==============================================================================
#  INSTRUCTIONS:
#  1. Configure SCRIPT_SEARCH_DIRS below with directories containing your scripts.
#  2. Edit the 'INSTALL_SEQUENCE' list below.
#  3. Use "S | name.sh" for Root (Sudo) commands.
#  4. Use "U | name.sh" for User commands.
#  5. Entries WITHOUT a / in the name are searched across SCRIPT_SEARCH_DIRS
#     in order (first match wins).
#  6. Entries WITH a / are treated as direct absolute paths (no searching).
#     Use ${HOME} instead of ~ for home directory paths.
# ==============================================================================

# --- USER CONFIGURATION AREA ---

# TODO: Remove lock cleanup once verified no stale locks remain
rm -rf /tmp/conductor_1000.lock

# Directories to search for scripts (in order — first match wins)
SCRIPT_SEARCH_DIRS=(
	"${HOME}/user_scripts/arch_setup_scripts/scripts"
	"${HOME}/user_scripts/arch_setup_scripts"
	"${HOME}/user_scripts/rofi"
	"${HOME}/user_scripts/theme_matugen"
	# "${HOME}/my_other_scripts"
	# "/opt/shared_team_scripts"
)

# Delay (in seconds) after each successful script. Set to 0 to disable.
POST_SCRIPT_DELAY=0

INSTALL_SEQUENCE=(

	# ------ Setup SCRIPTS -------

	"U | 005_hypr_custom_config_setup.sh"
	"U | 010_package_removal.sh --auto"
	"U | 015_set_thunar_terminal_kitty.sh"
	"U | 020_desktop_apps_username_setter.sh"
	"U | 025_configure_keyboard.sh"
	"U | 040_long_sleep_timeout.sh --auto"
	#    "S | 045_battery_limiter.sh"
	"S | 050_pacman_config.sh --auto"
	"S | 055_pacman_reflector.sh"
	"S | 060_package_installation.sh"
	"U | 065_enabling_user_services.sh"
	"S | 070_openssh_setup.sh --auto"
	"U | 075_changing_shell_zsh.sh"
	"S | 080_aur_paru_fallback_yay.sh --paru"
	#    "S | 085_warp.sh"
	#    "U | 090_paru_packages_optional.sh"
	#    "S | 095_battery_limiter_again_dusk.sh"
	"U | 100_paru_packages.sh"
	"S | 110_aur_packages_sudo_services.sh"
	"U | 115_aur_packages_user_services.sh"
	#    "S | 120_create_mount_directories.sh"
	"S | 125_pam_keyring.sh"
	"S | 130_copy_service_files.sh --default"
	"U | 131_dbus_copy_service_files.sh"
	"U | 135_battery_notify_service.sh --auto"
	"U | 140_fc_cache_fv.sh"

	"U | dawn_matugen_config_tui.sh --smart"

	"U | 145_matugen_directories.sh"
	"U | 150_wallpapers_download.sh"
	"U | 155_blur_shadow_opacity.sh"
	"U | 160_theme_ctl.sh"
	"U | 165_qtct_config.sh"
	"U | 170_waypaper_config_reset.sh"
	"U | 175_animation_default.sh"
	"S | 180_udev_usb_notify.sh"
	"U | 185_terminal_default.sh"
	#    "S | 190_dusk_fstab.sh"
	#    "S | 195_zen_symlink_partition.sh"
	#    "S | 200_tlp_config.sh"
	"S | 205_zram_configuration.sh"
	#    "S | 210_zram_optimize_swappiness.sh"
	#    "S | 215_powerkey_lid_close_behaviour.sh"
	"S | 220_logrotate_optimization.sh"
	#    "S | 225_faillock_timeout.sh"
	"U | 230_non_asus_laptop.sh --auto"
	"U | 235_file_manager_switch.sh --nemo"
	"U | 236_browser_switcher.sh --zen-browser"

	#    "U | dawn_zen_tui.sh --sync --all"

	"U | 237_text_editor_switcher.sh --gnome-text-editor"
	"U | 238_terminal_switcher.sh --kitty"
	"U | 240_swaync_dgpu_fix.sh --disable"
	#    "S | 245_asusd_service_fix.sh"
	#    "S | 250_ftp_arch.sh"
	#    "U | 255_tldr_update.sh"
	#    "U | 260_spotify.sh"
	#    "U | 265_mouse_button_reverse.sh --right"
	"U | 280_dusk_clipboard_errands_delete.sh --delete"
	#    "S | 285_tty_autologin.sh"
	"S | 290_system_services.sh"
	#    "S | 295_initramfs_optimization.sh"
	#    "U | 300_git_config.sh"
	#    "U | 305_new_github_repo_to_backup.sh"
	#    "U | 310_reconnect_and_push_new_changes_to_github.sh"
	#    "S | 315_grub_optimization.sh"
	#    "S | 320_systemdboot_optimization.sh"
	#    "S | 325_hosts_files_block.sh"
	"S | 330_gtk_root_symlink.sh"
	#    "S | 335_preload_config.sh"
	#    "U | 340_kokoro_cpu.sh"
	#    "U | 345_faster_whisper_cpu.sh"
	"S | 350_dns_systemd_resolve.sh"
	#    "U | 355_hyprexpo_plugin.sh"
	#    "U | 356_dawn_plugin_manager.sh"
	"U | 360_obsidian_pensive_vault_configure.sh"
	"U | 365_cache_purge.sh"
	"S | 370_arch_install_scripts_cleanup.sh"
	"U | 375_cursor_theme_bibata_classic_modern.sh"
	"U | 376_generate_colorfiles_for_current_wallpaper.sh"
	"U | 380_nvidia_open_source.sh --auto"
	"S | 381_nvidia_services.sh"
	#    "S | 385_waydroid_setup.sh"
	"U | 390_clipboard_persistence.sh --ram"
	"S | 395_intel_media_sdk_check.sh"
	"U | 400_zen_matugen_pywalfox.sh"
	#    "U | 405_spicetify_matugen_setup.sh"
	"U | 410_waybar_swap_config.sh"
	"U | 415_mpv_setup.sh"
	#    "U | 420_kokoro_gpu_setup.sh" #requires nvidia gpu with at least 4gb vram
	#    "U | 425_parakeet_gpu_setup.sh" #requires nvidia gpu with at least 4gb vram
	#    "S | 430_btrfs_zstd_compression_stats.sh"
	#    "U | 435_key_sound_wayclick_setup.sh --setup"
	"U | 440_config_bat_notify.sh --default"
	"U | 455_hyprctl_reload.sh"
	"U | 460_switch_clipboard.sh --terminal"
	"S | 465_sddm_setup.sh --auto"
	"U | 470_equibop_matugen.sh --auto"
	"U | 475_reverting_sleep_timeout.sh"
	"U | 480_dawn_commands.sh"
	"S | 485_sudoers_nopassword.sh"

	# ------ CUSTOM PATH SCRIPTS -------

	"U | rofi_wallpaper_selector.sh --cache-only --progress"
)

# --- DEPENDENCY VERIFICATION ---
# Packages expected on the system after the install scripts complete.
# Keep in sync with 060_package_installation.sh and 100_paru_packages.sh.
# Remove or comment out packages you intentionally skip.
# Set to () to skip dependency verification entirely.
declare -ar DEPENDENCY_PACKAGES=(
	# Graphics & Drivers
	intel-media-driver vpl-gpu-rt mesa vulkan-intel mesa-utils intel-gpu-tools
	libva libva-utils vulkan-icd-loader vulkan-tools sof-firmware linux-firmware
	acpi_call-dkms archlinux-keyring
	# Hyprland Core
	hyprland xorg-xwayland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk
	xorg-xhost polkit hyprpolkitagent xdg-utils socat inotify-tools libnotify file
	# GUI, Toolkits & Fonts
	qt5-wayland qt6-wayland gtk3 gtk4 nwg-look qt5ct qt6ct qt6-svg
	qt6-multimedia-ffmpeg adw-gtk-theme matugen ttf-font-awesome
	ttf-jetbrains-mono-nerd noto-fonts-emoji sassc
	# Desktop Experience
	waybar swww hyprlock hypridle hyprsunset hyprpicker swaync swayosd rofi
	libdbusmenu-qt5 libdbusmenu-glib brightnessctl connman connman-gtk connman-openrc
	# Audio & Bluetooth
	pipewire wireplumber pipewire-pulse playerctl bluez bluez-utils blueman bluetui
	pavucontrol gst-plugin-pipewire libcanberra songrec sox pipewire-openrc
	wireplumber-openrc pipewire-pulse-openrc bluez-openrc
	# Filesystem & Archives
	btrfs-progs compsize zram-generator udisks2 udiskie dosfstools ntfs-3g
	xdg-user-dirs usbutils gnome-disk-utility unzip zip unrar 7zip cpio file-roller
	rsync nemo nemo-fileroller gvfs gvfs-smb gvfs-mtp gvfs-gphoto2 gvfs-google
	gvfs-nfs gvfs-afc gvfs-dnssd ffmpegthumbnailer webp-pixbuf-loader poppler-glib
	libgsf gnome-epub-thumbnailer resvg nemo-terminal nemo-python nemo-compare meld
	nemo-media-columns nemo-audio-tab nemo-image-converter nemo-emblems nemo-repairer
	nemo-share python-gobject dconf-editor xreader gst-libav gst-plugins-good
	nemo-pastebin
	# Network & Internet
	iwd nm-connection-editor inetutils wget curl openssh firewalld vsftpd reflector
	bmon ethtool httrack wavemon network-manager-applet
	# Terminal & Shell
	kitty foot zsh zsh-syntax-highlighting starship fastfetch bat eza fd yazi gum
	tree fzf less ripgrep expac zsh-autosuggestions iperf3 pkgstats libqalculate
	moreutils
	# Development
	neovim git git-delta lazygit meson cmake clang uv rq jq bc viu chafa ueberzugpp
	ccache mold shellcheck shfmt stylua prettier tree-sitter-cli nano
	# Multimedia
	ffmpeg mpv mpv-mpris satty swayimg imagemagick libheif grim slurp wl-clipboard
	wl-clip-persist cliphist tesseract-data-eng
	# Sys Admin
	btop htop dgop nvtop inxi sysstat sysbench logrotate acpid tlp tlp-pd tlp-rdw
	thermald powertop gdu iotop iftop lshw wev pacman-contrib gnome-keyring
	libsecret seahorse yad dysk fwupd perl
	# Gnome Utilities
	snapshot cameractrls loupe gnome-text-editor gnome-calculator gnome-clocks
	# Productivity
	zathura zathura-pdf-mupdf cava
	# AUR Packages (from 100_paru_packages.sh)
	wlogout adwaita-qt6 adwaita-qt5 adwsteamgtk otf-atkinson-hyperlegible-next
	python-pywalfox python-pyquery hyprshade hyprshutdown waypaper peaclock tray-tui
	rofi-connman xdg-terminal-exec papirus-icon-theme-git papirus-folders-git
	# AUR Browser (from 400_zen_matugen_pywalfox.sh)
	zen-browser-bin
	# AUR Helpers (from 080_aur_paru_fallback_yay.sh)
	paru yay
	# AUR Discord Client (from 470_equibop_matugen.sh)
	equibop-bin
)

# ==============================================================================
#  INTERNAL ENGINE (Do not edit below unless you know Bash)
# ==============================================================================

# 1. Safety First
set -o errexit
set -o nounset
set -o pipefail

# 2. Paths & Constants
readonly STATE_FILE="${HOME}/Documents/.install_state"
readonly LOG_FILE="${HOME}/Documents/logs/install_$(date +%Y%m%d_%H%M%S).log"
readonly LOCK_FILE="/tmp/conductor_${UID}.lock"
readonly SUDO_REFRESH_INTERVAL=50

# 3. Global Variables
declare -g SUDO_PID=""
declare -g LOGGING_INITIALIZED=0
declare -g EXECUTION_PHASE=0

# Bash 5.3 O(1) Performance Arrays
declare -gA COMPLETED_SCRIPTS=()
declare -gA SCRIPT_CACHE=()

# 4. Colors (Zero-Subshell ANSI Hardcodes)
declare -g RED="" GREEN="" BLUE="" YELLOW="" BOLD="" RESET=""

if [[ -t 1 ]]; then
	RED=$'\e[1;31m'
	GREEN=$'\e[1;32m'
	YELLOW=$'\e[1;33m'
	BLUE=$'\e[1;34m'
	BOLD=$'\e[1m'
	RESET=$'\e[0m'
fi

# 5. Logging
setup_logging() {
	local log_dir
	log_dir="$(dirname "$LOG_FILE")"
	if [[ ! -d "$log_dir" ]]; then
		mkdir -p "$log_dir" || {
			echo "CRITICAL ERROR: Could not create log directory $log_dir"
			exit 1
		}
	fi

	touch "$LOG_FILE"
	# PATCH: Close FD 9 for the tee process to avoid lock file inheritance
	exec > >(
		exec 9>&-
		tee >(sed 's/\x1B\[[0-9;]*[a-zA-Z]//g; s/\x1B(B//g' >>"$LOG_FILE")
	) 2>&1

	LOGGING_INITIALIZED=1
	echo "--- Installation Started: $(date '+%Y-%m-%d %H:%M:%S') ---"
	echo "--- Log File: $LOG_FILE ---"
}

# Discord Webhook Configuration
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/1492363011136946257/tO4hhxCGf_ZXcZqVO-h4mHs35kGt8gtGrHDcmIH5ohXlxsG2ENWJ9XiqVMG8drEYTObq"
DISCORD_NOTIFY_ON_ERROR=true

send_discord_notification() {
	local -r title="$1"
	local -r description="$2"
	local -r color="$3"  # hex color without #
	local -r fields="$4" # optional additional fields

	local payload
	payload=$(
		cat <<EOF
{
  "embeds": [{
    "title": "$title",
    "description": "$description",
    "color": "$color",
    "timestamp": "$(date -Iseconds)",
    "footer": {
      "text": "Dawn Conductor"
    }
    ${fields:+, "fields": [$fields]}
  }]
}
EOF
	)

	curl -s -X POST \
		-H "Content-Type: application/json" \
		-d "$payload" \
		"$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

notify_error_to_discord() {
	local -r script_name="$1"
	local -r error_message="$2"
	local -r log_file="${3:-}"

	local fields='{"name": "Script", "value": "'"$script_name"'"}, {"name": "Error", "value": "'"$error_message"'"}'

	if [[ -n "$log_file" && -f "$log_file" ]]; then
		fields+=', {"name": "Log", "value": "'"$log_file"'"}'
	fi

	send_discord_notification \
		"Script Failed" \
		"**$script_name** encountered an error" \
		"FF5555" \
		"$fields"
}

# 5b. Dependency Verification
verify_dependencies() {
	if [[ ${#DEPENDENCY_PACKAGES[@]} -eq 0 ]]; then
		log "INFO" "Dependency verification skipped (empty check list)."
		return 0
	fi

	log "INFO" "Verifying ${#DEPENDENCY_PACKAGES[@]} installed dependencies..."

	# Build installed-package set from pacman in one pass (1 subprocess)
	local installed_raw
	installed_raw=$(pacman -Qq 2>/dev/null) || {
		log "WARN" "pacman query failed — skipping dependency verification."
		return 0
	}

	local -A installed_map=()
	local pkg
	while IFS= read -r pkg; do
		installed_map["$pkg"]=1
	done <<<"$installed_raw"

	# Check each expected dependency
	local -a missing=()
	for pkg in "${DEPENDENCY_PACKAGES[@]}"; do
		[[ -z "${installed_map[$pkg]:-}" ]] && missing+=("$pkg")
	done

	if ((${#missing[@]} == 0)); then
		log "SUCCESS" "All ${#DEPENDENCY_PACKAGES[@]} dependencies verified."
		return 0
	fi

	log "WARN" "${#missing[@]} of ${#DEPENDENCY_PACKAGES[@]} dependencies are missing:"
	for pkg in "${missing[@]}"; do
		log "WARN" "  ✗ $pkg"
	done

	# Upload log to Discord if notifications are enabled
	if [[ "$DISCORD_NOTIFY_ON_ERROR" == "true" ]]; then
		send_missing_deps_notification "${missing[@]}"
	fi

	return 0
}

send_missing_deps_notification() {
	local -a missing_pkgs=("$@")

	# Build a compact missing-packages list for Discord embed (4096-char limit)
	local missing_list=""
	local pkg
	for pkg in "${missing_pkgs[@]}"; do
		missing_list+="• ${pkg}\n"
	done

	# Truncate if the list exceeds the embed description limit
	if ((${#missing_list} > 3800)); then
		missing_list=""
		for pkg in "${missing_pkgs[@]:0:50}"; do
			missing_list+="• ${pkg}\n"
		done
		missing_list+="… and $((${#missing_pkgs[@]} - 50)) more"
	fi

	local payload_file
	payload_file=$(mktemp) || return 0

	cat >"$payload_file" <<PAYLOAD_EOF
{
  "embeds": [{
    "title": "Missing Dependencies Detected",
    "description": "**${#missing_pkgs[@]} packages missing:**\n${missing_list}",
    "color": "FF5555",
    "timestamp": "$(date -Iseconds)",
    "footer": {
      "text": "Dawn Conductor"
    }
  }]
}
PAYLOAD_EOF

	# Upload the install log alongside the notification
	if [[ -f "$LOG_FILE" && -r "$LOG_FILE" ]]; then
		curl -s -F "payload_json=<${payload_file}" \
			-F "file=@${LOG_FILE};filename=install_log.txt;type=text/plain" \
			"$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
	else
		curl -s -X POST -H "Content-Type: application/json" \
			-d @"${payload_file}" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
	fi

	rm -f "$payload_file"
}

log() {
	local level="$1"
	local msg="$2"
	local color=""

	case "$level" in
	INFO) color="$BLUE" ;;
	SUCCESS) color="$GREEN" ;;
	WARN) color="$YELLOW" ;;
	ERROR) color="$RED" ;;
	RUN) color="$BOLD" ;;
	esac

	printf "%s[%s]%s %s\n" "${color}" "${level}" "${RESET}" "${msg}"
}

# 6. Sudo Management
init_sudo() {
	log "INFO" "Sudo privileges required. Please authenticate."
	if ! sudo -v; then
		log "ERROR" "Sudo authentication failed."
		exit 1
	fi

	# PATCH: Close FD 9 to prevent the sleep loop from holding the lock
	(
		exec 9>&-
		set +e
		while true; do
			sudo -n true
			sleep "$SUDO_REFRESH_INTERVAL"
			kill -0 "$$" || exit
		done 2>/dev/null
	) &
	SUDO_PID=$!
	disown "$SUDO_PID"
}

cleanup() {
	local exit_code=$?
	if [[ -n "${SUDO_PID:-}" ]]; then
		kill "$SUDO_PID" 2>/dev/null || true
	fi

	if [[ $EXECUTION_PHASE -eq 1 ]]; then
		if [[ $exit_code -eq 0 ]]; then
			log "SUCCESS" "Conductor finished successfully."
		else
			log "ERROR" "Conductor exited with error code $exit_code."
			if [[ "$DISCORD_NOTIFY_ON_ERROR" == "true" ]]; then
				notify_error_to_discord "Conductor" "Failed with exit code $exit_code" "$LOG_FILE"
			fi
		fi
	fi

	# Allow process substitution (tee/sed) to flush final output to log file
	if [[ $LOGGING_INITIALIZED -eq 1 ]]; then
		sleep 0.3
	fi
}
trap cleanup EXIT

# 7. Utility Functions
trim() {
	local var="$*"
	var="${var#"${var%%[![:space:]]*}"}"
	var="${var%"${var##*[![:space:]]}"}"
	printf '%s' "$var"
}

# O(1) Memory State Loader (STRICT MODE SAFE)
load_state() {
	# Safely wipe the associative array without losing the -A flag
	unset COMPLETED_SCRIPTS
	declare -gA COMPLETED_SCRIPTS=()

	# Only attempt to read if the file exists AND is > 0 bytes (-s)
	if [[ -s "$STATE_FILE" ]]; then
		# Explicitly declare array to prevent set -u unbound variable exceptions
		local _state_lines=()
		mapfile -t _state_lines <"$STATE_FILE" 2>/dev/null || true

		for _line in "${_state_lines[@]}"; do
			# Use proper if-statement to prevent set -e short-circuiting on blank lines
			if [[ -n "$_line" ]]; then
				COMPLETED_SCRIPTS["$_line"]=1
			fi
		done
	fi
}

resolve_script() {
	local name="$1"

	# O(1) Lookup: Check if we've already found this file
	if [[ -n "${SCRIPT_CACHE[$name]:-}" ]]; then
		printf '%s' "${SCRIPT_CACHE[$name]}"
		return 0
	fi

	# Contains a slash → direct path, no searching
	if [[ "$name" == */* ]]; then
		if [[ -f "$name" ]]; then
			SCRIPT_CACHE["$name"]="$name"
			printf '%s' "$name"
			return 0
		fi
		return 1
	fi
	# No slash → search directories in order, first match wins
	for dir in "${SCRIPT_SEARCH_DIRS[@]}"; do
		if [[ -f "${dir}/${name}" ]]; then
			SCRIPT_CACHE["$name"]="${dir}/${name}"
			printf '%s' "${dir}/${name}"
			return 0
		fi
	done
	return 1
}

report_search_locations() {
	local name="$1"
	if [[ "$name" == */* ]]; then
		log "ERROR" "Direct path not found: $name"
	else
		log "ERROR" "Script '$name' not found in any search directory:"
		for dir in "${SCRIPT_SEARCH_DIRS[@]}"; do
			log "ERROR" "  - ${dir}/"
		done
	fi
}

validate_search_dirs() {
	if [[ ${#SCRIPT_SEARCH_DIRS[@]} -eq 0 ]]; then
		log "ERROR" "SCRIPT_SEARCH_DIRS is empty. Add at least one directory."
		exit 1
	fi

	local valid=0
	for dir in "${SCRIPT_SEARCH_DIRS[@]}"; do
		if [[ -d "$dir" ]]; then
			log "INFO" "Search directory OK: $dir"
			((++valid))
		else
			log "WARN" "Search directory not found: $dir"
		fi
	done

	if ((valid == 0)); then
		log "ERROR" "None of the configured search directories exist."
		exit 1
	fi
}

get_script_description() {
	local filepath="$1"
	local desc
	desc=$(sed -n '2s/^#[[:space:]]*//p' "$filepath" 2>/dev/null)
	if [[ -z "$desc" ]]; then
		desc=$(sed -n '3s/^#[[:space:]]*//p' "$filepath" 2>/dev/null)
	fi
	printf "%s" "${desc:-No description available}"
}

preflight_check() {
	local missing=0
	log "INFO" "Performing pre-flight validation..."

	for entry in "${INSTALL_SEQUENCE[@]}"; do
		local rest="${entry#*|}"
		rest=$(trim "$rest")
		local filename args
		read -r filename args <<<"$rest"

		if ! resolve_script "$filename" >/dev/null; then
			log "ERROR" "Missing: ${filename}"
			((++missing))
		fi
	done

	if ((missing > 0)); then
		echo -e "${RED}CRITICAL:${RESET} $missing script(s) could not be found."
		read -r -p "Continue anyway? [y/N]: " _choice
		if [[ "${_choice,,}" != "y" ]]; then
			log "ERROR" "Aborting execution."
			exit 1
		fi
	else
		log "SUCCESS" "All sequence files verified and cached."
	fi
}

show_help() {
	cat <<EOF
Arch Linux Master Conductor

Usage: $(basename "$0") [OPTIONS]

Options:
    --help, -h       Show this help message and exit
    --dry-run, -d    Preview execution plan without running anything
    --reset          Clear progress state and start fresh

Description:
    This script conducts the execution of multiple setup scripts
    for Arch Linux with Hyprland. It tracks completed scripts and
    can resume from where it left off if interrupted.

    Scripts are searched in the directories listed in SCRIPT_SEARCH_DIRS
    (first match wins). Entries with a / in the name are treated as
    direct absolute paths.

Examples:
    $(basename "$0")              # Normal run
    $(basename "$0") --dry-run    # Preview what would be executed
    $(basename "$0") --reset      # Reset progress and start over
EOF
	exit 0
}

main() {
	# Root User Guard
	if [[ $EUID -eq 0 ]]; then
		echo -e "${RED}CRITICAL ERROR: This script must NOT be run as root!${RESET}"
		echo "The script handles sudo privileges internally for specific steps."
		echo "Please run as a normal user: ./Conductor.sh"
		exit 1
	fi

	# --- READ-ONLY ARGUMENT HANDLING ---
	case "${1:-}" in
	--help | -h)
		show_help
		;;
	--dry-run | -d)
		load_state
		echo -e "\n${YELLOW}=== DRY RUN MODE ===${RESET}"
		echo -e "State file: ${BOLD}${STATE_FILE}${RESET}\n"

		echo "Search directories:"
		for dir in "${SCRIPT_SEARCH_DIRS[@]}"; do
			if [[ -d "$dir" ]]; then
				echo -e "  ${GREEN}✓${RESET} $dir"
			else
				echo -e "  ${RED}✗${RESET} $dir ${RED}(not found)${RESET}"
			fi
		done
		echo ""

		echo "Execution plan:"
		echo ""

		local i=0
		local completed_count=0
		local missing_count=0

		for entry in "${INSTALL_SEQUENCE[@]}"; do
			((++i))
			local mode="${entry%%|*}"
			local rest="${entry#*|}"
			mode=$(trim "$mode")
			rest=$(trim "$rest")

			local filename args
			read -r filename args <<<"$rest"

			local mode_label="USER"
			if [[ "$mode" == "S" ]]; then mode_label="SUDO"; fi

			local status=""

			if ! resolve_script "$filename" >/dev/null; then
				status="${RED}[MISSING]${RESET}"
				((++missing_count))
			elif [[ -n "${COMPLETED_SCRIPTS[$filename]:-}" ]]; then
				status="${GREEN}[DONE]${RESET}"
				((++completed_count))
			else
				status="${BLUE}[PENDING]${RESET}"
			fi

			printf "  %3d. [%s] %-45s %s\n" "$i" "$mode_label" "${filename}${args:+ $args}" "$status"
		done

		echo ""
		echo -e "${BOLD}Summary:${RESET}"
		echo -e "  Total scripts: $i"
		echo -e "  Completed: ${GREEN}${completed_count}${RESET}"
		echo -e "  Pending: ${BLUE}$((i - completed_count - missing_count))${RESET}"
		if [[ $missing_count -gt 0 ]]; then echo -e "  Missing: ${RED}${missing_count}${RESET}"; fi
		echo ""
		echo "No changes were made."
		exit 0
		;;
	esac

	# --- CONCURRENT EXECUTION GUARD ---
	exec 9>"$LOCK_FILE"
	if ! flock -n 9; then
		echo -e "${RED}ERROR: Another instance of this script is already running.${RESET}"
		exit 1
	fi

	# --- MUTATING ARGUMENT HANDLING ---
	case "${1:-}" in
	--reset)
		rm -f "$STATE_FILE"
		echo "State file reset. Starting fresh."
		;;
	"") ;;
	*)
		echo -e "${RED}ERROR: Unknown option '${1}'${RESET}"
		echo "Use --help to see available options."
		exit 1
		;;
	esac

	setup_logging
	validate_search_dirs
	preflight_check

	# Start timer
	local start_ts=$SECONDS

	# Check for sudo requirement
	local needs_sudo=0
	for entry in "${INSTALL_SEQUENCE[@]}"; do
		if [[ "$entry" == S* ]]; then
			needs_sudo=1
			break
		fi
	done

	if [[ $needs_sudo -eq 1 ]]; then
		init_sudo
	fi

	touch "$STATE_FILE"

	# --- SESSION RECOVERY PROMPT ---
	if [[ -s "$STATE_FILE" ]]; then
		echo -e "\n${YELLOW}>>> PREVIOUS SESSION DETECTED <<<${RESET}"
		read -r -p "Do you want to [C]ontinue where you left off or [S]tart over? [C/s]: " _session_choice
		if [[ "${_session_choice,,}" == "s" || "${_session_choice,,}" == "start" ]]; then
			rm -f "$STATE_FILE"
			touch "$STATE_FILE"
			log "INFO" "State file reset. Starting fresh."
		else
			log "INFO" "Continuing from previous session."
		fi
	fi

	# Load State into O(1) Memory Array
	load_state

	# --- EXECUTION MODE SELECTION ---
	local interactive_mode=0
	echo -e "\n${YELLOW}>>> EXECUTION MODE <<<${RESET}"
	read -r -p "Do you want to run interactively (prompt before every script)? [y/N]: " _mode_choice
	if [[ "${_mode_choice,,}" == "y" || "${_mode_choice,,}" == "yes" ]]; then
		interactive_mode=1
		log "INFO" "Interactive mode selected. You will be asked before each script."
	else
		log "INFO" "Autonomous mode selected. Running all scripts without confirmation."
	fi

	local total_scripts=${#INSTALL_SEQUENCE[@]}
	local current_index=0
	log "INFO" "Processing ${total_scripts} scripts..."

	local SKIPPED_OR_FAILED=()

	EXECUTION_PHASE=1

	for entry in "${INSTALL_SEQUENCE[@]}"; do
		((++current_index))

		local mode="${entry%%|*}"
		local rest="${entry#*|}"

		mode=$(trim "$mode")
		rest=$(trim "$rest")

		# Separate filename from arguments
		local filename args
		read -r filename args <<<"$rest"

		# --- RESOLVE SCRIPT PATH ---
		local script_path=""
		while true; do
			if script_path=$(resolve_script "$filename"); then
				break
			fi
			report_search_locations "$filename"
			echo -e "${YELLOW}Action Required:${RESET} File is missing."
			read -r -p "Do you want to [S]kip to next, [R]etry check, or [Q]uit? (s/r/q): " _choice

			case "${_choice,,}" in
			s | skip)
				log "WARN" "Skipping $filename (User Selection)"
				SKIPPED_OR_FAILED+=("$filename")
				continue 2
				;;
			r | retry)
				log "INFO" "Retrying check for $filename..."
				sleep 1
				;;
			*)
				log "INFO" "Stopping execution. Place the script in one of the search directories and rerun."
				exit 1
				;;
			esac
		done

		# --- STATE FILE SKIP CHECK (O(1) Array Lookup) ---
		if [[ -n "${COMPLETED_SCRIPTS[$filename]:-}" ]]; then
			log "WARN" "[${current_index}/${total_scripts}] Skipping $filename (Already Completed)"
			continue
		fi

		# --- USER CONFIRMATION PROMPT (CONDITIONAL) ---
		if [[ $interactive_mode -eq 1 ]]; then
			local desc
			desc=$(get_script_description "$script_path")

			echo -e "\n${YELLOW}>>> NEXT SCRIPT [${current_index}/${total_scripts}]:${RESET} $filename${args:+ $args} ($mode)"
			echo -e "    ${BOLD}Description:${RESET} $desc"

			read -r -p "Do you want to [P]roceed, [S]kip, or [Q]uit? (p/s/q): " _user_confirm
			case "${_user_confirm,,}" in
			s | skip)
				log "WARN" "Skipping $filename (User Selection)"
				SKIPPED_OR_FAILED+=("$filename")
				continue
				;;
			q | quit)
				log "INFO" "User requested exit."
				exit 0
				;;
			*)
				# Fall through to execution
				;;
			esac
		fi

		# --- EXECUTION RETRY LOOP ---
		while true; do
			log "RUN" "[${current_index}/${total_scripts}] Executing: ${filename}${args:+ $args} ($mode)"

			local result=0
			set -f
			if [[ "$mode" == "S" ]]; then
				(cd "$(dirname "$script_path")" && sudo bash "$(basename "$script_path")" $args) || result=$?
			elif [[ "$mode" == "U" ]]; then
				(cd "$(dirname "$script_path")" && bash "$(basename "$script_path")" $args) || result=$?
			else
				log "ERROR" "Invalid mode '$mode' in config. Use 'S' or 'U'."
				exit 1
			fi
			set +f

			if [[ $result -eq 0 ]]; then
				echo "$filename" >>"$STATE_FILE"
				COMPLETED_SCRIPTS["$filename"]=1 # Update Memory Array instantly
				log "SUCCESS" "Finished $filename"
				if [[ "$POST_SCRIPT_DELAY" != "0" ]]; then
					sleep "$POST_SCRIPT_DELAY"
				fi
				break
			else
				log "ERROR" "Failed $filename (Exit Code: $result)."
				notify_error_to_discord "$filename" "Exit code: $result" "$LOG_FILE"

				echo -e "${YELLOW}Action Required:${RESET} Script execution failed."
				read -r -p "Do you want to [S]kip to next, [R]etry, or [Q]uit? (s/r/q): " _fail_choice

				case "${_fail_choice,,}" in
				s | skip)
					log "WARN" "Skipping $filename (User Selection). NOT marking as complete."
					SKIPPED_OR_FAILED+=("$filename")
					break
					;;
				r | retry)
					log "INFO" "Retrying $filename..."
					sleep 1
					continue
					;;
				*)
					log "INFO" "Stopping execution as requested."
					exit 1
					;;
				esac
			fi
		done
	done

	# --- SUMMARY OF FAILED / SKIPPED SCRIPTS ---
	if [[ ${#SKIPPED_OR_FAILED[@]} -gt 0 ]]; then
		echo -e "\n${YELLOW}================================================================${RESET}"
		echo -e "${YELLOW}NOTE: Some scripts were skipped or failed:${RESET}"
		for f in "${SKIPPED_OR_FAILED[@]}"; do
			echo " - $f"
		done
		echo -e "\nYou can run them individually from their respective directories:"
		for dir in "${SCRIPT_SEARCH_DIRS[@]}"; do
			if [[ -d "$dir" ]]; then echo -e "  ${BOLD}${dir}/${RESET}"; fi
		done
		echo -e "${YELLOW}================================================================${RESET}\n"
	fi

	# --- DEPENDENCY VERIFICATION ---
	verify_dependencies

	# Calculate elapsed time
	local end_ts=$SECONDS
	local duration=$((end_ts - start_ts))
	local minutes=$((duration / 60))
	local seconds=$((duration % 60))

	# --- COMPLETION & REBOOT NOTICE ---
	echo -e "\n${GREEN}================================================================${RESET}"
	echo -e "${BOLD}FINAL INSTRUCTIONS:${RESET}"
	echo -e "1. Execution Time: ${BOLD}${minutes}m ${seconds}s${RESET}"
	echo -e "2. Please ${BOLD}REBOOT YOUR SYSTEM${RESET} for all changes to take effect."
	echo -e "3. This script is designed to be run multiple times."
	echo -e "   If you think something wasn't done right, you can run this script again."
	echo -e "   It will ${BOLD}NOT${RESET} re-download the whole thing again, but instead"
	echo -e "   only download/configure what might have failed the first time."
	echo -e "${GREEN}================================================================${RESET}\n"
}

main "$@"
