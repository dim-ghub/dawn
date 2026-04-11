#!/usr/bin/env bash

# ==============================================================================
#  Equibop & Matugen Automation Suite
#  Target: Arch Linux (Hyprland) | Deps: yay/paru, jq
# ==============================================================================

# --- Strict Mode ---
set -euo pipefail
IFS=$'\n\t'

# --- Formatting (detect color support on stderr, where all logs go) ---
if [[ -t 2 ]]; then
	readonly RED=$'\033[0;31m'
	readonly GREEN=$'\033[0;32m'
	readonly BLUE=$'\033[0;34m'
	readonly YELLOW=$'\033[1;33m'
	readonly NC=$'\033[0m'
else
	readonly RED='' GREEN='' BLUE='' YELLOW='' NC=''
fi

# --- Cleanup Trap & Temp Management ---
_tmp=""
cleanup() {
	local exit_code=$?
	# Clean up temp file if it exists
	[[ -n "$_tmp" ]] && rm -f -- "$_tmp"

	if [[ $exit_code -ne 0 ]]; then
		printf '%s[!] Script failed with exit code %d%s\n' "$RED" "$exit_code" "$NC" >&2
	fi
}
trap cleanup EXIT

# --- Helper Functions (all diagnostic output to stderr) ---
log_info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$1" >&2; }
log_success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$1" >&2; }
log_warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$1" >&2; }
log_error() {
	printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$1" >&2
	exit 1
}

# --- Privilege Check ---
if [[ $EUID -eq 0 ]]; then
	log_error "This script must NOT be run as root. It modifies user configs and uses AUR helpers."
fi

# ==============================================================================
#  Phase 0: User Consent & State Logic
# ==============================================================================

# 1. Check for --auto flag
_auto_mode="false"
for _arg in "$@"; do
	if [[ "$_arg" == "--auto" ]]; then
		_auto_mode="true"
		break
	fi
done

# 2. Define State File
readonly STATE_FILE="$HOME/.config/dawn/settings/equibop_matugen"

# 3. Logic Flow
if [[ "$_auto_mode" == "false" ]]; then
	if [[ -f "$STATE_FILE" ]]; then
		_state=$(<"$STATE_FILE")
		if [[ "$_state" == "declined" ]]; then
			log_info "Equibop installation previously declined (found 'declined' in $STATE_FILE). Skipping."
			exit 0
		fi
		# If 'accepted', proceed normally
	else
		# Prompt the user
		printf '%s[?]%s Do you want to install Equibop? (A Discord client with beautiful Matugen theming and a lot better than the official Discord client with additional features) [Y/n] ' "$YELLOW" "$NC"
		read -r -n 1 _response
		printf '\n' # Fix formatting after read

		mkdir -p -- "${STATE_FILE%/*}"

		if [[ "$_response" =~ ^[Nn]$ ]]; then
			printf 'declined' >"$STATE_FILE"
			log_info "Equibop installation declined. State saved. Exiting."
			exit 0
		else
			printf 'accepted' >"$STATE_FILE"
			log_success "Equibop installation accepted. Proceeding..."
		fi
	fi
fi

# --- Detect AUR Helper ---
AUR_HELPER=""
if command -v paru &>/dev/null; then
	AUR_HELPER="paru"
elif command -v yay &>/dev/null; then
	AUR_HELPER="yay"
else
	log_error "Neither 'paru' nor 'yay' found. Please install an AUR helper."
fi
readonly AUR_HELPER

# ==============================================================================
#  Phase 1: Installation
# ==============================================================================
log_info "Phase 1: Package Management..."

# Ensure jq is installed (vital for JSON editing in Phase 4)
if ! command -v jq &>/dev/null; then
	log_info "Installing dependency: jq..."
	sudo pacman -S --needed --noconfirm jq
fi

# Warn early if matugen is missing (config is written regardless)
if ! command -v matugen &>/dev/null; then
	log_warn "'matugen' is not installed. Theme generation will not work until it is."
fi

# Install equibop-bin
if pacman -Qi equibop-bin &>/dev/null; then
	log_success "equibop-bin is already installed."
else
	log_info "Installing equibop-bin via ${AUR_HELPER}..."
	"$AUR_HELPER" -S --needed --noconfirm equibop-bin
fi

# ==============================================================================
#  Phase 2: Matugen Configuration
# ==============================================================================
log_info "Phase 2: Configuring Matugen..."

readonly MATUGEN_CONFIG="$HOME/.config/matugen/config.toml"
mkdir -p -- "${MATUGEN_CONFIG%/*}"

# Quoted heredoc ('TOML') prevents Bash expansion; $HOME is expanded later
# by the shell when matugen executes the post_hook.
read -r -d '' VESKTOP_BLOCK <<'TOML' || true
[templates.equibop]
input_path  = '~/.config/matugen/templates/midnight-discord.css'
output_path = '~/.config/matugen/generated/midnight-discord.css'
post_hook   = '''
bash -c '
{
  mkdir -p "$HOME/.config/equibop/themes/"
  ln -nfs "$HOME/.config/matugen/generated/midnight-discord.css" "$HOME/.config/equibop/themes/midnight-discord.css"
} >/dev/null 2>&1 </dev/null & disown
'
'''
TOML
readonly VESKTOP_BLOCK

if [[ ! -f "$MATUGEN_CONFIG" ]]; then
	log_info "Matugen config missing. Creating..."
	printf '%s\n' "$VESKTOP_BLOCK" >"$MATUGEN_CONFIG"
	log_success "Created matugen config."
elif grep -qE '^[[:space:]]*\[templates\.equibop\]' "$MATUGEN_CONFIG"; then
	log_success "Equibop template already active in Matugen config."
elif grep -qE '^[[:space:]]*#.*\[templates\.equibop\]' "$MATUGEN_CONFIG"; then
	# Do NOT auto-uncomment. Regex-based uncommenting on multi-line TOML
	# with ''' delimiters is extremely prone to corruption.
	log_warn "Equibop template exists but is commented out."
	log_warn "Please manually uncomment the [templates.equibop] block in: $MATUGEN_CONFIG"
else
	log_info "Appending Equibop template to Matugen config..."
	printf '\n%s\n' "$VESKTOP_BLOCK" >>"$MATUGEN_CONFIG"
	log_success "Appended Equibop template."
fi

# ==============================================================================
#  Phase 3: Pre-emptively Create Theme Symlink
# ==============================================================================
log_info "Phase 3: Enforcing Theme Files..."

readonly SOURCE_CSS="$HOME/.config/matugen/generated/midnight-discord.css"
readonly TARGET_LINK="$HOME/.config/equibop/themes/midnight-discord.css"

mkdir -p -- "${SOURCE_CSS%/*}" "${TARGET_LINK%/*}"

if [[ ! -f "$SOURCE_CSS" ]]; then
	log_warn "Generated CSS not found. Creating placeholder to allow Equibop to load..."
	: >"$SOURCE_CSS"
fi

ln -nfs -- "$SOURCE_CSS" "$TARGET_LINK"
log_success "Symlinked midnight-discord.css to Equibop themes."

# ==============================================================================
#  Phase 4: Equibop Settings Injection
# ==============================================================================
log_info "Phase 4: Injecting Equibop Settings..."

readonly THEME_NAME="midnight-discord.css"
readonly SETTINGS_FILE="$HOME/.config/equibop/settings/settings.json"
mkdir -p -- "${SETTINGS_FILE%/*}"

if [[ ! -f "$SETTINGS_FILE" ]]; then
	log_info "Settings file missing. Creating minimal configuration..."
	# Minimal valid JSON; Equibop merges with its internal defaults at runtime.
	printf '{"enabledThemes": ["%s"]}\n' "$THEME_NAME" >"$SETTINGS_FILE"
	log_success "Created settings.json with '${THEME_NAME}' enabled."
else
	log_info "Settings file exists. Patching..."

	# Pre-flight: fail fast with a clear message on corrupt JSON.
	if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
		log_error "Settings file contains invalid JSON: $SETTINGS_FILE"
	fi

	# Create temp file on the SAME filesystem for atomic mv (rename, not copy).
	_tmp=$(mktemp -p "${SETTINGS_FILE%/*}" .settings.XXXXXXXXXX)

	# Safely use JQ with a temp file and trap cleanup
	jq --arg theme "$THEME_NAME" '
        if .enabledThemes == null then
            .enabledThemes = [$theme]
        elif (.enabledThemes | index($theme)) == null then
            .enabledThemes += [$theme]
        else
            .
        end
    ' "$SETTINGS_FILE" >"$_tmp"

	mv -- "$_tmp" "$SETTINGS_FILE"
	_tmp="" # Clear so trap doesn't attempt to delete the now-renamed file
	log_success "Patched settings.json: '${THEME_NAME}' is enabled."
fi

log_success "Automation Complete. Equibop is ready."
