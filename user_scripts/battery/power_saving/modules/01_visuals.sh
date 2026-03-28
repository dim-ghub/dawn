#!/usr/bin/env bash
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

echo
log_step "Module 01: Visual Effects"

# Disable blur/opacity/shadow
run_external_script "${BLUR_SCRIPT}" "Disabling blur/opacity/shadow..." off

# Disable Hyprshade
if has_cmd hyprshade; then
	spin_exec "Disabling Hyprshade..." hyprshade off
fi

log_step "Visual effects configuration complete."
