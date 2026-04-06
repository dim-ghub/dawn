# 🎛️ Dusky Control Center Configuration

This document serves as the master reference for editing `dawn_config.yaml`. The Control Center is a Python/GTK4 application that renders this YAML file dynamically.

> [!TIP] **Hot Reload**
> 
> You do **not** need to restart the application to see changes.
> 
> Press **`Ctrl + R`** while the Control Center is open to reload the configuration instantly.

## 1. High-Level Structure

The configuration follows a strict hierarchy. If indentation is off, the Python parser will fail (gracefully, usually showing an empty state).

```
graph LR
    A[Root: pages] --> B[Page]
    B --> C[Layout: Sections]
    C --> D[Items: Widgets]
    D --> E[Action / Value]
```

### The Skeleton

```
pages:
  - id: unique_id_here       # Internal ID
    title: "Page Title"      # Displayed in Sidebar
    icon: icon-name-symbolic # GTK/Adwaita Icon Name
    layout:
      - type: section        # or 'grid_section'
        properties:
          title: "Group Title"
        items:
          - type: button     # Widget definition
            # ... properties ...
```

## 2. Layout Types

Layouts define how items are arranged within a page.

### A. List Section (`type: section`)

Standard rows. Best for lists of settings, toggles, or information.

- **`title`**: Header text.
    
- **`description`**: Subtitle text for the whole group.
    

### B. Grid Section (`type: grid_section`)

Large square cards (2 columns). Best for "Quick Actions" or primary toggles.

- **`title`**: Header text.
    
- **Note**: Items inside grids render differently (larger icons, centered text).
    

## 3. Widget Reference (Items)

### 🔘 Button

A standard clickable action row.

```
- type: button
  properties:
    title: "System Update"
    description: "Runs pacman -Syu"  # Optional
    icon: system-software-update-symbolic
    style: suggested  # Options: 'suggested' (Blue), 'destructive' (Red), or omit for default
  on_press:
    type: exec
    command: kitty --hold sh -c "sudo pacman -Syu"
    terminal: false
```

### 🌗 Toggle

A switch that maintains state (On/Off).

```
- type: toggle
  properties:
    title: "Dark Mode"
    icon: weather-clear-night-symbolic
    key: dawn_theme/state   # FILE/KEY where state is saved
    key_inverse: true        # If true, logic is flipped
    save_as_int: true        # Saves as 1/0 instead of true/false
  on_toggle:
    enabled:
      type: exec
      command: scripts/theme.sh dark
    disabled:
      type: exec
      command: scripts/theme.sh light
```

### 🏷️ Label (Dynamic Info)

Read-only rows that display system information.

```
- type: label
  properties:
    title: "Memory Used"
    icon: memory-symbolic
    interval: 5              # Refresh rate in seconds
  value:
    type: exec               # Source of the text
    command: free -h | awk '/^Mem:/ {print $3}'
```

_Value Source Options:_

1. **`type: exec`**: Output of a bash command.
    
2. **`type: file`**: content of a text file (`path: /path/to/file`).
    
3. **`type: system`**: Internal Python keys (e.g., `kernel_version`, `cpu_model`).
    

### 🎚️ Slider (Brightness/Volume)

> [!WARNING] Experimental
> 
> Sliders generally require specific Python backend handling in `dawn_control_center.py` to map values correctly unless bound to a specific script that accepts arguments.

```
- type: slider
  properties:
    title: "Brightness"
    icon: display-brightness-symbolic
  on_change:
    type: exec
    command: brightnessctl set {}% # '{}' is replaced by value
```

### ⚠️ Warning Banner

A static visual alert used for critical areas.

```
- type: warning_banner
  properties:
    title: "WARNING"
    message: "Editing these files may break your system."
    icon: dialog-warning-symbolic
```

## 4. Execution Patterns (`on_press`)

The `command` field is passed directly to a shell.

### Background Command

Runs silently. Good for toggles, file operations, or launching GUI apps (`thunar`, `firefox`).

```
on_press:
  type: exec
  command: thunar ~/Downloads
  terminal: false
```

### Terminal Command (TUI)

Runs an interactive script or TUI inside a terminal window.

> [!NOTE] The `kitty` Pattern We usually launch a _new_ kitty instance so the control center stays open.

```
on_press:
  type: exec
  # --class: sets Wayland app ID (for window rules)
  # --hold: keeps terminal open after script finishes
  command: kitty --class "update_tui" --title "Updater" --hold sh -c "$HOME/scripts/update.sh"
  terminal: false
```

### Page Navigation

Jumps to another tab within the Control Center.

```
on_press:
  type: redirect
  page: network   # Must match the 'id' of the target page
```

## 5. Icons & Styling

### Icons

The app uses standard **Freedesktop/Adwaita** icon names.

- **Browse Icons:** Use `gtk4-icon-browser` (install via `gtk4-demos` or similar).
    
- **Common Suffix:** usually ends in `-symbolic` for monochrome UI blending.
    
    - `system-run-symbolic`
        
    - `user-trash-symbolic`
        
    - `network-wireless-symbolic`
        

### Styling

Buttons support CSS classes via the `style` property:

- **`suggested