#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

if [[ "${RESTORE_THEME:-false}" != "true" ]]; then
	exit 0
fi

printf '\n'
log_step "Module 05: Theme Switch"

gum style --foreground 212 "Switching to Dark Mode..."

if "${THEME_SCRIPT}" --mode dark; then
	log_step "Theme switched to Dark mode."
else
	log_error "Theme switch failed."
	exit 1
fi
