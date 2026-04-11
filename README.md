<div align="center">

# 🌅 Dawn

**A meticulously crafted Hyprland dotfiles framework for Artix Linux (OpenRC)**

[![Stars](https://img.shields.io/github/stars/dim-ghub/dawn?style=for-the-badge&logo=starship&color=a167e0&labelColor=1a1a2e)](https://github.com/dim-ghub/dawn/stargazers)
[![License: MIT](https://img.shields.io/github/license/dim-ghub/dawn?style=for-the-badge&color=a167e0&labelColor=1a1a2e)](https://github.com/dim-ghub/dawn/blob/main/LICENSE)
[![Discord](https://img.shields.io/discord/1372743714785177600?style=for-the-badge&logo=discord&color=5865F2&labelColor=1a1a2e&label=DISCORD)](https://discord.gg/a85YB9wuau)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome!-style=for-the-badge&color=a167e0&labelColor=1a1a2e)](https://github.com/dim-ghub/dawn/pulls)

</div>

---

> **If you need help with installation or troubleshooting, join the [Discord server](https://discord.gg/a85YB9wuau).**
>
> 🚀 **Haven't installed Artix yet?** Use the [Artix Installer](https://github.com/dim-ghub/artix-installer) to get a full Hyprland setup running in minutes.

### 🖼️ Wallpapers

If you're here just for the wallpapers, grab all 1050+ from the [images repo](https://github.com/dusklinux/images).

### 📊 Waybar — Your Pick

Horizontal or vertical, choose during setup — easily toggleable from rofi too.

| Block | Circular | Nerdy |
|:---:|:---:|:---:|
| ![Block](Pictures/readme_assets/waybar_block.webp) | ![Circular](Pictures/readme_assets/waybar_circular.webp) | ![Horizontal](Pictures/readme_assets/waybar_horizontal.webp) |

| Minimal |  |
|:---:|:---:|
| ![Minimal](Pictures/readme_assets/waybar_minimal.webp) | |

### 🎛️ Dawn Control Center

A brand new system-overview GUI for settings and features. Almost anything you want to set or change can be done from this one-stop-shop app, and more quality-of-life features are added regularly.

![Dawn Control Center](Pictures/readme_assets/dawn_control_center.webp)

---

This repository is the result of 8 months of tinkering, breaking, fixing, and polishing. It's a labor of love designed to feel as easy to install as a "standard" distribution — but with the raw power and minimalism of Arch Linux on OpenRC.

**Please consider starring ⭐ this repo as a token of support!**

---

## ⚠️ Prerequisites & Hardware

### Filesystem

This setup is strictly optimized for **BTRFS** filesystem format. (Should also work on ext4, but not recommended.)

- **Why BTRFS?** ZSTD compression, copy-on-write (CoW) to prevent data corruption, and instant snapshots.

### Hardware Config (Intel / Nvidia / AMD)

The setup scripts auto-detect your hardware and set the appropriate environment variables. If your hardware isn't detected or has issues, configure manually:

> [!Note]
>
> Configure your GPU environment variables.
>
> 1. Open `~/.config/hypr/edit_here/source/environment_variables.conf`
> 2. Add Intel/Nvidia/AMD-specific variables for your hardware.

### Dual Booting

- Compatible with Windows or other Linux distros.
- **Bootloader:** Uses `Limine` — a modern, lightweight UEFI bootloader.

### Init System

- **OpenRC only** — Dawn fully supports Artix Linux with the OpenRC init system.
- **Systemd is no longer supported.** All user services are managed directly via autostart or OpenRC init scripts.

---

## 💿 Installation

[![](https://img.shields.io/badge/Artix%20Installer-a167e0?style=for-the-badge&logo=github&logoColor=white&labelColor=1a1a2e)](https://github.com/dim-ghub/artix-installer)

**Best for:** Users who already have a fresh, unconfigured Artix Linux installation with Hyprland, set up either via the [Artix Installer](https://github.com/dim-ghub/artix-installer) or manually. If you haven't installed yet, use the installer script to get up and running with **Btrfs** and **Hyprland** configured automatically.

After installing, boot into the OS and run the following in a terminal:

### Step 1: Clone Dotfiles (Bare Repo Method)

Uses a bare git repository method to drop files exactly where they belong in your home directory.

Make sure you're connected to the internet and git is installed:

```bash
sudo pacman -Syu --needed git
```

Clone the repo:

```bash
git clone --bare --depth 1 https://github.com/dim-ghub/dawn.git $HOME/dawn
```

Deploy the files on your system:

```bash
git --git-dir=$HOME/dawn/ --work-tree=$HOME checkout -f
```

> [!Note]
> This will list a few errors at the top — that's expected! They'll resolve on their own once `matugen` generates colors and cycles through a wallpaper.

### Step 2: Run the Orchestra

Run the master script to install dependencies, themes, and services. This will take a while since it sets up everything. You'll be prompted with yes/no questions during setup, so don't leave it running unattended.

```bash
~/user_scripts/arch_setup_scripts/ORCHESTRA.sh
```

## 🎼 The Orchestra Script

The `ORCHESTRA.sh` is a conductor that manages ~80 subscripts.

- **Smart:** Detects installed packages and skips them.
- **Safe:** Re-run as many times as you like without breaking things.
- **Time:** Expect 30–60 minutes. A few AUR packages compile from source — grab a coffee!

---

## ⌨️ Usage & Keybinds

The steepest learning curve will be the keybinds. They're designed to be intuitive, but feel free to customize them.

> 💡 **Pro Tip:** Press `Ctrl` + `Shift` + `Space` to open the Keybinds Cheatsheet. You can click commands in this menu to run them directly!

Tested to work on other Arch-based distros with Hyprland installed (fresh install).

---

## 🔧 Troubleshooting

If a script fails (which can happen on a rolling release distro):

1. **Don't Panic.** The scripts are modular — the rest of the system usually installs fine.
2. **Check the Output.** Identify which subscript failed (located in `$HOME/user_scripts/setup_scripts/scripts/`).
3. **Run Manually.** Try running that specific subscript individually.
4. **AI Help.** Copy the script content and error message into ChatGPT/Gemini. It can usually pinpoint the exact issue.

---

## 📋 Overview

> Note: Dawn purposely avoids Quickshell to keep things as lightweight as possible. Everything uses user-friendly TUIs to stay snappy and low on resources while delivering a whole host of features.

### 🛠️ Utilities

| Feature | Description |
|---------|-------------|
| **Music Recognition** | Look up what music is playing |
| **Circle-to-Search** | Google Lens integration |
| **Appearance TUI** | Chain hyprland's appearance — gaps, shadow color, blur, opacity, and more |
| **AI LLM Sidebar** | Local inference with Ollama (terminal-based, incredibly resource efficient) |
| **Keybind TUI Setter** | Auto-checks for conflicts and unbinds existing keybinds |
| **Swaync Side Toggle** | Easily switch notification center to left or right |
| **Airmon WiFi Script** | WiFi testing / password cracking *(only use on access points you own)* |
| **Live Disk I/O Monitor** | See live read/write disk speed — useful for flash drives & external drives |
| **Quick Audio Switch** | Keybind to switch audio input/output (e.g. Bluetooth ↔ speakers) |
| **Mono/Stereo Toggle** | Toggle mono and stereo audio |
| **Touchpad Gestures** | Volume/brightness, lock screen, swaync, pause/play, mute |
| **Battery Notifier** | Customizable notifications at certain battery levels |
| **Power Saver Mode** | Togglable power saver for laptops |
| **System Cleanup** | Cache purge to reclaim storage |
| **USB Notifications** | Sound alerts for USB plug/unplug events |
| **FTP Server** | Automatic FTP server setup |
| **Tailscale** | Automatic Tailscale VPN setup |
| **OpenSSH** | Automatic SSH setup (with or without Tailscale) |
| **Cloudflare Warp** | Auto setup and toggle from rofi |
| **VNC for iPhone** | Wired VNC setup for iPhones |
| **Dynamic Fractional Scaling** | Scale your display with a keybind |
| **Window Effects Toggle** | Toggle transparency, blur, and shadows with a single keybind |
| **Hypridle TUI** | Configure hypridle settings |
| **Network Manager** | Connect to WiFi via `connman-gtk` (replaces NetworkManager) |
| **Sysbench Benchmarking** | System benchmarking script |
| **Color Picker** | Pick colors from anywhere on screen |
| **Neovim** | Pre-configured neovim (or install lazyvim/your own rice) |
| **GitHub Repo Integration** | Easily create a repo to backup files via bare git (tracked via `~/.git_dawn_list`) |
| **BTRFS Compression Stats** | See how much space ZSTD compression is saving you |
| **Drive Manager** | Lock/unlock encrypted drives, auto-mount at specified paths, NTFS fix |
| **Discord Webhook Notifications** | Script failure notifications via Discord webhook |

### 📱 Rofi Menus

- Emoji Picker
- Calculator
- Matugen Theme Switcher
- Animation Switcher
- Power Menu
- Clipboard Manager
- Wallpaper Selector
- Shader Menu
- System Menu

### 🎚️ GUI Sliders (Keybind-Invoked)

- Volume Control
- Brightness Control
- Nightlight / Hyprsunset Intensity

### 🗣️ Speech & Audio

| Feature | Engine |
|---------|--------|
| **Speech-to-Text** | Whisper (CPU) or Parakeet (Nvidia GPU) |
| **Text-to-Speech** | Kokoro (CPU & GPU) |
| **Mechanical Keypress Sounds** | Togglable via keybind or rofi |

### 🎨 Wlogout

Dynamically rendered to respect your fractional scaling settings.

---

## ⚡ Performance & System

- **Lightweight:** ~900MB RAM usage and ~5GB disk usage (fully configured)
- **ZSTD & ZRAM:** Compression enabled by default — save storage and triple your effective RAM (great for low-spec machines)
- **Native Optimization:** AUR helpers configured to build with CPU-native flags (up to 20% performance boost)
- **OpenRC Support:** Fully compatible with Artix Linux and the OpenRC init system

---

## 🎮 Graphics & Gaming

- **Fluid Animations:** Tuned physics and momentum for a liquid feel
- **GPU Passthrough Guide:** Zero latency (native performance) for dual-GPU setups using Looking Glass
- **Instant Shaders:** Switch visual shaders via Rofi
- **Android Support:** Automated Waydroid installer script

---

## 🎨 Usability & Theming

- **Universal Theming:** `Matugen` powers unified Light/Dark mode across the system
- **Dual Workflow:** Designed for both GUI-centric (mouse) and Terminal-centric (keyboard) users
- **Accessibility:** Text-to-Speech (TTS) and Speech-to-Text (STT) capabilities
- **Keybind Cheatsheet:** Press `Ctrl` + `Shift` + `Space` anytime to see controls

---

## 🔄 Key Changes from Previous Releases

| Change | Details |
|--------|---------|
| **Dusky → Dawn** | Complete project rename |
| **systemd → OpenRC** | systemd support has been dropped; Artix Linux / OpenRC is the primary target |
| **UWSM Removed** | No longer depends on UWSM; apps launch directly in Hyprland |
| **swww → awww** | Wallpaper engine switched from swww to awww |
| **NetworkManager → connman** | Network management now uses connman + connman-gtk |
| **wifitui removed** | Replaced with connman-gtk for WiFi management |
| **CachyOS dropped** | CachyOS support removed; Artix Linux support added |
| **Discord Webhooks** | Script failures can now notify you via Discord webhook |

---

<div align="center">

**Enjoy the experience!**

If you run into issues, check the detailed Obsidian notes included in the repo (~2MB).

</div>

---

## 🙏 Acknowledgments

Thank you to all the Contributors!

SDDM theme is a modified version of the **SilentSDDM** project by [@uiriansan](https://github.com/uiriansan) — a great project, kindly star it on GitHub!

[![](https://img.shields.io/badge/SilentSDDM-⭐%20on%20GitHub-a167e0?style=for-the-badge&logo=github&labelColor=1a1a2e)](https://github.com/uiriansan/SilentSDDM/)
