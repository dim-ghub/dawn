#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

# Always kill awww-daemon for power saving
cleanup_awww() {
    run_quiet pkill awww-daemon
    log_step "awww-daemon terminated."
}

# Skip theme switch if not requested
if [[ "${POWER_SAVER_THEME:-false}" != "true" ]]; then
    cleanup_awww
    exit 0
fi

echo
log_step "Module 05: Theme Switch"

if ! has_cmd uwsm-app; then
    log_error "uwsm-app required for theme switch."
    cleanup_awww
    exit 1
fi

gum style --foreground 212 "Executing theme switch..."
gum style --foreground 240 "(Terminal may close - this is expected)"
sleep 1

if uwsm-app -- "${THEME_SCRIPT}" --mode light; then
    sleep 2
    cleanup_awww
    log_step "Theme switched to light mode."
else
    log_error "Theme switch failed."
    cleanup_awww
    exit 1
fi
