# Configuration Bible

> $$\!INFO$$
> 
> **System Overview**
> 
> **Version:** 2.0 (Forensic Build)
> 
> **Framework:** GTK4 + Libadwaita
> 
> **Language:** Python 3.14+
> 
> **Config Format:** YAML
> 
> **Architecture:** Daemonized Single-Instance with UWSM Compliance.

## 1. The Architecture: Why it feels instant

Before you configure, understand _why_ Dusky works the way it does.

### The "Restaurant" Analogy

To understand how the configuration works, think of Dusky Control Center like a high-end restaurant:

1. **The YAML (`dawn_config.yaml`) is the Menu.** It lists what is available, the prices, and the descriptions. It doesn't cook the food; it just describes it.
    
2. **The Python Backend (`rows.py`) is the Kitchen.** It takes the order and actually prepares the widget (buttons, sliders, toggles).
    
3. **The Daemon Mode.** Unlike most apps that "close" (shut down the kitchen) when you click 'X', Dusky just turns off the dining room lights. The kitchen staff stays ready in the background. When you open it again, service is instant.
    

### Performance Engineering (The "Kitchen Staff")

> $$\!NOTE$$
> 
> Under the Hood
> 
> - **Thread Safety (The Head Chef):** Every time a label updates or a toggle switches, a background thread handles the work so the main UI (the waiter) never freezes while taking your order.
>     
> - **UWSM Compliance (The Health Inspector):** Apps launched by Dusky are wrapped in `uwsm-app`. This ensures they know they are running in a Hyprland session and don't crash or become "zombies" when you close the Control Center.
>     
> - **Hot Reload (Printing New Menus):** When you save the YAML and hit `Ctrl+R`, Dusky instantly prints a new menu and reorganizes the tables without kicking the customers (you) out.
>     

## 2. Configuration Structure

The configuration file is located at `$HOME/user_scripts/dawn_config.yaml`.

The hierarchy is strict. If the indentation is wrong, the "Menu" is unreadable.

**Pages** $\to$ **Layouts** (Sections) $\to$ **Items** (Widgets)

The `dawn_config.yaml` is the heart of the system with this hierarchical structure:

```
pages (list)
├── id, title, icon (page metadata)
└── layout (list of sections)
    ├── type: "section" | "grid_section" 
    ├── properties (title, description)
    └── items (list of widgets)
        ├── button, toggle, slider, label, selection, entry
        ├── navigation, expander, warning_banner
        ├── grid_card, toggle_card
        └── Properties & Actions
```

```
pages:
  - id: unique_page_id
    title: "Page Title"
    icon: icon-name-symbolic
    layout:
      - type: section
        properties: { ... }
        items: [ ... ]
```

## 3. Widget Reference

This section details every component available in the widget factory (`rows.py`).

### 3.1 Standard Button (`button`)

**Analogy:** The Doorbell.

You press it, and something happens immediately. It doesn't remember if you pressed it 5 minutes ago; it just triggers an action.

- **Event Type:** `on_press`
    
- `type`: Must be `exec` (run command) or `redirect` (change page).
    
- `terminal`: If `true`, opens a Kitty window holding the process (good for scripts that need to show output).
    

```
- type: button
  properties:
    title: System Update
    description: Run the Arch updater
    icon: system-software-update-symbolic
    style: suggested  # Options: default, suggested, destructive
    button_text: "Run"
  on_press:
    type: exec
    command: kitty --hold sh -c "paru -Syu"
    terminal: false
```

### 3.2 Toggle Switch (`toggle`)

**Analogy:** The Light Switch.

This is smarter than a doorbell. It needs to know: "Is the light currently ON?" (Read) and "How do I turn it OFF?" (Write).

> $$\!TIP$$
> 
> The "State Monitor"
> 
> Toggles use a `StateMonitorMixin`. They poll the system every few seconds to ensure the switch on your screen matches reality.

- **Event Type:** `on_toggle`
    
- `state_command`: A shell command. If it returns "enabled", "on", or "active", the switch turns green.
    
- `key`: Alternatively, link to a file in `~/.config/dawn/settings/` for internal state.
    
- `interval`: How often (in seconds) to check the state.
    

```
- type: toggle
  properties:
    title: Wi-Fi
    icon: network-wireless-symbolic
    state_command: nmcli radio wifi
    interval: 5
  on_toggle:
    enabled:
      type: exec
      command: nmcli radio wifi on
    disabled:
      type: exec
      command: nmcli radio wifi off
```

### 3.3 Slider (`slider`)

**Analogy:** The Dimmer Switch.

Used for Volume, Brightness, or any continuous value.

- **Fast Path Optimization:** Unlike buttons, sliders use a direct `subprocess` call to reduce lag while dragging.
    
- `debounce`: If `true`, waits for you to _stop_ dragging before running the command. This prevents the system from crashing under 100 commands per second.
    
- `command`: Supports a `{value}` placeholder.
    

```
- type: slider
  properties:
    title: Brightness
    icon: display-brightness-symbolic
    min: 0
    max: 100
    step: 5
    debounce: true
  on_change:
    type: exec
    command: brightnessctl set {value}%
```

### 3.4 Selection Dropdown (`selection`)

**Analogy:** The Menu Choice.

"Would you like Fries, Salad, or Soup?" You pick one option from a list.

- **Event Type:** `on_change`
    
- `options`: A simple list of text strings.
    
- `command`: Replaces `{value}` with the text you selected.
    

```
- type: selection
  properties:
    title: Power Profile
    icon: battery-level-80-symbolic
    options:
      - Performance
      - Balanced
      - Power Saver
  on_change:
    type: exec
    command: powerprofilesctl set {value}
```

### 3.5 Text Entry (`entry`)

**Analogy:** The Comment Card.

You write something specific (like a hostname or a custom message) and hand it over.

- **Event Type:** `on_action`
    
- `command`: Replaces `{value}` with the text you typed.
    

```
- type: entry
  properties:
    title: Set Hostname
    icon: network-server-symbolic
    button_text: "Apply"
  on_action:
    type: exec
    command: hostnamectl set-hostname {value}
    terminal: true
```

### 3.6 Grid Cards (`grid_card` / `toggle_card`)

**Analogy:** The Dashboard Tiles.

These are large, square buttons used in the `grid_section` layout. Ideal for the "Home" page or "Quick Actions".

- `grid_card`: Acts exactly like a **Button**.
    
- `toggle_card`: Acts exactly like a **Toggle** (changes color when active).
    

```
- type: toggle_card
  properties:
    title: Dark Mode
    icon: weather-clear-night-symbolic
    key: dawn_theme/state # Saves state to file
  on_toggle:
    enabled:
      type: exec
      command: theme_ctl.sh set dark
    disabled:
      type: exec
      command: theme_ctl.sh set light
```

### 3.7 Dynamic Label (`label`)

**Analogy:** The Scoreboard.

You don't interact with it; you just read it. It updates itself automatically.

- `value` -> `type`:
    
    - `exec`: Runs a command (e.g., `free -h`) and shows the output.
        
    - `file`: Reads a text file.
        
    - `system`: Reads extremely fast cached values (`kernel_version`, `cpu_model`, `memory_total`).
        

```
- type: label
  properties:
    title: Kernel
    interval: 60 # Updates every minute
  value:
    type: system
    key: kernel_version
```

### 3.8 Navigation Row (`navigation`)

**Analogy:** The Secret Door. Unlike a standard button that launches a command, this row slides the entire view to a new sub-page. Use this to create nested menus without cluttering the main sidebar.

- `layout`: A list of sections, identical to the main page layout structure.
    

```
- type: navigation
  properties:
    title: Advanced Settings
    icon: preferences-other-symbolic
  layout:
    - type: section
      properties: { title: "Deeper Settings" }
      items: [ ... ]
```

### 3.9 Expander Row (`expander`)

**Analogy:** The Folding Map.

It looks like a single line, but click it, and it unfolds to reveal more settings in place. Use this to hide advanced settings so they don't clutter the page.

```
- type: expander
  properties:
    title: Advanced Network Settings
    icon: preferences-system-network-symbolic
  items:
    - type: button
      properties: { title: "DNS Settings", ... }
    - type: toggle
      properties: { title: "IPv6", ... }
```

### 3.10 Warning Banner (`warning_banner`)

**Analogy:** The "Wet Floor" Sign.

A visual alert to warn users about sensitive settings.

```
- type: warning_banner
  properties:
    title: "Read Only"
    message: "These are system defaults. Do not edit directly."
```

## 4. Advanced Features

### 4.1 Hot Reload (`Ctrl+R`)

**Analogy:** Changing the Menu while the restaurant is open.

You do **not** need to close and reopen the application to see your changes.

1. Edit `dawn_config.yaml`.
    
2. Focus the Dusky window.
    
3. Press `Ctrl + R`.
    

> $$\!WARNING$$
> 
> State Preservation
> 
> Dusky attempts to remember exactly which page you were on. However, if you delete that page in the config, it will default back to the first page.

### 4.2 Deep Search (`Ctrl+F`)

**Analogy:** The Index.

Dusky includes a recursive indexing engine that finds needles in haystacks.

- It indexes **Page Titles**, **Section Titles**, **Item Titles**, and even **Descriptions**.
    
- It creates "Breadcrumbs" (e.g., _Home > Network > VPN_) so you know exactly where a setting lives.
    
- **Grid Cards** and **Toggles** found in search results are automatically converted into standard List Rows so they look good in the search results list.
    

### 4.3 Sidebar Toggle

The interface uses `Adw.OverlaySplitView`.

- On wide monitors, the sidebar is pinned (always visible).
    
- On small windows, the sidebar collapses (hides).
    
- Clicking the "Dusky" icon in the top left or the sidebar toggle button will slide the menu in/out.
    

## 5. Troubleshooting & Debugging

### "The toggle switches back instantly"

- **Cause:** The `state_command` is reporting the _old_ state.
    
- **Explanation:** You clicked the toggle, the command ran, but the system (e.g., NetworkManager) took 1 second to actually change status. The Dusky Monitor checked instantly, saw the old status, and flipped the switch back to match reality.
    
- **Fix:** Ensure your toggle scripts wait for the process to finish, or accept that the switch will correct itself on the next `interval` tick (usually 5 seconds).
    

### "My command works in terminal but not in Dusky"

- **Cause:** Path issues.
    
- **Fix:** Always use absolute paths (e.g., `/usr/bin/htop` instead of `htop`). While Dusky handles `$HOME` expansion, it does not automatically load your `.bashrc` aliases.
    

### "The app won't open"

- **Check:** Run `dawn_control_center.py` from a terminal to see the error output.
    
- **Recover:** If the config is broken, Dusky will launch into a special "Error State" page showing you the Python stack trace, allowing you to fix the YAML and Hot Reload (`Ctrl+R`) without crashing.

### 1. `dawn_control_center.py` (The Manager)

**Role:** Main Application Logic & Window Management. This is the file you actually run. It creates the window, manages the sidebar navigation, handles the Search bar logic (`Ctrl+F`), and listens for the Hot Reload command (`Ctrl+R`). It doesn't know how to build a specific slider or button; it just coordinates everything.

- **Key Job:** Keeps the app running in the background (Daemon mode) so it opens instantly.
    

### 2. `rows.py` (The Kitchen)

**Role:** Widget Factory & Logic. This file contains the "recipes" for every interactive element. When the config asks for a "slider," this file builds the `SliderRow`, attaches the threading logic (so dragging it doesn't freeze the app), and handles the debouncing.

- **Key Job:** Converts abstract YAML text into actual clicking, sliding GTK widgets.
    

### 3. `utility.py` (The Supply Chain)

**Role:** Helper Functions & Safety. This file does the dirty work that multiple parts of the app need. It handles:

- **Safe Command Execution:** Wrapping commands in `uwsm-app` so they work on Hyprland.
    
- **Atomic Saves:** Saving your toggle states to disk without corrupting files if the power fails.
    
- **System Info:** Reading RAM/CPU usage efficiently.
    
- **Key Job:** ensuring thread safety and preventing crashes when interacting with the OS.
    

### 4. `dawn_config.yaml` (The Menu)

**Role:** User Configuration. This is the **only** file a normal user interacts with. It defines _what_ goes in the app. It lists the pages, the icons, the titles, and the commands to run.

- **Key Job:** Tells the app what to display. If you delete everything in this file, the app opens as a blank window (or shows the "Empty State" error page).
    

### 5. `dawn_style.css` (The Decor)

**Role:** Visual Styling. This standard CSS file overrides the default GTK look. It defines the rounded corners of the cards, the specific colors of the toggle switches, the "dim" look of labels, and the hover effects.

- **Key Job:** Makes the app look like "Dusky" rather than a generic Linux window.