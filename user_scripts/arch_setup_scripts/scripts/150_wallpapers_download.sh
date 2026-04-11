#!/usr/bin/env bash
# Downloads dawn wallpapers and copies them to the required directory

set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly ZIP_URL="https://github.com/dusklinux/images/archive/refs/heads/main.zip"
readonly TARGET_PARENT="${HOME:?HOME not set}/Pictures"
readonly WALLPAPERS_DIR="${TARGET_PARENT}/wallpapers"
readonly CACHE_DIR="${TARGET_PARENT}/.dusk-wallpapers-cache"
readonly CACHE_FILE="${CACHE_DIR}/dusk-wallpapers.zip"

# --- Terminal Setup (graceful degradation) -----------------------------------
if [[ -t 1 ]]; then
	readonly RST=$'\033[0m' BOLD=$'\033[1m'
	readonly RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' BLU=$'\033[34m'
	readonly CLR=$'\033[K'
	readonly IS_TTY=1
else
	readonly RST='' BOLD='' RED='' GRN='' YEL='' BLU='' CLR=''
	readonly IS_TTY=0
fi

# --- Logging -----------------------------------------------------------------
log_info() { printf '%s[INFO]%s %s\n' "${BLU}" "${RST}" "$*"; }
log_ok() { printf '%s[ OK ]%s %s\n' "${GRN}" "${RST}" "$*"; }
log_warn() { printf '%s[WARN]%s %s\n' "${YEL}" "${RST}" "$*" >&2; }
log_error() { printf '%s[ERR ]%s %s\n' "${RED}" "${RST}" "$*" >&2; }

# --- Status Indicator --------------------------------------------------------
CURRENT_STATUS=""

status_begin() {
	CURRENT_STATUS="$1"
	if ((IS_TTY)); then
		printf '\r%s[....]%s %s%s' "${BLU}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
	fi
}

status_end() {
	local -r rc=$1
	if ((IS_TTY)); then
		if ((rc == 0)); then
			printf '\r%s[ OK ]%s %s%s\n' "${GRN}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
		else
			printf '\r%s[FAIL]%s %s%s\n' "${RED}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
		fi
	else
		if ((rc == 0)); then
			log_ok "${CURRENT_STATUS}"
		else
			log_error "${CURRENT_STATUS}"
		fi
	fi
	CURRENT_STATUS=""
}

# --- Cleanup Trap ------------------------------------------------------------
cleanup() {
	local -r exit_code=$?
	# If the script dies while a spinner is active, close it with FAIL
	if [[ -n "${CURRENT_STATUS}" ]]; then
		status_end 1
	fi
	if ((exit_code != 0 && exit_code != 130)); then
		log_error "Script failed (exit ${exit_code})."
		if [[ -f "${CACHE_FILE}" ]]; then
			log_warn "Partial download preserved at: ${CACHE_FILE}"
		fi
	fi
}
trap cleanup EXIT

# --- Dependency Verification -------------------------------------------------
check_deps() {
	local -a missing=()
	local dep
	for dep in curl unzip; do
		command -v "${dep}" &>/dev/null || missing+=("${dep}")
	done

	if ((${#missing[@]} > 0)); then
		log_error "Missing dependencies: ${missing[*]}"
		return 1
	fi
	return 0
}

# --- Download ----------------------------------------------------------------
download_archive() {
	# Validate existing cache before re-downloading
	if [[ -f "${CACHE_FILE}" ]]; then
		status_begin "Verifying existing cache"
		if unzip -tq "${CACHE_FILE}" &>/dev/null; then
			status_end 0
			log_ok "Valid archive found. Skipping download."
			return 0
		fi
		status_end 1
		log_warn "Existing cache is invalid. Re-downloading..."
		rm -f -- "${CACHE_FILE}"
	fi

	log_info "Downloading wallpapers (~1.7 GB)..."

	# GitHub-generated zips do not support HTTP range requests (no resume).
	# Added connect-timeout to fail fast on network hangs.
	if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 \
		-o "${CACHE_FILE}" "${ZIP_URL}"; then
		log_error "Download failed."
		rm -f -- "${CACHE_FILE}"
		return 1
	fi
	log_ok "Download complete."

	# Verify integrity of the fresh download
	status_begin "Verifying download integrity"
	if ! unzip -tq "${CACHE_FILE}" &>/dev/null; then
		status_end 1
		log_error "Download corrupted. Please check your connection."
		rm -f -- "${CACHE_FILE}"
		return 1
	fi
	status_end 0
	return 0
}

# --- Archive Extraction ------------------------------------------------------
extract_archive() {
	status_begin "Extracting wallpapers"
	if ! unzip -qo "${CACHE_FILE}" -d "${CACHE_DIR}"; then
		status_end 1
		log_error "Extraction failed."
		return 1
	fi
	status_end 0
	return 0
}

# --- Locate Extracted Directory ----------------------------------------------
find_extracted_root() {
	local -a candidates=()

	# Use local shopt toggling instead of subshell
	shopt -s nullglob
	candidates=("${CACHE_DIR}"/images-*/)
	shopt -u nullglob

	if ((${#candidates[@]} == 0)); then
		log_error "Extracted folder not found in ${CACHE_DIR}."
		return 1
	fi
	printf '%s' "${candidates[0]%/}"
}

# --- Install Wallpapers ------------------------------------------------------
install_wallpapers() {
	local -r src="$1"
	local count=0

	log_info "Installing wallpapers..."

	if [[ -d "${src}/dark" ]]; then
		mv -T -- "${src}/dark" "${WALLPAPERS_DIR}/active_theme"
		log_ok "Installed: dark → wallpapers/active_theme"
		count=$((count + 1))
	else
		log_warn "'dark' directory not found in archive."
	fi

	if [[ -d "${src}/light" ]]; then
		mv -T -- "${src}/light" "${TARGET_PARENT}/light"
		log_ok "Installed: light → Pictures/light"
		count=$((count + 1))
	else
		log_warn "'light' directory not found in archive."
	fi

	if ((count == 0)); then
		log_error "No wallpapers were installed."
		return 1
	fi
	return 0
}

# --- Main Entry Point --------------------------------------------------------
main() {
	printf '%s:: Dusk Wallpaper Installer%s\n' "${BOLD}" "${RST}"
	printf '   Download curated wallpaper collection? (~1.7 GB)\n'

	if [[ ! -t 0 ]]; then
		log_error "Interactive terminal required."
		return 1
	fi

	local response
	read -r -p "   [y/N] > " response
	case "${response,,}" in
	y | yes) ;;
	*)
		log_info "Aborted by user."
		return 0
		;;
	esac

	check_deps
	mkdir -p -- "${TARGET_PARENT}" "${WALLPAPERS_DIR}" "${CACHE_DIR}"

	status_begin "Removing old wallpaper directories"
	if ! rm -rf -- "${TARGET_PARENT}/dark" \
		"${TARGET_PARENT}/light" \
		"${WALLPAPERS_DIR}/active_theme" \
		"${WALLPAPERS_DIR}/dark" \
		"${WALLPAPERS_DIR}/light"; then
		status_end 1
		log_error "Failed to remove old directories."
		return 1
	fi
	status_end 0

	download_archive
	extract_archive

	local extracted_root
	extracted_root=$(find_extracted_root)
	install_wallpapers "${extracted_root}"

	rm -rf -- "${CACHE_DIR}"

	log_ok "Installation complete."
	log_info "Location: ${TARGET_PARENT/#"${HOME}"/\~}"
	return 0
}

main "$@"
