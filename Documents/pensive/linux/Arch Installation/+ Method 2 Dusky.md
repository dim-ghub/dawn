## Method 2: The "Clean Slate" (only recommended if you have Intel or (Intel/Nvidia) hardware. (will make this amd compatible in the near future)

Best for: New installs, Dual Booting, ensuring zero bloat.

Requirement: Official Arch Linux ISO.

This method handles everything from disk partitioning with guided user intervention to automated installing of packages and everything else.

### Step 1: Connect to Internet

Boot the Arch ISO. USB tethering usually works out of the box. For WiFi, follow these steps:

<details>

<summary>Click to view WiFi Connection Commands</summary>

1. Run the interactive tool:
    
    ```
    iwctl
    ```
    
2. List your devices (note your device name, e.g., `wlan0`):
    
    ```
    device list
    ```
    
3. Scan for networks:
    
    ```
    station wlan0 scan
    ```
    
4. List available networks:
    
    ```
    station wlan0 get-networks
    ```
    
5. Connect:
    
    ```
    station wlan0 connect "YOUR_SSID"
    ```
    
6. Exit the tool:
    
    ```
    exit
    ```
    

</details>

### Step 2: Download the Script

Run the following commands to initialize keys, install git, and clone the installer:

```bash
pacman-key --init
pacman -Sy git
```

##### Clone the repo (type carefully or it asks a password if you enter the wrong repo)
```bash
git clone --depth 1 https://github.com/dim-ghub/dawn.git
```

##### Copy the pre-chroot scripts to the current directory
```bash
cp dawn/user_scripts/arch_iso_scripts/000_pre_chroot/* .
```

### Step 3: Run the ISO Orchestra

This script automates the pre-chroot setup (disk partitioning)
```bash
./001_ISO_ORCHESTRA.sh
```

### Step 4: Run the Chroot Orchestra

Once the previous script finishes, enter your new system and run the final stage:
```bash
arch-chroot /mnt
```

```bash
./001_CHROOT_ORCHESTRA.sh
```

### Step 5: Post-Reboot Setup

1. Reboot your computer.
    
2. Login with your username and password.
    
3. Open the terminal (Default: `Super` + `Q`).
    
4. Run the final deployment scripts:
    

```
# Connect to wifi if needed
./wifi_connect.sh
```

```
# Deploy config files
./deploy_dotfiles.sh
```

> Note:
> 
> This will immediately list a few errors at the top, but dont worry, that's expected behaviour, the errors will later go away on there own after matugen generates colors and cycles through a wallpaper. 

the main setup script.
```bash
~/user_scripts/arch_setup_scripts/Conductor.sh
```
