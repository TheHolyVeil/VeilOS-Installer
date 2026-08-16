#!/usr/bin/env bash
# /usr/lib/veilos/install-backend.sh — VeilOS Installation Backend

set -euo pipefail

CONFIG_FILE="/tmp/veilos-install.conf"
EXIT_CODE_FILE="/tmp/veilos-install.exitcode"
MOUNTED=0

log()   { printf "[veilos] %s\n" "$*"; }
warn()  { printf "[warn] %s\n" "$*"; }
error() {
  printf "[error] %s\n" "$*" >&2
  exit 1
}

emit_progress() {
  local msg="$1" percent="$2"
  printf "VEILOS_PROGRESS:%s:%s\n" "$msg" "$percent"
}

# Kernel/udev can take a moment to create the partition device nodes after
# sgdisk/parted rewrites the partition table. Formatting immediately after
# used to be a race that failed with "No such file or directory".
wait_for_partition() {
  local dev="$1" tries=0
  while [[ ! -b "$dev" && $tries -lt 50 ]]; do
    sleep 0.2
    ((tries++))
  done
  [[ -b "$dev" ]] || error "Partition $dev never appeared after partitioning."
}

# btrfs swapfiles need No_COW + no compression or the kernel refuses to swap
# on them; ext4/xfs don't care. fallocate is preferred but some filesystems/
# kernels don't support it for this, so fall back to a slower dd zero-fill.
create_swapfile() {
  local size_mb="$1" swapfile="/mnt/swapfile"
  log "Creating ${size_mb}MiB swapfile at $swapfile..."
  if [[ "$FILESYSTEM" == "btrfs" ]]; then
    touch "$swapfile"
    chattr +C "$swapfile" 2>/dev/null || warn "chattr +C failed — swapfile on btrfs needs No_COW (kernel 5.0+) to work reliably."
  fi
  if ! fallocate -l "${size_mb}M" "$swapfile" 2>/dev/null; then
    warn "fallocate unsupported here, falling back to dd (slower)..."
    dd if=/dev/zero of="$swapfile" bs=1M count="$size_mb" status=none
  fi
  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
  echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab
}

# -----------------------------------------------------------------------------
# 0. CLEANUP / EXIT-CODE HANDLING
# -----------------------------------------------------------------------------
# The GUI reads /tmp/veilos-install.exitcode because a `sudo bash backend | tee`
# pipeline in bash reports the exit status of the LAST stage of the pipe (tee/yad),
# not the backend's — so a mid-install failure was previously reported as success.
cleanup() {
  local rc=$?
  echo "$rc" > "$EXIT_CODE_FILE"
  if [[ $rc -ne 0 && $MOUNTED -eq 1 ]]; then
    warn "Install failed (exit $rc) — attempting to unmount /mnt so the disk isn't left busy."
    umount -R /mnt 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. LOAD CONFIGURATION
# -----------------------------------------------------------------------------
[[ -f "$CONFIG_FILE" ]] || error "Configuration file $CONFIG_FILE not found."
# shellcheck disable=SC1090
source "$CONFIG_FILE"

log "Loaded configuration for target disk: $DISK"

# -----------------------------------------------------------------------------
# 2. PRE-FLIGHT: dependency + sanity checks (before anything destructive)
# -----------------------------------------------------------------------------
emit_progress "Checking requirements" 2

REQUIRED_BINS=(wipefs sgdisk parted mkfs.vfat mkfs.ext4 mkfs.btrfs mkfs.xfs
  blkid partprobe udevadm genfstab arch-chroot pacstrap mkinitcpio lsblk swapoff mkswap)
missing=()
for bin in "${REQUIRED_BINS[@]}"; do
  command -v "$bin" &>/dev/null || missing+=("$bin")
done
[[ ${#missing[@]} -eq 0 ]] || error "Missing required tools: ${missing[*]} (check gptfdisk/parted/dosfstools/e2fsprogs/btrfs-progs/xfsprogs/arch-install-scripts are installed on the live ISO)."

[[ -n "${DISK:-}" ]] || error "DISK is not set in $CONFIG_FILE."
[[ -b "$DISK" ]] || error "$DISK is not a valid block device."

case "${FILESYSTEM:-}" in btrfs|ext4|xfs) ;; *) error "Unsupported/unset filesystem: ${FILESYSTEM:-<empty>}" ;; esac
case "${BOOTLOADER:-}" in grub|limine|systemd-boot) ;; *) error "Unknown/unset bootloader: ${BOOTLOADER:-<empty>}" ;; esac
case "${BOOT_MODE:-}" in efi|bios) ;; *) error "Unknown/unset boot mode: ${BOOT_MODE:-<empty>}" ;; esac
[[ "$BOOT_MODE" == "efi" || "$BOOTLOADER" != "systemd-boot" ]] || error "systemd-boot requires UEFI; refusing to install on BIOS."

# Limine's BIOS stage lives outside the chroot — it has to be on the live ISO
# itself, not just pacstrapped into /mnt, or "limine bios-install" below fails.
if [[ "$BOOTLOADER" == "limine" && "$BOOT_MODE" == "bios" ]]; then
  command -v limine &>/dev/null || error "BOOTLOADER=limine on a BIOS system requires the 'limine' package on the live ISO itself (not just in the target install)."
fi

SWAP_TYPE="${SWAP_TYPE:-none}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-0}"
case "$SWAP_TYPE" in
  none) ;;
  swapfile|partition)
    [[ "$SWAP_SIZE_MB" =~ ^[0-9]+$ && "$SWAP_SIZE_MB" -gt 0 ]] || error "SWAP_TYPE=$SWAP_TYPE but SWAP_SIZE_MB (\"$SWAP_SIZE_MB\") is not a positive integer."
    ;;
  *) error "Unknown SWAP_TYPE: $SWAP_TYPE (expected none, swapfile, or partition)" ;;
esac
[[ "$SWAP_TYPE" != "partition" || "$FILESYSTEM" != "btrfs" ]] || warn "Swap partition + btrfs root: fine, no interaction — partition swap doesn't touch the filesystem."
log "Swap: type=$SWAP_TYPE size=${SWAP_SIZE_MB}MiB"

LOGIN_MANAGER="${LOGIN_MANAGER:-auto}"
case "$LOGIN_MANAGER" in
  auto*|sddm|gdm|lightdm|velogin|none) ;;
  custom) [[ -n "${LOGIN_MANAGER_CMD:-}" ]] || error "LOGIN_MANAGER=custom but LOGIN_MANAGER_CMD is empty." ;;
  *) error "Unknown LOGIN_MANAGER: $LOGIN_MANAGER" ;;
esac

# Plymouth boot splash — only wired in if the theme actually shipped on the
# live ISO. Detected here (before pacstrap) so the package only gets pulled
# in when there's an actual theme to install.
PLYMOUTH_THEME_SRC="/usr/lib/veilos/plymouth/veilos"
if [[ -d "$PLYMOUTH_THEME_SRC" ]]; then
  PLYMOUTH_AVAILABLE=1
  log "VeilOS Plymouth theme found — will install and enable it."
else
  PLYMOUTH_AVAILABLE=0
  warn "$PLYMOUTH_THEME_SRC not found on the live ISO — boot will use the default (unbranded) splash."
fi

# Onboard tools (machina, yay-bin, glasspad) now come from your own veilos
# repo in pacman.conf. Refresh sync dbs and confirm they actually resolve
# before touching the disk — a repo misconfiguration should fail here, not
# halfway through pacstrap after the disk is already wiped.
ONBOARD_PACKAGES=(machina yay-bin glasspad)
log "Checking veilos repo for onboard packages: ${ONBOARD_PACKAGES[*]}..."
pacman -Sy &>/dev/null || warn "pacman -Sy failed — check network/mirrors before continuing."
if ! pacman -Si "${ONBOARD_PACKAGES[@]}" &>/dev/null; then
  error "One or more onboard packages (${ONBOARD_PACKAGES[*]}) aren't resolvable — check the [veilos] repo entry in pacman.conf on the live ISO and that its server is reachable."
fi
log "Onboard packages resolved OK."

# Refuse to touch the medium we're currently booted/running from
LIVE_SRC=$(findmnt -no SOURCE / 2>/dev/null || true)
for mp in /run/archiso/bootmnt /run/miso/bootmnt; do
  [[ -d "$mp" ]] && LIVE_SRC+=" $(findmnt -no SOURCE "$mp" 2>/dev/null || true)"
done
LIVE_DISK=$(lsblk -no PKNAME "$DISK" 2>/dev/null || true)
for src in $LIVE_SRC; do
  [[ -n "$src" ]] || continue
  src_disk="/dev/$(lsblk -no PKNAME "$src" 2>/dev/null || true)"
  if [[ "$src_disk" == "$DISK" || "$src" == "$DISK" ]]; then
    error "$DISK appears to be the live boot medium — refusing to partition it."
  fi
done

# Make sure nothing on the target disk is mounted, swapped-on, or part of an
# active LVM/RAID/LUKS stack — sgdisk/wipefs will otherwise fail with
# "device or resource busy" (or worse, silently touch a device still in use).
log "Checking for active mounts/swap/LVM/RAID on $DISK..."
while read -r part; do
  [[ -n "$part" ]] || continue
  dev="/dev/$part"
  mnt=$(findmnt -no TARGET "$dev" 2>/dev/null || true)
  [[ -n "$mnt" ]] && { log "Unmounting $dev from $mnt..."; umount -R "$dev" 2>/dev/null || true; }
  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$dev"; then
    log "Disabling swap on $dev..."
    swapoff "$dev" || true
  fi
  if command -v pvs &>/dev/null && pvs --noheadings -o vg_name "$dev" 2>/dev/null | grep -q .; then
    vg=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | xargs)
    [[ -n "$vg" ]] && { log "Deactivating LVM volume group $vg..."; vgchange -an "$vg" 2>/dev/null || true; }
  fi
  if command -v cryptsetup &>/dev/null && lsblk -no TYPE "$dev" 2>/dev/null | grep -q crypt; then
    warn "Encrypted mapping detected on $dev — closing may be required manually if wipe fails."
  fi
done < <(lsblk -no NAME "$DISK" 2>/dev/null | tail -n +2)

# -----------------------------------------------------------------------------
# 3. DISK PARTITIONING & FORMATTING
# -----------------------------------------------------------------------------
emit_progress "Partitioning disk" 10
log "Wiping existing partition table on $DISK..."
wipefs -af "$DISK"
sgdisk -Z "$DISK"
partprobe "$DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || true

if [[ "$BOOT_MODE" == "efi" ]]; then
  log "Creating GPT partitions (UEFI)..."
  sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$DISK"
  if [[ "$SWAP_TYPE" == "partition" ]]; then
    sgdisk -n 2:0:+${SWAP_SIZE_MB}M -t 2:8200 -c 2:"Swap" "$DISK"
    sgdisk -n 3:0:0 -t 3:8300 -c 3:"Root" "$DISK"
  else
    sgdisk -n 2:0:0     -t 2:8300 -c 2:"Root" "$DISK"
  fi

  # Handle partition naming scheme (e.g., /dev/nvme0n1p1 vs /dev/sda1)
  if [[ "$DISK" =~ [0-9]$ ]]; then SEP="p"; else SEP=""; fi
  PART_BOOT="${DISK}${SEP}1"
  if [[ "$SWAP_TYPE" == "partition" ]]; then
    PART_SWAP="${DISK}${SEP}2"
    PART_ROOT="${DISK}${SEP}3"
  else
    PART_ROOT="${DISK}${SEP}2"
  fi

  partprobe "$DISK" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  wait_for_partition "$PART_BOOT"
  [[ "$SWAP_TYPE" == "partition" ]] && wait_for_partition "$PART_SWAP"
  wait_for_partition "$PART_ROOT"

  emit_progress "Formatting partitions" 20
  log "Formatting ESP partition ($PART_BOOT) as FAT32..."
  mkfs.vfat -F 32 -n "BOOT" "$PART_BOOT"
else
  log "Creating MBR partitions (BIOS)..."
  parted -s "$DISK" mklabel msdos
  parted -s "$DISK" mkpart primary fat32 1MiB 1025MiB
  parted -s "$DISK" set 1 boot on
  if [[ "$SWAP_TYPE" == "partition" ]]; then
    swap_end_mib=$((1025 + SWAP_SIZE_MB))
    parted -s "$DISK" mkpart primary linux-swap 1025MiB "${swap_end_mib}MiB"
    parted -s "$DISK" mkpart primary "${swap_end_mib}MiB" 100%
  else
    parted -s "$DISK" mkpart primary 1025MiB 100%
  fi

  if [[ "$DISK" =~ [0-9]$ ]]; then SEP="p"; else SEP=""; fi
  PART_BOOT="${DISK}${SEP}1"
  if [[ "$SWAP_TYPE" == "partition" ]]; then
    PART_SWAP="${DISK}${SEP}2"
    PART_ROOT="${DISK}${SEP}3"
  else
    PART_ROOT="${DISK}${SEP}2"
  fi

  partprobe "$DISK" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  wait_for_partition "$PART_BOOT"
  [[ "$SWAP_TYPE" == "partition" ]] && wait_for_partition "$PART_SWAP"
  wait_for_partition "$PART_ROOT"

  emit_progress "Formatting partitions" 20
  # FAT32, not ext4: Limine's (and to a lesser extent GRUB's) BIOS-mode
  # filesystem drivers have very limited ext4 support. Modern mkfs.ext4
  # enables features by default (metadata_csum, 64bit, orphan_file) that a
  # normal Linux mount reads without issue but a minimal boot-time ext4
  # parser can't — the file is genuinely on disk and still gets reported as
  # "not found" because the driver can't walk the filesystem structure to
  # find it. FAT32 has none of this ambiguity and every bootloader reads it
  # identically, which is also why the EFI ESP above is FAT32.
  log "Formatting boot partition ($PART_BOOT) as FAT32..."
  mkfs.vfat -F 32 -n "BOOT" "$PART_BOOT"
fi

if [[ "$SWAP_TYPE" == "partition" ]]; then
  log "Formatting swap partition ($PART_SWAP)..."
  mkswap -L "SWAP" "$PART_SWAP"
  swapon "$PART_SWAP"   # active during install so genfstab picks it up below
fi

log "Formatting root partition ($PART_ROOT) as $FILESYSTEM..."
case "$FILESYSTEM" in
  btrfs) mkfs.btrfs -f -L "ROOT" "$PART_ROOT" ;;
  ext4)  mkfs.ext4 -F -L "ROOT" "$PART_ROOT" ;;
  xfs)   mkfs.xfs -f -L "ROOT" "$PART_ROOT" ;;
  *)     error "Unsupported filesystem: $FILESYSTEM" ;;
esac

# -----------------------------------------------------------------------------
# 4. MOUNT TARGET FILESYSTEMS
# -----------------------------------------------------------------------------
emit_progress "Mounting filesystems" 30
log "Mounting root filesystem on /mnt..."
mount "$PART_ROOT" /mnt
MOUNTED=1

mkdir -p /mnt/boot
log "Mounting boot partition on /mnt/boot..."
mount "$PART_BOOT" /mnt/boot

# -----------------------------------------------------------------------------
# 5. MIRRORLIST (uses the country picked in the GUI's Mirror step)
# -----------------------------------------------------------------------------
if [[ -n "${MIRROR_COUNTRY:-}" && "$MIRROR_COUNTRY" != "automatic" ]] && command -v reflector &>/dev/null; then
  emit_progress "Ranking mirrors" 33
  log "Selecting fastest mirrors for country: $MIRROR_COUNTRY..."
  reflector --country "$MIRROR_COUNTRY" --protocol https --latest 10 --sort rate \
    --save /etc/pacman.d/mirrorlist || warn "reflector failed, keeping default mirrorlist"
elif [[ "${MIRROR_COUNTRY:-automatic}" == "automatic" ]] && command -v reflector &>/dev/null; then
  emit_progress "Ranking mirrors" 33
  log "Auto-selecting fastest mirrors..."
  reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist || warn "reflector failed, keeping default mirrorlist"
fi

# -----------------------------------------------------------------------------
# 6. PACSTRAP BASE SYSTEM & BOOTLOADER SELECTION
# -----------------------------------------------------------------------------
emit_progress "Preparing base packages" 35

BOOTLOADER_PKG=""
case "$BOOTLOADER" in
  grub)
    BOOTLOADER_PKG="grub"
    [[ "$BOOT_MODE" == "efi" ]] && BOOTLOADER_PKG="grub efibootmgr"
    ;;
  limine)
    BOOTLOADER_PKG="limine"
    ;;
  systemd-boot)
    BOOTLOADER_PKG="efibootmgr"
    ;;
  *)
    error "Unknown bootloader: $BOOTLOADER"
    ;;
esac

# Desktop Environment Package Mapping (DM/login manager handled separately below)
DESKTOP_PKGS=""
case "$DESKTOP" in
  plasma) DESKTOP_PKGS="plasma-meta kde-applications-meta" ;;
  gnome)  DESKTOP_PKGS="gnome gnome-extra" ;;
  xfce)   DESKTOP_PKGS="xfce4 xfce4-goodies" ;;
  i3)     DESKTOP_PKGS="i3-wm i3status i3lock" ;;
  sway)   DESKTOP_PKGS="sway swaylock swayidle foot" ;;
  veil)   DESKTOP_PKGS="foot" ;; # AUR/custom dependencies handled in post-step
  *)      DESKTOP_PKGS="" ;;
esac

# Login manager: "auto" falls back to the desktop's usual DM, an explicit
# choice (sddm/gdm/lightdm) overrides it regardless of desktop, "none" skips
# a DM entirely, and "custom" runs LOGIN_MANAGER_CMD inside the chroot later
# instead of installing/enabling any packaged DM at all (e.g. VeilLogin).
LOGIN_MANAGER="${LOGIN_MANAGER:-auto}"
DM_PKG=""
DM_SERVICE=""
case "$LOGIN_MANAGER" in
  auto*|"")
    case "$DESKTOP" in
      plasma)  DM_PKG="sddm";                          DM_SERVICE="sddm" ;;
      gnome)   DM_PKG="gdm";                            DM_SERVICE="gdm" ;;
      xfce|i3) DM_PKG="lightdm lightdm-gtk-greeter";    DM_SERVICE="lightdm" ;;
      *)       ;; # sway/veil: no DM unless the user asked for one
    esac
    ;;
  sddm)    DM_PKG="sddm";                       DM_SERVICE="sddm" ;;
  gdm)     DM_PKG="gdm";                        DM_SERVICE="gdm" ;;
  lightdm) DM_PKG="lightdm lightdm-gtk-greeter"; DM_SERVICE="lightdm" ;;
  velogin) ;; # handled via arch-chroot below — installs + enables its own units
  none)    ;;
  custom)  ;; # handled via arch-chroot + LOGIN_MANAGER_CMD after base install
  *) error "Unknown LOGIN_MANAGER: $LOGIN_MANAGER" ;;
esac

EXTRA_PKGS="curl ca-certificates"
[[ "$LOGIN_MANAGER" == "velogin" ]] && EXTRA_PKGS="$EXTRA_PKGS seatd"
[[ "$PLYMOUTH_AVAILABLE" -eq 1 ]] && EXTRA_PKGS="$EXTRA_PKGS plymouth"
# base-devel + git: no longer needed to bootstrap yay itself (it's a plain
# package in the veilos repo now), but yay still needs them on hand to build
# any *actual* AUR package later, and setup-veil.sh/setup-sway-woven.sh may
# pull further AUR deps through it.
EXTRA_PKGS="$EXTRA_PKGS base-devel git"
# Onboard tools, now plain packages in your own repo — pacstrap installs them
# in the same pass as everything else, no throwaway build user required.
EXTRA_PKGS="$EXTRA_PKGS ${ONBOARD_PACKAGES[*]}"

BASE_PACKAGES="base linux linux-firmware sudo networkmanager $BOOTLOADER_PKG $DESKTOP_PKGS $DM_PKG $EXTRA_PKGS"

emit_progress "Installing base packages (pacstrap)" 40
log "Executing pacstrap with packages: $BASE_PACKAGES"
# --noconfirm: this runs with no real TTY on stdin (piped through the GUI's
# progress dialog) — without it, any pacman prompt (conflicts, provider
# selection) can silently eat input and leave a partial/empty install that
# still exits 0. -K seeds a fresh keyring in the target instead of trusting
# whatever the live ISO happened to have cached.
pacstrap -K /mnt $BASE_PACKAGES --noconfirm

# Fail loud, not silent: a "successful" pacstrap that didn't actually lay
# down a base system used to sail through to a reboot prompt. Verify the
# files that must exist for *any* working install before going further.
for check in etc/os-release usr/bin/bash usr/lib/systemd/systemd; do
  [[ -e "/mnt/$check" ]] || error "pacstrap reported success but /mnt/$check is missing — the base system was not actually installed. Check the log above for pacman errors."
done
log "Verified base system is present (os-release, bash, systemd all found)."

# pacstrap only ever READS the live ISO's pacman.conf to fetch packages for
# /mnt — it never copies the file itself in. Without this, the install ends
# up with the pacman package's stock template (no [veilos] repo), so
# machina/glasspad/yay-bin would have no way to update or reinstall post-boot.
log "Copying live pacman.conf (with the veilos repo) into the install..."
cp /etc/pacman.conf /mnt/etc/pacman.conf
log "Copying ranked mirrorlist into the install..."
cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist

# -----------------------------------------------------------------------------
# 7. GENERATE FSTAB & SYSTEM CONFIGURATION
# -----------------------------------------------------------------------------
emit_progress "Generating fstab" 50
log "Writing /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

if [[ "$SWAP_TYPE" == "swapfile" ]]; then
  create_swapfile "$SWAP_SIZE_MB"
fi

# -----------------------------------------------------------------------------
# 7b. VEILOS BRANDING
# -----------------------------------------------------------------------------
emit_progress "Applying VeilOS branding" 52

# Onboard setup scripts (post-install AUR/dependency helpers for the Veil and
# Sway+Woven desktops) — ship on the live ISO, land in the target's PATH.
mkdir -p /mnt/usr/local/bin
for script in setup-sway-woven.sh setup-veil.sh; do
  src="/usr/lib/veilos/$script"
  if [[ -f "$src" ]]; then
    log "Installing $script to /usr/local/bin..."
    cp "$src" "/mnt/usr/local/bin/$script"
    chmod 755 "/mnt/usr/local/bin/$script"
  else
    warn "$src not found on the live ISO — skipping (won't be available in the installed system)."
  fi
done

# Real VeilOS os-release from the live ISO itself, not a guess.
if [[ -f /etc/os-release ]]; then
  log "Copying live ISO's /etc/os-release into the install..."
  cp /etc/os-release /mnt/etc/os-release
else
  warn "/etc/os-release missing on the live ISO (unexpected) — leaving pacstrap's stock Arch version in place."
fi

# fastfetch config — copy whatever's at /etc/fastfetch on the live ISO,
# whether that's a single config file or a directory of presets.
if [[ -e /etc/fastfetch ]]; then
  log "Copying /etc/fastfetch into the install..."
  cp -a /etc/fastfetch /mnt/etc/
else
  warn "/etc/fastfetch not found on the live ISO — skipping."
fi

# Guaranteed fallback: even with no live-ISO os-release, never let the
# install silently read back as stock Arch.
if ! grep -q '^ID=veilos' /mnt/etc/os-release 2>/dev/null; then
  log "No VeilOS os-release available — writing a minimal default."
  cat <<'EOF' > /mnt/etc/os-release
NAME="VeilOS"
PRETTY_NAME="VeilOS"
ID=veilos
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;147;112;219"
HOME_URL="https://github.com/TheHolyVeil"
EOF
fi

# /etc/issue and /etc/motd still say "Arch Linux" by default post-pacstrap.
log "Rebranding /etc/issue and /etc/motd..."
printf 'VeilOS \\r (\\l)\n' > /mnt/etc/issue
printf 'Welcome to VeilOS.\n' > /mnt/etc/motd

# Plymouth boot splash
if [[ "$PLYMOUTH_AVAILABLE" -eq 1 ]]; then
  log "Installing VeilOS Plymouth theme..."
  mkdir -p /mnt/usr/share/plymouth/themes/veilos
  cp -a "$PLYMOUTH_THEME_SRC"/. /mnt/usr/share/plymouth/themes/veilos/
  # Insert the plymouth hook right after udev in mkinitcpio's HOOKS array —
  # has to run before the theme can render anything at early boot.
  if grep -q '^HOOKS=.*\budev\b' /mnt/etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=/ s/\budev\b/udev plymouth/' /mnt/etc/mkinitcpio.conf
  else
    warn "Couldn't find 'udev' in mkinitcpio.conf's HOOKS array — add 'plymouth' to it manually."
  fi
  # -R sets the theme AND rebuilds the initramfs with it baked in.
  arch-chroot /mnt plymouth-set-default-theme -R veilos \
    || warn "plymouth-set-default-theme failed — boot splash may not appear, but this isn't fatal."
fi

emit_progress "Configuring system" 55
log "Setting timezone ($TIMEZONE) and locale ($LOCALE)..."
arch-chroot /mnt ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
arch-chroot /mnt hwclock --systohc

echo "$LOCALE UTF-8" > /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf

log "Setting keymap and hostname..."
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
echo "$HOSTNAME" > /mnt/etc/hostname

# Configure NetworkManager
arch-chroot /mnt systemctl enable NetworkManager

# -----------------------------------------------------------------------------
# 8. USER & PASSWORD CONFIGURATION
# -----------------------------------------------------------------------------
emit_progress "Configuring users" 60
log "Setting root password..."
echo "root:$ROOT_PASSWORD" | arch-chroot /mnt chpasswd

if [[ "$CREATE_USER" == "true" ]]; then
  log "Creating user account: $USERNAME..."
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"
  echo "$USERNAME:$USER_PASSWORD" | arch-chroot /mnt chpasswd

  if [[ "$SUDO_ENABLED" == "true" ]]; then
    log "Enabling sudo access for group wheel..."
    echo "%wheel ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/wheel
    chmod 0440 /mnt/etc/sudoers.d/wheel
  fi
fi

# Enable display manager if one was selected (auto default, or explicit choice)
if [[ -n "$DM_SERVICE" ]]; then
  log "Enabling login manager: $DM_SERVICE..."
  arch-chroot /mnt systemctl enable "$DM_SERVICE"
fi

if [[ "$LOGIN_MANAGER" == "custom" && -n "${LOGIN_MANAGER_CMD:-}" ]]; then
  emit_progress "Installing custom login manager" 63
  log "Running custom login manager command inside chroot: $LOGIN_MANAGER_CMD"
  arch-chroot /mnt bash -c "$LOGIN_MANAGER_CMD" \
    || error "Custom login manager command failed (exit $?). Check the log above — the command runs as root inside the new install's chroot, so it needs to be self-contained (install + enable its own systemd service)."
fi

if [[ "$LOGIN_MANAGER" == "velogin" ]]; then
  emit_progress "Installing VeilLogin" 63
  log "Installing VeilLogin..."
  arch-chroot /mnt bash -c "curl -fsSL https://raw.githubusercontent.com/TheHolyVeil/veilTDC/refs/heads/main/veil-login/dist/install.sh | sudo bash" \
    || error "VeilLogin install script failed (exit $?)."

  # The install script only PRINTS these as next steps for an interactive
  # user — it doesn't run them itself, so a hands-off install would silently
  # end up with no seatd, tty1's getty still fighting for the console, and
  # velogin.service never enabled. Do them explicitly here instead.
  if [[ "$CREATE_USER" == "true" ]]; then
    log "Adding $USERNAME to the seat group for seatd/VeilLogin..."
    arch-chroot /mnt usermod -aG seat "$USERNAME" \
      || warn "Could not add $USERNAME to the seat group — run 'usermod -aG seat $USERNAME' manually after first boot."
  fi
  log "Enabling seatd + velogin, disabling getty@tty1..."
  # NOTE: no --now here — there's no running systemd instance to talk to
  # inside a chroot, "enable" alone (symlinking the unit) is correct and is
  # all that's needed for it to start on the real first boot.
  arch-chroot /mnt systemctl enable seatd.service \
    || error "Could not enable seatd.service — is the seatd package actually installed? (check pacstrap log above)"
  arch-chroot /mnt systemctl disable getty@tty1.service
  arch-chroot /mnt systemctl enable velogin.service \
    || error "Could not enable velogin.service — check that the VeilLogin install script above actually placed its unit file."
fi

# -----------------------------------------------------------------------------
# 9. BOOTLOADER INSTALLATION
# -----------------------------------------------------------------------------
emit_progress "Installing bootloader" 65
log "Deploying $BOOTLOADER ($BOOT_MODE)..."

# "splash" only makes sense if a Plymouth theme actually got installed above —
# otherwise it just adds a blank-screen delay for nothing.
CMDLINE_EXTRA="rw quiet"
[[ "$PLYMOUTH_AVAILABLE" -eq 1 ]] && CMDLINE_EXTRA="rw quiet splash"

case "$BOOTLOADER" in
  grub)
    if [[ "$PLYMOUTH_AVAILABLE" -eq 1 ]]; then
      sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)"/\1\2 splash"/' /mnt/etc/default/grub
    fi
    if [[ "$BOOT_MODE" == "efi" ]]; then
      arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=VeilOS
      [[ -f /mnt/boot/EFI/VeilOS/grubx64.efi ]] || error "grub-install (EFI) did not produce grubx64.efi — check the log above."
    else
      arch-chroot /mnt grub-install --target=i386-pc "$DISK"
    fi
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    [[ -s /mnt/boot/grub/grub.cfg ]] || error "grub-mkconfig produced an empty grub.cfg."
    ;;

  limine)
    if [[ "$BOOT_MODE" == "efi" ]]; then
      [[ -f /mnt/usr/share/limine/BOOTX64.EFI ]] || error "limine package didn't install /usr/share/limine/BOOTX64.EFI — is 'limine' actually in the package list?"
      mkdir -p /mnt/boot/EFI/BOOT
      cp /mnt/usr/share/limine/BOOTX64.EFI /mnt/boot/EFI/BOOT/
      # Fallback path (\EFI\BOOT\BOOTX64.EFI) alone is unreliable on real
      # hardware once NVRAM gets touched by another OS installer — also
      # register a proper boot entry the same way the grub branch does.
      arch-chroot /mnt efibootmgr --create --disk "$DISK" --part 1 \
        --loader '\EFI\BOOT\BOOTX64.EFI' --label "VeilOS" 2>/dev/null \
        || warn "efibootmgr NVRAM entry failed — fallback path \\EFI\\BOOT\\BOOTX64.EFI should still boot on most firmware."
    else
      # CRITICAL: the MBR-embedded stage1/2 written by `limine bios-install`
      # below comes from the LIVE ISO's limine binary, and it must be the
      # EXACT SAME VERSION as limine-bios.sys or it rejects it outright —
      # printing "stage 3 file not found" even though the file is right
      # there, because a version mismatch fails validation silently rather
      # than reporting itself as a version error. Pulling limine-bios.sys
      # from the chroot's separately-pacstrapped limine package (which can
      # drift to a different version than the live ISO's) was exactly that
      # bug. Fix: source it from the SAME live-ISO limine install as the
      # binary actually doing bios-install, not from the target.
      [[ -f /usr/share/limine/limine-bios.sys ]] || error "limine-bios.sys not found on the LIVE ISO at /usr/share/limine/ — is 'limine' actually installed there (not just pacstrapped into the target)?"
      cp /usr/share/limine/limine-bios.sys /mnt/boot/limine-bios.sys
      log "Running Limine BIOS installation on device $DISK..."
      limine bios-install "$DISK"
    fi

    # Generate Limine configuration.
    # boot():/path is current Limine's path resolver ("the partition Limine
    # itself booted from") — boot:///path (triple-slash, no parens) is the
    # older/wrong syntax and fails to resolve, which is exactly why the
    # kernel showed up as "doesn't exist" despite being at the right path.
    # kernel_cmdline is likewise the current key name (plain "cmdline" is
    # silently ignored by newer Limine, not an error, just no cmdline set).
    cat <<EOF > /mnt/boot/limine.conf
timeout: 5

/VeilOS
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    kernel_cmdline: root=PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT") $CMDLINE_EXTRA
    module_path: boot():/initramfs-linux.img
EOF
    if [[ "$BOOT_MODE" == "efi" ]]; then
      [[ -f /mnt/boot/EFI/BOOT/BOOTX64.EFI ]] || error "Limine EFI install verification failed: BOOTX64.EFI missing from ESP."
    else
      [[ -f /mnt/boot/limine-bios.sys ]] || error "Limine BIOS install verification failed: limine-bios.sys missing from /boot."
    fi
    ;;

  systemd-boot)
    arch-chroot /mnt bootctl install
    [[ -f /mnt/boot/EFI/systemd/systemd-bootx64.efi ]] || error "bootctl install did not produce systemd-bootx64.efi — check the log above."

    # Configure loader and entry
    cat <<EOF > /mnt/boot/loader/loader.conf
default veilos.conf
timeout 4
console-mode max
EOF

    mkdir -p /mnt/boot/loader/entries
    cat <<EOF > /mnt/boot/loader/entries/veilos.conf
title   VeilOS
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT") $CMDLINE_EXTRA
EOF
    ;;
esac

# -----------------------------------------------------------------------------
# 10. CLEANUP & UNMOUNT
# -----------------------------------------------------------------------------
emit_progress "Finalizing installation" 90
log "Generating initramfs images..."
arch-chroot /mnt mkinitcpio -P

if [[ "$SWAP_TYPE" == "partition" ]]; then
  log "Deactivating swap partition before unmount..."
  swapoff "$PART_SWAP" 2>/dev/null || true
fi

log "Unmounting target partitions..."
# arch-chroot commonly leaves a stray dbus-daemon/gpg-agent running inside
# the chroot's mount namespace even after the chroot session itself exits
# (spawned by pacman-key/makepkg hooks) — that's the usual cause of "target
# is busy" here, not anything actually wrong with the install. Kill anything
# still holding /mnt open, then retry a few times before giving up.
unmount_ok=0
for attempt in 1 2 3 4 5; do
  if umount -R /mnt 2>/dev/null; then
    unmount_ok=1
    break
  fi
  command -v fuser &>/dev/null && { fuser -km /mnt 2>/dev/null || true; }
  sleep 1
done

if [[ "$unmount_ok" -eq 1 ]]; then
  MOUNTED=0
else
  # Everything that actually matters — partitioning, packages, bootloader,
  # users, fstab — is already fully written to disk at this point. A stuck
  # unmount only affects the live session's view of the disk, not the
  # install itself, so this is a warning, not a fatal error.
  warn "Could not cleanly unmount /mnt after several attempts — the install itself is already complete and should boot fine. You may need 'umount -R /mnt' manually (or just reboot) before reusing this live session for another install."
fi

# Config file holds plaintext root/user passwords — don't leave it lying around.
if command -v shred &>/dev/null; then
  shred -u "$CONFIG_FILE" 2>/dev/null || rm -f "$CONFIG_FILE"
else
  rm -f "$CONFIG_FILE"
fi

emit_progress "Installation complete" 100
log "VeilOS backend installation successfully finished."
