## Table of Contents

- [[#Target Disk Layout]]
- [[#Subvolume Purpose & Snapshot Behaviour]]
- [[#Required Packages]]
- [[#Optional — Verify Boot Mode]]
- [[#1. WiFi Connection]]
- [[#2. SSH]]
- [[#3. Setting a Bigger Font]]
- [[#4. Optional — Limiting Battery Charge to 60%]]
- [[#5. Pacman Keyring, Cache Cleanup & Sync]]
- [[#6. System Timezone]]
- [[#7. Partitioning the Target Drive]]
- [[#8. LUKS2 Encryption Setup]]
- [[#9. Formatting ESP & Encrypted Root]]
- [[#10. BTRFS Subvolume Creation]]
- [[#11. Mounting All Subvolumes & ESP]]
- [[#12. Syncing Mirrors for Faster Download Speeds]]
- [[#13. Installing the Base System]]
- [[#14. Fstab Generation & Verification]]
- [[#15. Chrooting]]
- [[#16. Setting System Time]]
- [[#17. Setting System Language]]
- [[#18. Setting Hostname]]
- [[#19. Setting Root Password]]
- [[#20. Creating User Account]]
- [[#21. Allowing Wheel Group Root Rights]]
- [[#22. Configuring mkinitcpio for Encrypted BTRFS Boot]]
- [[#23. Installing Packages]]
- [[#24. Generating Initramfs]]
- [[#25. Limine Bootloader Installation & Configuration]]
- [[#26. Fallback Disk-Based Swap File]]
- [[#27. ZRAM Configuration & Swappiness Tuning]]
- [[#28. LUKS Header Backup]]
- [[#29. System Services]]
- [[#30. Concluding & First Reboot]]
- [[#31. First Boot Verification]]
- [[#32. Ongoing Maintenance]]
- [[#33. Quick-Reference Cheat Sheet]]
- [[#Final System Architecture]]
- [[#Troubleshooting]]

---

> [!tip] **SSH vs. Manual Typing**
> Only use the "Recommended" one-liners if you are **copy-pasting** via SSH.
>
> If you are typing by hand, use the manual method instead. The automated commands are too complex and prone to typos when typed manually.

> [!warning] **Placeholder Conventions — Replace These**
> Throughout this guide:
> - `sdX` → your target drive (e.g., `nvme0n1`, `sda`)
> - `sdX1` or `esp_partition` → your ESP partition (e.g., `nvme0n1p1`, `sda1`)
> - `sdX2` or `root_partition` → your LUKS partition (e.g., `nvme0n1p2`, `sda2`)
> - `wlan0` → your wireless interface name
> - `192.168.xx` → your machine's IP address
> - `your-hostname` → your desired hostname
> - `your_username` → your desired username

---

## Target Disk Layout

```
┌──────────────────────────────────────────────────────────┐
│  /dev/sdX                                                │
├──────────────────────────────────────────────────────────┤
│  Partition 1 — ESP (FAT32, ~2-5 GiB)                     │
│    └── mounted at /boot                                  │
│        Contains: Limine EFI, vmlinuz, initramfs          │
├──────────────────────────────────────────────────────────┤
│  Partition 2 — LUKS2 Encrypted (rest of disk)            │
│    └── /dev/mapper/cryptroot — BTRFS                     │
│        ├── @                  → /                        │
│        ├── @home              → /home                    │
│        ├── @snapshots         → /.snapshots              │
│        ├── @home_snapshots    → /home/.snapshots         │
│        ├── @var_log           → /var/log                 │
│        ├── @var_cache         → /var/cache               │
│        ├── @var_tmp           → /var/tmp                 │
│        ├── @var_lib_libvirt   → /var/lib/libvirt         │
│        └── @swap              → /swap                    │
└──────────────────────────────────────────────────────────┘
```

---

## Subvolume Purpose & Snapshot Behaviour

| Subvolume | Mount Point | Snapshotted? | Why Separate? |
|---|---|:---:|---|
| `@` | `/` | ✅ Yes | Root filesystem — the main thing you snapshot & roll back |
| `@home` | `/home` | ✅ Yes | User data — independent snapshot schedule from root |
| `@snapshots` | `/.snapshots` | ❌ Excluded | Snapper metadata for `@` — must survive rollbacks |
| `@home_snapshots` | `/home/.snapshots` | ❌ Excluded | Snapper metadata for `@home` — must survive rollbacks |
| `@var_log` | `/var/log` | ❌ Excluded | Logs grow constantly, useless in snapshots |
| `@var_cache` | `/var/cache` | ❌ Excluded | Pacman cache etc. — large, reproducible |
| `@var_tmp` | `/var/tmp` | ❌ Excluded | Persistent temp files — no value in snapshots |
| `@var_lib_libvirt` | `/var/lib/libvirt` | ❌ Excluded | VM disk images (qcow2) — **huge**, would bloat snapshots |
| `@swap` | `/swap` | ❌ Excluded | Fallback disk swap file — must be NOCOW |

---

## Required Packages

> [!important] Cross-check your [[Package Installation]] list. Add any of these that are missing.

| Package       | Repo    | Installed When     | Purpose                                                |
| ------------- | ------- | ------------------ | ------------------------------------------------------ |
| `cryptsetup`  | `core`  | pacstrap (Step 13) | LUKS2 encryption — **not** in `base`, must be explicit |
| `btrfs-progs` | `core`  | pacstrap (Step 13) | BTRFS tools                                            |
| `dosfstools`  | `core`  | pacstrap (Step 13) | FAT32 ESP tools                                        |
| `limine`      | `extra` | pacman (Step 25)   | Bootloader                                             |
| `efibootmgr`  | `core`  | pacman (Step 25)   | UEFI boot entry management                             |


---

## Optional — Verify Boot Mode

```bash
cat /sys/firmware/efi/fw_platform_size
```

> [!NOTE]- What the Output Means
> - `64` → UEFI mode, 64-bit x64 UEFI ✅ (this guide assumes this)
> - `32` → UEFI mode, 32-bit IA32 UEFI (limits bootloader choices)
> - `No such file or directory` → BIOS/CSM mode (LUKS + Limine UEFI will not work)

---

### 1. WiFi Connection

```bash
iwctl
```

```bash
device list
```

```bash
station wlan0 scan
```

```bash
station wlan0 get-networks
```

```bash
station wlan0 connect "Near"
```

```bash
exit
```

```bash
ping -c 2 x.com
```

- [ ] Status

---

### 2. SSH

```bash
passwd
```

```bash
ip a
```

*Client side (to connect to target machine)*

```bash
ssh root@192.168.xx
```

*Only if you need to reset the key (troubleshooting)*

```bash
ssh-keygen -R 192.168.xx
```

- [ ] Status

---

### 3. Setting a Bigger Font

```bash
setfont latarcyrheb-sun32
```

- [ ] Status

---

### 4. Optional — Limiting Battery Charge to 60%

> [!note] Check your battery name first: `ls /sys/class/power_supply/` — it might be `BAT0`, `BAT1`, `BATT`, etc.

```bash
echo 60 | tee /sys/class/power_supply/BAT1/charge_control_end_threshold
```

- [ ] Status

---

### 5. Pacman Keyring, Cache Cleanup & Sync

**Recommended** (one-liner via SSH)

```bash
mount -o remount,size=4G /run/archiso/cowspace && pacman-key --init && pacman-key --populate archlinux && yes | pacman -Scc && pacman -Syy && pacman -S --noconfirm archlinux-keyring
```

**OR** step by step

```bash
mount -o remount,size=4G /run/archiso/cowspace
```

```bash
pacman-key --init
```

```bash
pacman-key --populate archlinux
```

After entering this next command, type "y" for all prompts.

```bash
pacman -Scc
```

```bash
pacman -Syy
```

```bash
pacman -S --noconfirm archlinux-keyring
```

> [!note]- Why this order?
> 1. **Remount cowspace first** — gives the ISO ramdisk room for downloads
> 2. **Init + populate keys** — establishes trust for package signatures
> 3. **`-Scc`** — purges stale cached packages and old sync databases
> 4. **`-Syy`** — forces a full fresh database sync
> 5. **`-S archlinux-keyring`** — installs latest keyring against the fresh database

- [ ] Status

---

### 6. System Timezone

**Recommended** (one command)

```bash
timedatectl set-timezone Asia/Kolkata && timedatectl set-ntp true
```

**OR** step by step

```bash
timedatectl set-timezone Asia/Kolkata
```

```bash
timedatectl set-ntp true
```

- [ ] Status

---

### 7. Partitioning the Target Drive

*Identify the target drive*

```bash
lsblk
```

*Partition the target drive*

```bash
cfdisk /dev/sdX
```

> [!important] **Partition Table & Layout**
> If the disk is empty or you are starting fresh, select **`gpt`** when cfdisk asks.
>
> Create exactly **two** partitions:
>
> | # | Size | Type (cfdisk) | Purpose |
> |---|---|---|---|
> | 1 | `2-5 GB` | **EFI System** | ESP — unencrypted boot partition (UEFI) |
> | 2 | *remainder* | **Linux filesystem** | LUKS2 encrypted root |
>
> Write and quit.

*Verify the partitions*

```bash
lsblk /dev/sdX
```

- [ ] Status

---

### 8. LUKS2 Encryption Setup

> [!warning] **This will destroy all data on the root partition.** Double-check you are targeting the correct partition (the large one, **not** the ~2GB ESP).

*Format the root partition with LUKS2*

```bash
cryptsetup luksFormat /dev/root_partition
```

> [!note]- What this does & defaults
> - Creates a LUKS2 container (LUKS2 is the default since cryptsetup 2.4+)
> - Cipher: `aes-xts-plain64` (256-bit AES, 512-bit key)
> - Key derivation: `argon2id` (memory-hard, resistant to GPU/ASIC attacks)
> - You will be asked to type `YES` (uppercase) and then enter your encryption passphrase **twice**
> - **Choose a strong passphrase.** This is the only thing protecting your data.

*Open the LUKS container*

```bash
cryptsetup open --allow-discards /dev/root_partition cryptroot
```

> [!note]- Why `--allow-discards`?
> Allows TRIM/discard commands to pass through the LUKS layer to the SSD. Without it, `discard=async` in your BTRFS mount options would have no effect.
>
> > [!warning] **Security trade-off**
> > Enabling TRIM on LUKS reveals which disk blocks are unused, which could theoretically leak filesystem usage patterns. For the vast majority of users, the SSD performance and longevity benefits far outweigh this theoretical concern. If you need maximum OpSec, omit `--allow-discards` here and remove `discard=async` from mount options and `rd.luks.options=discard` from the kernel cmdline.

*Verify the mapped device exists*

```bash
ls /dev/mapper/cryptroot
```

- [ ] Status

---

### 9. Formatting ESP & Encrypted Root

*Format the ESP partition*

```bash
mkfs.fat -F 32 -n "EFI" /dev/esp_partition
```

*Format the opened LUKS container as BTRFS*

```bash
mkfs.btrfs -f -L "ROOT" /dev/mapper/cryptroot
```

> [!important] You are formatting `/dev/mapper/cryptroot` (the **decrypted mapped device**), **not** `/dev/root_partition` (the raw encrypted partition).

- [ ] Status

---

### 10. BTRFS Subvolume Creation

*Mount the top-level BTRFS volume*

```bash
mount /dev/mapper/cryptroot /mnt
```

*Create all subvolumes*

**Recommended** (one-liner via SSH)

```bash
btrfs subvolume create /mnt/{@,@home,@snapshots,@home_snapshots,@var_log,@var_cache,@var_tmp,@var_lib_libvirt,@swap}
```

**OR** one by one

```bash
btrfs subvolume create /mnt/@
```

```bash
btrfs subvolume create /mnt/@home
```

```bash
btrfs subvolume create /mnt/@snapshots
```

```bash
btrfs subvolume create /mnt/@home_snapshots
```

```bash
btrfs subvolume create /mnt/@var_log
```

```bash
btrfs subvolume create /mnt/@var_cache
```

```bash
btrfs subvolume create /mnt/@var_tmp
```

```bash
btrfs subvolume create /mnt/@var_lib_libvirt
```

```bash
btrfs subvolume create /mnt/@swap
```

*Verify all 9 subvolumes were created*

```bash
btrfs subvolume list /mnt
```

> [!note]- Expected output (9 subvolumes, all `top level 5`)
> ```
> ID 256 gen ... top level 5 path @
> ID 257 gen ... top level 5 path @home
> ID 258 gen ... top level 5 path @snapshots
> ID 259 gen ... top level 5 path @home_snapshots
> ID 260 gen ... top level 5 path @var_log
> ID 261 gen ... top level 5 path @var_cache
> ID 262 gen ... top level 5 path @var_tmp
> ID 263 gen ... top level 5 path @var_lib_libvirt
> ID 264 gen ... top level 5 path @swap
> ```
> All must show `top level 5` — top-level subvolumes, not nested. This is critical for snapshot isolation later on

> [!tip]- **Why `top level 5` matters (this is just for info) **
> When Snapper snapshots `@` (root), it only captures data **inside** the `@` subvolume. Because `@var_log`, `@var_lib_libvirt`, etc. are sibling subvolumes at the top level, they are automatically excluded from root snapshots.
>
> If you roll back `@` to an earlier snapshot, your logs, VM images, home data, and snapshot metadata are completely unaffected.

*Unmount the top-level volume*

```bash
umount /mnt
```

- [ ] Status

---

### 11. Mounting All Subvolumes & ESP

> [!important] **Mount order matters.** Root subvolume (`@`) first → create directories → mount children → mount ESP last.

#### 11a. Mount the Root Subvolume

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@ /dev/mapper/cryptroot /mnt
```

#### 11b. Create All Mount Point Directories

**Recommended** (one-liner via SSH)

```bash
mkdir -p /mnt/{home,boot,.snapshots,home/.snapshots,var/{log,cache,tmp,lib/libvirt},swap}
```

**OR** manually

```bash
mkdir -p /mnt/home
```

```bash
mkdir -p /mnt/boot
```

```bash
mkdir -p /mnt/.snapshots
```

```bash
mkdir -p /mnt/home/.snapshots
```

```bash
mkdir -p /mnt/var/log
```

```bash
mkdir -p /mnt/var/cache
```

```bash
mkdir -p /mnt/var/tmp
```

```bash
mkdir -p /mnt/var/lib/libvirt
```

```bash
mkdir -p /mnt/swap
```

#### 11c. Mount All BTRFS Subvolumes

**Recommended** (SSH — variable + sequential mounts)

```bash
B="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"
D="/dev/mapper/cryptroot"
mount -o $B,subvol=@home              $D /mnt/home
mount -o $B,subvol=@snapshots         $D /mnt/.snapshots
mount -o $B,subvol=@home_snapshots    $D /mnt/home/.snapshots
mount -o $B,subvol=@var_log           $D /mnt/var/log
mount -o $B,subvol=@var_cache         $D /mnt/var/cache
mount -o $B,subvol=@var_tmp           $D /mnt/var/tmp
mount -o $B,subvol=@var_lib_libvirt   $D /mnt/var/lib/libvirt
mount -o rw,noatime,ssd,discard=async,space_cache=v2,subvol=@swap $D /mnt/swap
```

**OR** mount each one manually

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@home /dev/mapper/cryptroot /mnt/home
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@home_snapshots /dev/mapper/cryptroot /mnt/home/.snapshots
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@var_log /dev/mapper/cryptroot /mnt/var/log
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@var_cache /dev/mapper/cryptroot /mnt/var/cache
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@var_tmp /dev/mapper/cryptroot /mnt/var/tmp
```

```bash
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=@var_lib_libvirt /dev/mapper/cryptroot /mnt/var/lib/libvirt
```

```bash
mount -o rw,noatime,ssd,discard=async,space_cache=v2,subvol=@swap /dev/mapper/cryptroot /mnt/swap
```

> [!warning] **`@swap` has different mount options** — mounted **without** `compress=zstd:3`. Swap files must not be compressed at the filesystem level.

#### 11d. Mount the ESP

```bash
mount /dev/esp_partition /mnt/boot
```

#### 11e. Verify All Mounts

```bash
findmnt -R -t btrfs,vfat /mnt
```

> [!note]- Expected output (10 mount points)
> ```
> TARGET                 SOURCE                                     FSTYPE OPTIONS
> /mnt                   /dev/mapper/cryptroot[/@]                   btrfs  rw,noatime,compress=zstd:3,...
> ├─/mnt/home            /dev/mapper/cryptroot[/@home]               btrfs  rw,noatime,compress=zstd:3,...
> ├─/mnt/.snapshots      /dev/mapper/cryptroot[/@snapshots]          btrfs  ...
> ├─/mnt/home/.snapshots /dev/mapper/cryptroot[/@home_snapshots]     btrfs  ...
> ├─/mnt/var/log         /dev/mapper/cryptroot[/@var_log]            btrfs  ...
> ├─/mnt/var/cache       /dev/mapper/cryptroot[/@var_cache]          btrfs  ...
> ├─/mnt/var/tmp         /dev/mapper/cryptroot[/@var_tmp]            btrfs  ...
> ├─/mnt/var/lib/libvirt /dev/mapper/cryptroot[/@var_lib_libvirt]    btrfs  ...
> ├─/mnt/swap            /dev/mapper/cryptroot[/@swap]               btrfs  rw,noatime,...
> └─/mnt/boot            /dev/sdX1                                   vfat   rw,...
> ```
>
> **Check these things:**
> 1. All 9 BTRFS subvolumes are mounted at the correct paths
> 2. Each shows its correct `[/@subvolname]` in the SOURCE column
> 3. `@swap` does **not** show `compress=zstd:3`
> 4. `/mnt/boot` shows as `vfat`

- [ ] Status

---

### 12. Syncing Mirrors for Faster Download Speeds

```bash
reflector --protocol https --country India --latest 6 --sort rate --save /etc/pacman.d/mirrorlist
```

**Critical: resync package databases after new mirrors**

```bash
pacman -Syy
```

> [!warning] If `reflector` fails, manually edit the mirrorlist:
> ```bash
> vim /etc/pacman.d/mirrorlist
> ```
> Paste your mirrors from [[Indian Pacman Mirrors]] and then run `pacman -Syy`.

- [ ] Status

---

### 13. Installing the Base System

> [!warning] **Critical addition: `cryptsetup`** — not part of the `base` package. Without it, the `sd-encrypt` mkinitcpio hook cannot be built and your system will not decrypt at boot.

```bash
pacstrap -K /mnt base base-devel linux linux-headers linux-firmware intel-ucode neovim dosfstools btrfs-progs cryptsetup
```

> [!note]- About `linux-firmware`
> You can replace the monolithic `linux-firmware` with specific sub-packages (`linux-firmware-intel`, etc.) to save space. This is unrelated to LUKS/Limine.

- [ ] Status

---

### 14. Fstab Generation & Verification

```bash
genfstab -U /mnt >> /mnt/etc/fstab
```

```bash
cat /mnt/etc/fstab
```

> [!important] **Verify the generated fstab — you should see 10 entries**
>
> | # | Mount Point | Filesystem | Subvolume |
> |---|---|---|---|
> | 1 | `/` | btrfs | `subvol=/@` |
> | 2 | `/home` | btrfs | `subvol=/@home` |
> | 3 | `/.snapshots` | btrfs | `subvol=/@snapshots` |
> | 4 | `/home/.snapshots` | btrfs | `subvol=/@home_snapshots` |
> | 5 | `/var/log` | btrfs | `subvol=/@var_log` |
> | 6 | `/var/cache` | btrfs | `subvol=/@var_cache` |
> | 7 | `/var/tmp` | btrfs | `subvol=/@var_tmp` |
> | 8 | `/var/lib/libvirt` | btrfs | `subvol=/@var_lib_libvirt` |
> | 9 | `/swap` | btrfs | `subvol=/@swap` |
> | 10 | `/boot` | vfat | *(ESP)* |
>
> **Check:**
> 1. All 9 BTRFS entries reference the **same UUID** (the BTRFS filesystem UUID)
> 2. The `/swap` entry does **not** contain `compress=zstd:3`
> 3. The `/boot` entry is `vfat` with a different UUID

> [!tip]- Quick check: verify no compression on @swap
> ```bash
> grep '/swap' /mnt/etc/fstab | grep -o 'compress=[^,]*' && echo "⚠️  REMOVE compression from @swap entry!" || echo "✅ @swap has no compression"
> ```

- [ ] Status

---

### 15. Chrooting

```bash
arch-chroot /mnt
```

- [ ] Status

---

### 16. Setting System Time

**Recommended** (one command)

```bash
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && hwclock --systohc
```

**OR** step by step

```bash
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
```

```bash
hwclock --systohc
```

- [ ] Status

---

### 17. Setting System Language

**Recommended** (one-liner via SSH)

```bash
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen && echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

**OR** step by step

```bash
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
```

```bash
locale-gen
```

```bash
echo "LANG=en_US.UTF-8" > /etc/locale.conf
```

> [!note]- Manual method
> ```bash
> nvim /etc/locale.gen
> ```
> Uncomment `en_US.UTF-8 UTF-8`, save, then run `locale-gen` and create `/etc/locale.conf`.

- [ ] Status

---

### 18. Setting Hostname

**(replace with your desired hostname)**

```bash
echo "dawn" > /etc/hostname
```

- [ ] Status

---

### 19. Setting Root Password

```bash
passwd
```

- [ ] Status

---

### 20. Creating User Account

**(replace with your username)**

```bash
useradd -m -G wheel,input,audio,video,storage,optical,network,lp,power,games,rfkill your_username
```

```bash
passwd your_username
```

> [!tip]- **Libvirt users:** Add yourself to the `libvirt` group later
> The `libvirt` group is created by the `libvirt` package. Add yourself after installing libvirt:
> ```bash
> sudo usermod -aG libvirt your_username
> ```

- [ ] Status

---

### 21. Allowing Wheel Group Root Rights

**Recommended** (drop-in file)

```bash
echo '%wheel ALL=(ALL:ALL) ALL' | EDITOR='tee' visudo -f /etc/sudoers.d/10_wheel
```

**OR** manually edit

```bash
EDITOR=nvim visudo
```

> [!note] Uncomment: `%wheel ALL=(ALL:ALL) ALL`

- [ ] Status

---

### 22. Configuring mkinitcpio for Encrypted BTRFS Boot

> [!danger] **This is the most critical step for LUKS boot. Get the HOOKS order right or you will not boot.**
>
> Key differences from an unencrypted setup:
> 1. **`keyboard` moved before `autodetect`** — ensures keyboard modules are always included so you can type your LUKS passphrase
> 2. **`sd-encrypt` added after `block`** — systemd-native LUKS decryption hook (must use this with `systemd` base hook, **not** the busybox `encrypt` hook)

**Recommended** (drop-in file via SSH — Modern Arch Standard)

```bash
mkdir -p /etc/mkinitcpio.conf.d && cat << 'EOF' > /etc/mkinitcpio.conf.d/10-arch-btrfs-luks.conf
MODULES=(btrfs)
BINARIES=(/usr/bin/btrfs)
HOOKS=(systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems)
EOF
```

OR manually create the drop-in
```bash
mkdir -p /etc/mkinitcpio.conf.d
nvim /etc/mkinitcpio.conf.d/10-arch-btrfs-luks.conf
```


> [!note] Paste these exact three lines into the new file:
> ```ini
> MODULES=(btrfs)
> BINARIES=(/usr/bin/btrfs)
> HOOKS=(systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems)
> ```


> [!note]- **HOOKS order explained**
>
> | Hook | Purpose | Why This Position |
> |---|---|---|
> | `systemd` | Replaces `base` + `udev` — systemd-based init in initramfs | Always first |
> | `keyboard` | Keyboard driver modules | **Before `autodetect`** so keyboard is always included |
> | `autodetect` | Reduces initramfs to only hardware-relevant modules | After keyboard |
> | `microcode` | CPU microcode early loading (bundled into initramfs) | After autodetect |
> | `modconf` | Loads `/etc/modprobe.d/` configs | After autodetect |
> | `kms` | Kernel Mode Setting for early display | After modconf |
> | `sd-vconsole` | Console font + keymap (systemd version) | After kms |
> | `block` | Block device modules (NVMe, SATA, USB storage) | Before sd-encrypt |
> | `sd-encrypt` | **LUKS decryption** via `systemd-cryptsetup` | After block, before filesystems |
> | `filesystems` | Filesystem modules (btrfs, ext4, vfat) | Last — needs decrypted device |

> [!warning]- **Common mistakes that will prevent boot**
> - ❌ `keyboard` after `autodetect` → keyboard may not work for LUKS passphrase
> - ❌ Using `encrypt` instead of `sd-encrypt` with `systemd` hook → incompatible, silent failure
> - ❌ Using `cryptdevice=` in kernel cmdline with `sd-encrypt` → wrong syntax
> - ❌ Forgetting `cryptsetup` package → `sd-encrypt` hook fails to build
> - ❌ `sd-encrypt` before `block` → block devices not available when LUKS tries to open

- [ ] Status

---

### 23. Installing Packages

**[[Package Installation]]**

> [!important] Ensure these are included somewhere (either in pacstrap from Step 13 or in your package list):
>
> | Package | Check |
> |---|---|
> | `cryptsetup` | ✅ Already in pacstrap |
> | `limine` | ⬜ Add if not in your list |
> | `efibootmgr` | ⬜ Add if not in your list |
> | `btrfs-progs` | ✅ Already in pacstrap |

- [ ] Status

---

### 24. Generating Initramfs

```bash
mkinitcpio -P
```

> [!warning] **Check the output for errors.** Look for:
> - `==> ERROR: Hook 'sd-encrypt' cannot be found` → `cryptsetup` package is not installed
> - You should see `sd-encrypt` in the hook list and `Image generation successful` at the end

```bash
ls -la /boot/initramfs-*.img /boot/vmlinuz-*
```

> [!note]- Expected files in /boot
> ```
> /boot/vmlinuz-linux
> /boot/initramfs-linux.img
> /boot/initramfs-linux-fallback.img
> ```

- [ ] Status

---

### 25. Limine Bootloader Installation & Configuration

#### 25a. Install Limine and efibootmgr

*Skip if already installed via [[Package Installation]] in Step 23*

```bash
pacman -S --needed limine efibootmgr
```

#### 25b. Deploy Limine EFI Binary to the ESP

```bash
mkdir -p /boot/EFI/BOOT && cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
```

> [!note]- Why `EFI/BOOT/BOOTX64.EFI`?
> This is the UEFI **fallback** boot path. The firmware will find and boot it even without a custom UEFI boot entry — most resilient option.


#### 25c. Create the Limine Configuration

> [!danger] **The kernel cmdline must use `rd.luks.name=` syntax** (not `cryptdevice=`). Since mkinitcpio uses `systemd` + `sd-encrypt`, using the wrong syntax means LUKS won't decrypt.

```bash
cat > /boot/limine.conf << 'EOF'
timeout: 3
default_entry: 2
remember_last_entry: yes


/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: rd.luks.name=LUKS-UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
    module_path: boot():/initramfs-linux.img

/Arch Linux (Fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: rd.luks.name=LUKS-UUID=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw
    module_path: boot():/initramfs-linux-fallback.img
EOF
```

**Substitute your actual LUKS UUID:**

```bash
LUKS_UUID=$(blkid -s UUID -o value /dev/root_partition)
echo "Your LUKS UUID: $LUKS_UUID"
sed -i "s/LUKS-UUID/$LUKS_UUID/g" /boot/limine.conf
```

> [!important] Replace `/dev/root_partition` with your actual raw encrypted partition (e.g., `/dev/nvme0n1p2`).

**Verify:**

```bash
cat /boot/limine.conf
```

> [!note]- Expected output (with your real UUID substituted)
> ```
> timeout: 5
> verbose: no
>
> /Arch Linux
>     protocol: linux
>     kernel_path: boot():/vmlinuz-linux
>     cmdline: rd.luks.name=a1b2c3d4-e5f6-7890-abcd-ef1234567890=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
>     module_path: boot():/initramfs-linux.img
>
> /Arch Linux (Fallback)
>     protocol: linux
>     kernel_path: boot():/vmlinuz-linux
>     cmdline: rd.luks.name=a1b2c3d4-e5f6-7890-abcd-ef1234567890=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw
>     module_path: boot():/initramfs-linux-fallback.img
> ```
>
> **Verify:**
> - UUID looks real (not literal text `LUKS-UUID`)
> - `rd.luks.name=` (not `cryptdevice=`)
> - `rd.luks.options=discard` (enables TRIM passthrough)
> - `rootflags=subvol=@` (boots the `@` subvolume)
> - Fallback uses `initramfs-linux-fallback.img` and has no `quiet`

> [!note]- Kernel cmdline parameters explained
>
> | Parameter | Purpose |
> |---|---|
> | `rd.luks.name=<UUID>=cryptroot` | Tells `sd-encrypt` to decrypt LUKS partition and map to `/dev/mapper/cryptroot` |
> | `rd.luks.options=discard` | Passes `--allow-discards` to `cryptsetup open` — SSD TRIM through LUKS |
> | `root=/dev/mapper/cryptroot` | The decrypted device is the root filesystem |
> | `rootflags=subvol=@` | Mount the `@` subvolume as root |
> | `rw` | Mount root read-write |
> | `quiet` | Suppress kernel log messages (removed from fallback for debugging) |

> [!tip]- **Microcode note**
> Since the `microcode` hook is in your mkinitcpio HOOKS, Intel/AMD microcode is **bundled inside** `initramfs-linux.img`. No separate `module_path` line for `intel-ucode.img` needed.

#### 25d. Create a UEFI Boot Entry

> [!note] Adjust `--disk` and `--part` to match your ESP. If ESP is `/dev/nvme0n1p1`, disk is `/dev/nvme0n1`, part is `1`.

```bash
efibootmgr --create \
  --disk /dev/sdX \
  --part 1 \
  --loader '\EFI\BOOT\BOOTX64.EFI' \
  --label 'Limine' \
  --unicode
```

```bash
efibootmgr -v
```

> [!tip]- Setting Limine as the first boot option
> ```bash
> # Replace 0001 with your actual Limine boot number
> efibootmgr --bootorder 0001
> ```

#### 25e. Create a Pacman Hook for Automatic Limine Updates

```bash
mkdir -p /etc/pacman.d/hooks
```

```bash
cat > /etc/pacman.d/hooks/limine-update.hook << 'EOF'
[Trigger]
Type = Package
Operation = Install
Operation = Upgrade
Target = limine

[Action]
Description = Deploying updated Limine EFI binary to ESP...
When = PostTransaction
Exec = /usr/bin/cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
EOF
```

#### 25f. Secure Boot Implementation (Evil Maid Protection)

> [!warning] **BIOS Setup Required First**
> 
> Before executing these commands, your motherboard must be in "Setup Mode". This usually requires you to go into your BIOS/UEFI, **Disable Secure Boot**, and select **Clear all Secure Boot Keys** (or "Restore Factory Keys" depending on your vendor).

_Install the secure boot key manager_

```
pacman -S --needed sbctl
```

_Verify the system is in Setup Mode_

```
sbctl status
```

> [!note] You should see `Setup Mode: ✓ Enabled`. If it says disabled, your keys were not properly cleared in the BIOS.

_Create your custom secure boot keys_

```
sbctl create-keys
```

_Enroll the custom keys into your UEFI firmware_

```
sbctl enroll-keys -m
```

_Sign the Limine EFI binary and the Linux Kernel_

```bash
sbctl sign -s /boot/EFI/BOOT/BOOTX64.EFI
```
```bash
sbctl sign -s /boot/vmlinuz-linux
```

>[!warning] Architectural Limitation: Kernel Verification
> Because Limine boots the kernel using protocol: linux, it loads the kernel file directly without verifying its PE/COFF cryptographic signature against the UEFI keys.
> This setup ensures the motherboard validates the Limine bootloader (BOOTX64.EFI), preventing straightforward tampering of the EFI partition. However, true end-to-end Secure Boot requires migrating to Unified Kernel Images (UKIs) later.

> [!note]- What the -s flag does
> Passing -s tells sbctl to save this file path to its internal database. The pacman hook we create next will automatically re-sign the Limine binary whenever the limine package is upgraded.

> [!tip] **Final Step:** After you finish the rest of this installation guide and reboot your system for the first time, go back into your BIOS and **Enable Secure Boot**. Your system will now cryptographically reject any boot binaries not signed by your custom keys.


- [ ] Status


---
### 26. Fallback Disk-Based Swap File

> [!info] **Why disk swap alongside ZRAM?**
> ZRAM compresses pages in RAM — fast but limited to physical memory. When your system is under extreme memory pressure (many VMs, large compilations, browser with 200 tabs), ZRAM fills up. Without a fallback, the OOM killer starts terminating processes. A disk swap file provides a safety net: slower than ZRAM, but prevents crashes.
>
> **Priority system:** ZRAM gets priority `100` (default from `systemd-zram-generator`). Disk swap gets priority `10`. The kernel exhausts ZRAM first, then spills to disk only when necessary.

#### 26a. Create the Swap File

```bash
btrfs filesystem mkswapfile --size 8G /swap/swapfile
```

> [!note]- What `btrfs filesystem mkswapfile` does automatically
> - Creates the file with the correct size
> - Sets the `NOCOW` (no copy-on-write) attribute — required for swap on BTRFS
> - Disables compression on the file
> - Allocates contiguous extents (no holes/sparse regions)
> - Runs `mkswap` on the file
>
> This command was added in `btrfs-progs` 6.1 (2023). It replaces the old multi-step process of `truncate` + `chattr +C` + `fallocate` + `mkswap`.

> [!tip] **Sizing the swap file**
> - `8G` is a reasonable fallback for systems with 16–32 GB RAM
> - For **hibernation** (suspend-to-disk), you need swap ≥ your RAM size — this guide does not configure hibernation
> - You can resize later: delete the file, recreate with a different size

#### 26b. Add Swap to fstab

```bash
echo '/swap/swapfile none swap defaults,pri=10 0 0' >> /etc/fstab
```

> [!note] `pri=10` sets the swap priority lower than ZRAM (`pri=100`). The kernel uses higher-priority swap first.

#### 26c. Verify

```bash
grep swap /etc/fstab
```

You should see two swap-related lines:
1. The `@swap` subvolume mount at `/swap`
2. The swap file entry: `/swap/swapfile none swap defaults,pri=10 0 0`

> [!note]- About hibernation (not configured in this guide)
> If you want hibernate/suspend-to-disk in the future, you also need:
> 1. Swap file ≥ RAM size
> 2. `resume=/dev/mapper/cryptroot` in kernel cmdline
> 3. `resume_offset=<offset>` in kernel cmdline (get with `btrfs inspect-internal map-swapfile -r /swap/swapfile`)
> 4. Add the `resume` hook to mkinitcpio HOOKS (after `filesystems`)

- [ ] Status

---

### 27. ZRAM Configuration & Swappiness Tuning

#### 27a. ZRAM as Block Device and Swap Device

**Recommended** (one command)

```bash
mkdir -p /mnt/zram1 && cat > /etc/systemd/zram-generator.conf << 'EOF'
[zram0]
zram-size = ram - 2000
compression-algorithm = zstd

[zram1]
zram-size = ram - 2000
fs-type = ext2
mount-point = /mnt/zram1
compression-algorithm = zstd
options = rw,nosuid,nodev,discard,X-mount.mode=1777
EOF
```

**OR** manually

```bash
mkdir -p /mnt/zram1
```

```bash
nvim /etc/systemd/zram-generator.conf
```

```ini
[zram0]
zram-size = ram - 2000
compression-algorithm = zstd

[zram1]
zram-size = ram - 2000
fs-type = ext2
mount-point = /mnt/zram1
compression-algorithm = zstd
options = rw,nosuid,nodev,discard,X-mount.mode=1777
```

#### 27b. Swappiness Tuning

> [!info] **Why `vm.swappiness=180`?**
> Default swappiness is `60` (scale 0–200 since kernel 5.8). With ZRAM as primary swap, you **want** the kernel to aggressively move inactive pages to ZRAM — this effectively compresses cold memory, freeing physical RAM for active use. Fedora, SteamOS, and other ZRAM-centric distros use `180`. This does **not** increase disk swap usage — the priority system ensures ZRAM is used first.

```bash
echo 'vm.swappiness=180' > /etc/sysctl.d/99-swappiness.conf
```

- [ ] Status

---

### 28. LUKS Header Backup (Strongly Recommended)

> [!danger] **If the LUKS header is corrupted or overwritten, ALL data on the encrypted partition is permanently lost.** No password will help — the master key is stored in the header. Back it up now.

```bash
cryptsetup luksHeaderBackup /dev/root_partition --header-backup-file /home/your_username/luks-header-backup.img
```

> [!warning] **Store this backup file OFF this disk** — on a USB drive, cloud storage, etc. If the disk dies, the backup on the same disk is useless. The file is ~16 MiB. Guard it like a key — anyone with the header backup + your passphrase can decrypt a copy of your partition.

- [ ] Status

---

### 29. System Services

```bash
systemctl enable NetworkManager.service tlp.service udisks2.service thermald.service bluetooth.service firewalld.service fstrim.timer systemd-timesyncd.service acpid.service vsftpd.service reflector.timer swayosd-libinput-backend systemd-resolved.service
```

*TLP radio device wizard masks:*

```bash
systemctl mask systemd-rfkill.service systemd-rfkill.socket
```

> [!note]- About `fstrim.timer` and `discard=async`
> You have both continuous TRIM (`discard=async` in mount options + `rd.luks.options=discard` for LUKS passthrough) and periodic TRIM (`fstrim.timer`). Both are safe together. `discard=async` handles routine block reclamation; `fstrim.timer` catches anything that might have been missed.

### Supporting Commands
- For systemd resolved service to work , you need to symlink this file. 
NetworkManager will ignore it and use its own DNS backend unless you explicitly link the system's DNS resolver file to `systemd-resolved`'s stub file.

```bash
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
```

- for reflector to sync mirrors with your contry pick your contry's name 
```bash
_Configure Reflector for optimal mirror speeds (India)_

```bash
mkdir -p /etc/xdg/reflector
cat << 'EOF' > /etc/xdg/reflector/reflector.conf
--save /etc/pacman.d/mirrorlist
--protocol https
--country US
--latest 6
--sort rate
EOF
```

- [ ] Status

---

### 30. Concluding & First Reboot

```bash
exit
```

```bash
umount -R /mnt
```

```bash
poweroff
```

> [!important] **Remove the USB installation media** before powering on again.

- [ ] Status

---

### 31. First Boot Verification

> [!note] **What to expect on first boot:**
> 1. **Limine boot menu** appears (5-second timeout)
> 2. Select **Arch Linux** (or let it auto-boot)
> 3. **LUKS passphrase prompt:**
>    ```
>    Please enter passphrase for disk /dev/sdX2 (cryptroot): ████
>    ```
> 4. System boots into your Arch Linux installation
> 5. Log in with your user account

Run these after your first successful boot:

```bash
# 1. Confirm you booted from the encrypted volume
lsblk -f | grep crypto_LUKS
```

```bash
# 2. Verify BTRFS subvolume mounts
findmnt -t btrfs
# Should show all 9 subvolume mounts
```

```bash
# 3. Verify swap (both ZRAM and disk)
swapon --show
# Should show:
#   zram0           partition  ...  100  (ZRAM — high priority)
#   /swap/swapfile  file       8G   10   (disk — low priority)
```

```bash
# 4. Verify swappiness
cat /proc/sys/vm/swappiness
# Should output: 180
```

```bash
# 5. Verify TRIM is working through LUKS
sudo dmsetup table cryptroot | grep -o 'allow_discards' && echo "✅ TRIM passthrough enabled" || echo "⚠️  TRIM passthrough not active"
```

```bash
# 6. Verify Limine boot entry
efibootmgr -v | grep -i limine
```

```bash
# 7. Check BTRFS health
sudo btrfs device stats /
# All counters should be 0
```

```bash
# 8. Verify snapshot subvolumes are ready for future configuration
ls -la /.snapshots /home/.snapshots
# Both directories should exist 
```

- [ ] Status

---

### 32. Ongoing Maintenance

#### 32a. Check Disk Usage

```bash
# Overall filesystem usage
sudo btrfs filesystem usage /
```

#### 32b. BTRFS Scrub — Periodic Integrity Check

> [!tip] Run a scrub monthly. It reads all data and metadata, verifying checksums. On a single-disk setup it detects corruption but cannot auto-repair (no redundancy). Still valuable for early detection.

```bash
sudo btrfs scrub start /
```

```bash
sudo btrfs scrub status /
```

> [!tip]- **Optional: automate with a systemd timer**
> ```bash
> sudo systemctl enable --now btrfs-scrub@-.timer
> ```
> Runs monthly by default.


---

### 33. Quick-Reference Cheat Sheet

```bash
# ─── BTRFS Operations ───────────────────────────────────────────
sudo btrfs subvolume list /                                 # List all subvolumes
sudo btrfs filesystem usage /                               # Disk usage
sudo btrfs scrub start /                                    # Start integrity check
sudo btrfs scrub status /                                   # Check scrub progress
sudo btrfs device stats /                                   # Check error counters

# ─── LUKS Operations ────────────────────────────────────────────
sudo cryptsetup luksDump /dev/root_partition                 # Show LUKS header info
sudo cryptsetup luksAddKey /dev/root_partition               # Add a passphrase
sudo cryptsetup luksRemoveKey /dev/root_partition            # Remove a passphrase
sudo cryptsetup luksHeaderBackup /dev/root_partition \
  --header-backup-file ~/luks-header-backup.img             # Backup LUKS header

# ─── Boot / Limine Operations ───────────────────────────────────
cat /boot/limine.conf                                       # View boot config
sudo nvim /boot/limine.conf                                 # Edit boot config
efibootmgr -v                                               # View UEFI boot entries
ls -la /boot/vmlinuz-* /boot/initramfs-*                    # List kernel files
cat /proc/cmdline                                           # Current boot cmdline

# ─── Initramfs ──────────────────────────────────────────────────
sudo mkinitcpio -P                                          # Rebuild all initramfs
cat /etc/mkinitcpio.conf.d/10-arch-btrfs-luks.conf          # Check HOOKS order

# ─── Swap Status ────────────────────────────────────────────────
swapon --show                                               # Show active swap devices
cat /proc/sys/vm/swappiness                                 # Current swappiness value

# ─── Service Status ─────────────────────────────────────────────
systemctl list-timers --all | grep -E 'fstrim|scrub' # All relevant timers

```

---

## Final System Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                         UEFI Firmware                                │
│                              │                                       │
│                     ┌────────▼─────────────────────────────┐         │
│                     │  Limine (ESP)                        │         │
│                     │  /boot                               │         │
│                     │  ├── limine.conf                     │         │
│                     │  ├── vmlinuz-linux                   │         │
│                     │  ├── vmlinuz-linux-previous          │         │
│                     │  ├── initramfs-linux.img             │         │
│                     │  ├── initramfs-linux-previous.img    │         │
│                     │  └── EFI/BOOT/BOOTX64.EFI            │         │
│                     └────────┬─────────────────────────────┘         │
│                              │ rd.luks.name=UUID=cryptroot           │
│                     ┌────────▼────────┐                              │
│                     │   LUKS2 Layer   │                              │
│                     │ /dev/mapper/    │                              │
│                     │   cryptroot     │                              │
│                     └────────┬────────┘                              │
│                              │                                       │
│              ┌───────────────▼───────────────┐                       │
│              │     BTRFS Filesystem          │                       │
│              │                               │                       │
│  Snapshotted:│  @ ──────────► /              │                       │
│              │  @home ──────► /home          │                       │
│              │                               │                       │
│  Excluded:   │  @snapshots ─► /.snapshots    │ ◄── Future metadata   │
│  (no snapshot│  @home_snap ─► /home/.snap    │ ◄── Future metadata   │
│   bloat)     │  @var_log ──► /var/log        │ ◄── Logs              │
│              │  @var_cache ► /var/cache      │ ◄── Pacman cache      │
│              │  @var_tmp ──► /var/tmp        │ ◄── Temp files        │
│              │  @var_lib_   ► /var/lib/      │ ◄── VM disk images    │
│              │    libvirt      libvirt       │                       │
│              │  @swap ─────► /swap           │ ◄── NOCOW swap file   │
│              │                               │                       │
│  Swap:       │  ZRAM (priority 100)          │ ◄── Primary swap      │
│              │  /swap/swapfile (priority 10) │ ◄── Fallback swap     │
│              └───────────────────────────────┘                       │
│                                                                      │
│  Pacman hooks: limine-update.hook     ◄── Sync EFI binary            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## All Services Enabled (Combined)

```bash
# System services (Step 29, during chroot)
systemctl enable NetworkManager.service tlp.service udisks2.service \
  thermald.service bluetooth.service firewalld.service fstrim.timer \
  systemd-timesyncd.service acpid.service vsftpd.service reflector.timer \
  swayosd-libinput-backend systemd-resolved.service

# TLP masks (Step 29, during chroot)
systemctl mask systemd-rfkill.service systemd-rfkill.socket

```

---

## All Required Packages Summary

| Package | Repo | Installed In | Purpose |
|---|---|---|---|
| `cryptsetup` | `core` | pacstrap (Step 13) | LUKS2 encryption |
| `btrfs-progs` | `core` | pacstrap (Step 13) | BTRFS tools |
| `dosfstools` | `core` | pacstrap (Step 13) | FAT32 ESP tools |
| `limine` | `extra` | pacman (Step 25) | Bootloader |
| `efibootmgr` | `core` | pacman (Step 25) | UEFI boot entries |
| `snapper` | `extra` | pacman (Step 32) | Snapshot manager |
| `snap-pac` | `extra` | pacman (Step 32) | Auto pacman snapshots |
| `sbctl` | `extra` | pacman (Step 25f) | Secure Boot key manager |

---

## Troubleshooting

> [!note]- **Can't type LUKS passphrase (keyboard not working)**
> ```bash
> # Boot from live USB
> cryptsetup open /dev/root_partition cryptroot
> mount -o subvol=@ /dev/mapper/cryptroot /mnt
> mount /dev/esp_partition /mnt/boot
> arch-chroot /mnt
> ```
> # Verify HOOKS in your drop-in file — keyboard MUST be before autodetect
> ```bash
> cat /etc/mkinitcpio.conf.d/10-arch-btrfs-luks.conf
> ```
>
> # Fix if needed using modern Bash redirection
> ```bash
> cat << 'EOF' > /etc/mkinitcpio.conf.d/10-arch-btrfs-luks.conf
> MODULES=(btrfs)
> BINARIES=(/usr/bin/btrfs)
> HOOKS=(systemd keyboard autodetect microcode modconf kms sd-vconsole block sd-encrypt filesystems)
> EOF
> ```
>
> ```bash
> mkinitcpio -P
> exit
> umount -R /mnt
> reboot
> ```

> [!note]- **LUKS doesn't decrypt / kernel panic after passphrase**
> ```bash
> # Boot from live USB, mount ESP only
> mount /dev/esp_partition /mnt
> cat /mnt/limine.conf
>
> # Check LUKS UUID matches
> blkid /dev/root_partition
>
> # Common issues:
> # - Wrong UUID in limine.conf
> # - Using cryptdevice= instead of rd.luks.name=
> # - Typo in root=/dev/mapper/cryptroot
>
> # Fix limine.conf, unmount, reboot
> ```

> [!note]- **System boots but subvolumes not mounted**
> ```bash
> cat /etc/fstab
> sudo mount -a
>
> # If mount fails, verify the BTRFS UUID
> sudo blkid /dev/mapper/cryptroot
> # Compare with UUIDs in fstab
> ```

---

> [!tip] **Installation complete.** Your Arch Linux system has:
> - ✅ Full-disk LUKS2 encryption
> - ✅ BTRFS with 9 granular subvolumes (libvirt isolated)
> - ✅ Limine bootloader
> - ✅ ZRAM primary swap + disk-based fallback swap
