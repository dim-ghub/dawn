#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

# Always kill swww-daemon for power saving
cleanup_swww() {
	run_quiet pkill swww-daemon
	log_step "swww-daemon terminated."
}

# Skip theme switch if not requested
if [[ "${POWER_SAVER_THEME:-false}" != "true" ]]; then
	cleanup_swww
	exit 0
fi

echo
log_step "Module 05: Theme Switch"

gum style --foreground 212 "Executing theme switch..."
gum style --foreground 240 "(Terminal may close - this is expected)"
sleep 1

if "${THEME_SCRIPT}" --mode light; then
	sleep 2
	cleanup_swww
	log_step "Theme switched to light mode."
else
	log_error "Theme switch failed."
	cleanup_swww
	exit 1
fi
