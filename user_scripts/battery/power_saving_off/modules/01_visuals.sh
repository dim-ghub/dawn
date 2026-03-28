#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/common.sh"

printf '\n'
log_step "Module 01: Visual Effects"

# 1. Enable blur/opacity/shadow
# Added '|| true' so a failure here doesn't crash the whole restore process
run_external_script "${BLUR_SCRIPT}" "Enabling blur/opacity/shadow..." on || true

# 2. Restore Hyprshade
if has_cmd hyprshade; then
	spin_exec "Restoring Hyprshade (Auto)..." hyprshade auto || true
fi

log_step "Visual effects restored."
