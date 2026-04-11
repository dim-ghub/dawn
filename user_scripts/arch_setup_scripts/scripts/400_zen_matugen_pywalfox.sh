#!/usr/bin/env bash
# zen-browser setup for matugen theming with PywalZen
# -----------------------------------------------------------------------------
# Script: 400_zen_matugen_pywalfox.sh
# Description: Setup Zen Browser, PywalZen mod, PywalFox, and Matugen
# Environment: Arch Linux / Hyprland / UWSM
# -----------------------------------------------------------------------------

# --- Safety & Error Handling ---
set -euo pipefail
IFS=$'\n\t'
trap 'printf "\n[WARN] Script interrupted. Exiting.\n" >&2; exit 130' INT TERM

# --- Configuration ---
readonly TARGET_URL='https://addons.mozilla.org/en-US/firefox/addon/pywalfox/'
readonly BROWSER_BIN='zen-browser'
readonly AUR_PKG='zen-browser-bin'
readonly NATIVE_HOST_PKG='python-pywalfox'
readonly THEME_ENGINE_PKG='matugen'
readonly PYWALZEN_REPO='https://github.com/Axenide/PywalZen'

# --- Visual Styling ---
if command -v tput &>/dev/null && (($(tput colors 2>/dev/null || echo 0) >= 8)); then
	readonly C_RESET=$'\033[0m'
	readonly C_BOLD=$'\033[1m'
	readonly C_BLUE=$'\033[38;5;45m'
	readonly C_GREEN=$'\033[38;5;46m'
	readonly C_MAGENTA=$'\033[38;5;177m'
	readonly C_WARN=$'\033[38;5;214m'
	readonly C_ERR=$'\033[38;5;196m'
else
	readonly C_RESET='' C_BOLD='' C_BLUE='' C_GREEN=''
	readonly C_MAGENTA='' C_WARN='' C_ERR=''
fi

# --- Logging Utilities ---
log_info() { printf '%b[INFO]%b %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf '%b[SUCCESS]%b %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%b[WARNING]%b %s\n' "${C_WARN}" "${C_RESET}" "$1" >&2; }
die() {
	printf '%b[ERROR]%b %s\n' "${C_ERR}" "${C_RESET}" "$1" >&2
	exit 1
}

# --- Helper Functions ---
check_aur_helper() {
	if command -v paru &>/dev/null; then
		echo "paru"
	elif command -v yay &>/dev/null; then
		echo "yay"
	else return 1; fi
}

preflight() {
	if ((EUID == 0)); then die 'Run as normal user, not Root.'; fi
}

# --- Main Logic ---
main() {
	preflight

	# 1. Interactive Prompt (No Timeout)
	printf '\n%b>>> OPTIONAL SETUP: ZEN BROWSER, PYWALZEN & MATUGEN%b\n' "${C_WARN}" "${C_RESET}"
	printf 'This will install Zen Browser, Matugen, PywalFox backend, and the PywalZen mod.\n'
	printf '%bDo you want to proceed? [y/N]:%b ' "${C_BOLD}" "${C_RESET}"

	local response=''
	read -r response || true

	if [[ ! "${response,,}" =~ ^y(es)?$ ]]; then
		log_info 'Skipping setup by user request.'
		exit 0
	fi

	# 2. Standard Packages (matugen is from pacman or AUR)
	log_info "Ensuring ${THEME_ENGINE_PKG} is installed..."
	if sudo pacman -S --needed --noconfirm "${THEME_ENGINE_PKG}" 2>/dev/null; then
		log_success "matugen verified."
	elif pacman -Qi matugen-bin &>/dev/null; then
		log_success "matugen-bin (AUR) already installed."
	else
		log_warn "matugen not found via pacman. Attempting AUR install..."
		local helper
		if helper=$(check_aur_helper); then
			"$helper" -S --needed --noconfirm matugen-bin || log_warn "matugen AUR install failed — install manually."
		else
			log_warn "No AUR helper found. Install matugen manually."
		fi
	fi

	# 3. Install Zen Browser from AUR
	log_info "Installing ${AUR_PKG}..."
	local helper
	if helper=$(check_aur_helper); then
		if pacman -Qi "${AUR_PKG}" &>/dev/null; then
			log_success "${AUR_PKG} is already installed."
		else
			log_info "Installing ${AUR_PKG} via ${helper}..."
			"$helper" -S --needed --noconfirm "${AUR_PKG}"
			log_success "${AUR_PKG} installed."
		fi
	else
		die "No AUR helper found. Cannot install ${AUR_PKG}."
	fi

	# 4. Pywalfox Native Host
	log_info "Handling ${NATIVE_HOST_PKG}..."
	if helper=$(check_aur_helper); then
		# Check if installed, then NUKE it to force clean rebuild
		if pacman -Qq "${NATIVE_HOST_PKG}" &>/dev/null; then
			log_warn "Existing ${NATIVE_HOST_PKG} found. Removing to enforce clean rebuild..."
			sudo pacman -Rns --noconfirm "${NATIVE_HOST_PKG}" || true
		fi

		log_info "Installing/Rebuilding ${NATIVE_HOST_PKG} with ${helper}..."
		if "$helper" -S --rebuild --noconfirm "${NATIVE_HOST_PKG}"; then
			log_success "${NATIVE_HOST_PKG} ready."

			# Auto-register manifest
			if command -v pywalfox &>/dev/null; then
				log_info "Refreshing manifest..."
				pywalfox install || log_warn "Manifest update failed (non-fatal)."
			fi
		else
			die "Failed to install ${NATIVE_HOST_PKG}."
		fi
	else
		log_warn "No AUR helper found. Skipping Pywalfox backend."
	fi

	# 5. Install PywalZen mod for Zen Browser
	log_info "Setting up PywalZen mod..."

	# Find the first Zen profile directory
	local zen_profile_dir=""
	local zen_base_dir="$HOME/.config/zen"
	if [[ -d "$zen_base_dir" ]]; then
		for profile_dir in "$zen_base_dir"/*.default-release "$zen_base_dir"/*.default; do
			if [[ -d "$profile_dir" ]]; then
				zen_profile_dir="$profile_dir"
				break
			fi
		done
	fi

	if [[ -n "$zen_profile_dir" ]]; then
		local mod_dir="$zen_profile_dir/chrome/zen-themes/pywalzen"
		mkdir -p -- "$mod_dir"

		# Clone or update PywalZen
		local tmp_clone
		tmp_clone=$(mktemp -d)
		if git clone --depth 1 "$PYWALZEN_REPO" "$tmp_clone" 2>/dev/null; then
			cp -f -- "$tmp_clone/chrome.css" "$mod_dir/chrome.css" 2>/dev/null || true
			cp -f -- "$tmp_clone/preferences.json" "$mod_dir/preferences.json" 2>/dev/null || true
			log_success "PywalZen mod files copied to profile."
		else
			log_warn "Could not clone PywalZen repo. Install manually from: $PYWALZEN_REPO"
		fi
		rm -rf -- "$tmp_clone"

		# Register the mod in zen-themes.json
		local themes_json="$zen_profile_dir/zen-themes.json"
		if [[ -f "$themes_json" ]]; then
			if ! grep -q '"pywalzen"' "$themes_json" 2>/dev/null; then
				local tmp_json
				tmp_json=$(mktemp "${themes_json}.XXXXXXXXXX")
				if python3 -c "
import json, sys
with open('$themes_json') as f:
    d = json.load(f)
d['pywalzen'] = {
    'id': 'pywalzen',
    'name': 'PywalZen',
    'description': 'Applies Pywal/Matugen colors to Zen Browser via PywalFox',
    'author': 'Axenide',
    'enabled': True,
    'preferences': True,
    'version': '1.0.0'
}
with open('$tmp_json', 'w') as f:
    json.dump(d, f, indent=2)
" 2>/dev/null; then
					mv -f -- "$tmp_json" "$themes_json"
					log_success "PywalZen mod registered in zen-themes.json."
				else
					rm -f -- "$tmp_json"
					log_warn "Could not auto-register mod. Add it manually in Zen Settings → Mods."
				fi
			else
				log_success "PywalZen mod already registered."
			fi
		else
			mkdir -p -- "$zen_profile_dir"
			cat >"$themes_json" <<'THEMESJSON'
{
  "pywalzen": {
    "id": "pywalzen",
    "name": "PywalZen",
    "description": "Applies Pywal/Matugen colors to Zen Browser via PywalFox",
    "author": "Axenide",
    "enabled": true,
    "preferences": true,
    "version": "1.0.0"
  }
}
THEMESJSON
			log_success "Created zen-themes.json with PywalZen mod."
		fi
	else
		log_warn "Zen Browser profile directory not found. Launch Zen Browser once first, then re-run this script."
		log_warn "PywalZen mod will need to be installed manually from: $PYWALZEN_REPO"
	fi

	# 6. Configure Matugen template for PywalFox integration
	log_info "Configuring Matugen PywalFox template..."
	readonly MATUGEN_CONFIG="$HOME/.config/matugen/config.toml"

	# Create the pywalfox colors template
	local template_dir="$HOME/.config/matugen/templates"
	mkdir -p -- "$template_dir"

	cat >"$template_dir/pywalfox-colors.json" <<'PYWALFOX_TEMPLATE'
{
  "wallpaper": "{{image}}",
  "alpha": "100",
  "colors": {
    "color0":  "{{colors.background.default.hex}}",
    "color1":  "",
    "color2":  "",
    "color3":  "",
    "color4":  "",
    "color5":  "",
    "color6":  "",
    "color7":  "",
    "color8":  "",
    "color9":  "",
    "color10": "{{colors.primary.default.hex}}",
    "color11": "",
    "color12": "",
    "color13": "{{colors.surface_bright.default.hex}}",
    "color14": "",
    "color15": "{{colors.on_surface.default.hex}}"
  }
}
PYWALFOX_TEMPLATE
	log_success "Created pywalfox-colors.json template."

	# Add pywalfox template block to matugen config
	read -r -d '' PYWALFOX_BLOCK <<'TOML' || true
[templates.pywalfox]
input_path  = '~/.config/matugen/templates/pywalfox-colors.json'
output_path = '~/.config/matugen/generated/pywalfox-colors.json'
post_hook   = '''
bash -c '
{
  mkdir -p "$HOME/.cache/wal"
  ln -nfs "$HOME/.config/matugen/generated/pywalfox-colors.json" "$HOME/.cache/wal/colors.json"
  pywalfox update
} >/dev/null 2>&1 </dev/null & disown
'''
TOML
	readonly PYWALFOX_BLOCK

	if [[ ! -f "$MATUGEN_CONFIG" ]]; then
		log_info "Matugen config missing. Creating..."
		printf '%s\n' "$PYWALFOX_BLOCK" >"$MATUGEN_CONFIG"
		log_success "Created matugen config with PywalFox template."
	elif grep -qE '^[[:space:]]*\[templates\.pywalfox\]' "$MATUGEN_CONFIG"; then
		log_success "PywalFox template already active in Matugen config."
	elif grep -qE '^[[:space:]]*#.*\[templates\.pywalfox\]' "$MATUGEN_CONFIG"; then
		log_warn "PywalFox template exists but is commented out."
		log_warn "Please manually uncomment the [templates.pywalfox] block in: $MATUGEN_CONFIG"
	else
		log_info "Appending PywalFox template to Matugen config..."
		printf '\n%s\n' "$PYWALFOX_BLOCK" >>"$MATUGEN_CONFIG"
		log_success "Appended PywalFox template."
	fi

	# 7. Instructions
	hash -r 2>/dev/null || true
	if [[ -t 1 ]]; then clear; fi

	printf '%b%b' "${C_BOLD}" "${C_BLUE}"
	cat <<'BANNER'
   ╔═══════════════════════════════════════╗
   ║     ZEN BROWSER + PYWALFOX SETUP      ║
   ║        Arch / Hyprland / UWSM          ║
   ╚═══════════════════════════════════════╝
BANNER
	printf '%b\n' "${C_RESET}"
	printf "%b[Action Required]%b: Open Zen Browser → Install Extensions → PywalFox → 'Fetch Pywal Colors'\n" "${C_WARN}" "${C_RESET}"
	printf "Then enable the PywalZen mod in %bZen Settings → Mods%b.\n" "${C_BOLD}" "${C_RESET}"
	printf "Press %b[ENTER]%b to launch Zen Browser..." "${C_GREEN}" "${C_RESET}"
	read -r || true

	# 8. Launch Browser
	log_info "Launching..."
	nohup "${BROWSER_BIN}" "${TARGET_URL}" &>/dev/null 2>&1 &
	disown &>/dev/null || true
}

main "$@"
