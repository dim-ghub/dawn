# DuskyRC - Artix Linux (OpenRC) Port

This document outlines the changes made to port DuskyRC from Arch Linux (systemd) to Artix Linux (OpenRC).

## Overview

The main differences between systemd and OpenRC:
- OpenRC uses `/etc/init.d/` for service scripts instead of `.service` files
- OpenRC uses `rc-service`, `rc-update`, and `rc-status` instead of `systemctl`
- For session management, we use `elogind` (compatible with systemd-logind behavior)
- For user services without systemd, we use direct process spawning with fallback

## New Files Created

### OpenRC Init Scripts
Located in `user_scripts/openrc/init.d/`:
- `waybar` - Waybar status bar
- `pipewire` - Audio server
- `wireplumber` - PipeWire session manager
- `network-meter` - Network speed monitoring daemon
- `dusky-sliders` - System control sliders
- `update-checker` - Update checking service
- `battery-notify` - Battery notifications
- `dusky-control-center` - Control center
- `swww` - Wallpaper daemon

### OpenRC Timer
Located in `user_scripts/openrc/timers/`:
- `update-checker-timer` - Periodic update checking

### OpenRC Service Manager
- `user_scripts/services/dusky_service_manager_openrc.sh` - Declarative service state manager

### OpenRC Service Toggle
- `user_scripts/services/dusky_service_toggle_openrc.sh` - Interactive TUI for toggling services

### OpenRC Session Management
- `user_scripts/wlogout/dusky_session_openrc.sh` - Session/power actions (logout, suspend, reboot, etc.)
- `user_scripts/power/dusky_power_openrc.sh` - Power settings management (elogind/login.conf)

## Modified Scripts

The following scripts have been updated to detect and use OpenRC when available:

1. **powermenu.sh** - Now uses OpenRC session script when systemd is not available
2. **waybar_autostart.sh** - Falls back to OpenRC service or direct launch
3. **dusky_wayclick.sh** - Uses rc-service for PipeWire when systemd unavailable
4. **reload_sliders.sh** - Supports both systemd and OpenRC service management
5. **restart_swayosd.sh** - Supports OpenRC service or fallback
6. **theme_ctl.sh** - Supports OpenRC swww service

## Usage

### Managing Services (OpenRC)

```bash
# Start a service
sudo rc-service waybar start

# Enable service at boot
sudo rc-update add waybar default

# Check status
rc-status

# View all available services
rc-service -l
```

### Using the Service Manager

```bash
# Run the declarative service manager
sudo ./user_scripts/services/dusky_service_manager_openrc.sh

# Dry-run mode
sudo ./user_scripts/services/dusky_service_manager_openrc.sh --dry-run
```

### Using the Service Toggle

```bash
# Interactive TUI
./user_scripts/services/dusky_service_toggle_openrc.sh

# List all services
./user_scripts/services/dusky_service_toggle_openrc.sh --list

# Toggle specific service
./user_scripts/services/dusky_service_toggle_openrc.sh --toggle waybar
```

### Session Management

```bash
# Logout
./user_scripts/wlogout/dusky_session_openrc.sh logout

# Suspend
./user_scripts/wlogout/dusky_session_openrc.sh suspend

# Reboot
./user_scripts/wlogout/dusky_session_openrc.sh reboot

# Poweroff
./user_scripts/wlogout/dusky_session_openrc.sh poweroff
```

### Power Settings

```bash
# Interactive power configuration
sudo ./user_scripts/power/dusky_power_openrc.sh
```

## Dependencies

For full functionality on Artix Linux, install these packages:

```bash
# Core OpenRC
pacman -S openrc

# For session management (elogind - compatible with loginctl)
pacman -S elogind

# For service management tools
pacman -S util-linux

# Optional: ConsoleKit2 as alternative to elogind
# pacman -S consolekit2
```

## Service Files Mapping

| Systemd (.service) | OpenRC (/etc/init.d/) |
|-------------------|----------------------|
| waybar.service | waybar |
| pipewire.service | pipewire |
| wireplumber.service | wireplumber |
| network-meter.service | network-meter |
| dusky_sliders.service | dusky-sliders |
| update-checker.service | update-checker |
| swww.service | swww |
| hypridle.service | hypridle |
| hyprpolkitagent.service | hyprpolkitagent |
| swayosd.service | swayosd |

## Notes

1. **elogind**: Provides `loginctl` compatibility which is used by many scripts for session management (suspend, hibernate, power-off).

2. **User Services**: OpenRC doesn't have a built-in concept of user services like systemd. The scripts handle this by either:
   - Using direct process spawning (setsid)
   - Using the OpenRC init scripts in `/etc/init.d/` (requires root)
   - Falling back to process management with pgrep/pkill

3. **Timers**: OpenRC doesn't have native timer units. The update-checker-timer uses a simple loop with sleep for periodic execution. Consider using cron as an alternative.

4. **UWSM Removed**: UWSM (Universal Wayland Session Manager) has been removed as it requires systemd. Applications are now launched directly in autostart.conf without any session manager wrapper.
