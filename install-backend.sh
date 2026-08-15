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
  parted -s "$DISK" mkpart primary ext4 1MiB 1025MiB
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
  log "Formatting boot partition ($PART_BOOT) as ext4..."
  mkfs.ext4 -F -L "BOOT" "$PART_BOOT"
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

# Desktop Environment Package Mapping
DESKTOP_PKGS=""
case "$DESKTOP" in
  plasma) DESKTOP_PKGS="plasma-meta kde-applications-meta sddm" ;;
  gnome)  DESKTOP_PKGS="gnome gnome-extra gdm" ;;
  xfce)   DESKTOP_PKGS="xfce4 xfce4-goodies lightdm lightdm-gtk-greeter" ;;
  i3)     DESKTOP_PKGS="i3-wm i3status i3lock lightdm lightdm-gtk-greeter" ;;
  sway)   DESKTOP_PKGS="sway swaylock swayidle foot" ;;
  veil)   DESKTOP_PKGS="foot" ;; # AUR/custom dependencies handled in post-step
  *)      DESKTOP_PKGS="" ;;
esac

BASE_PACKAGES="base linux linux-firmware sudo networkmanager $BOOTLOADER_PKG $DESKTOP_PKGS"

emit_progress "Installing base packages (pacstrap)" 40
log "Executing pacstrap with packages: $BASE_PACKAGES"
pacstrap /mnt $BASE_PACKAGES

# -----------------------------------------------------------------------------
# 7. GENERATE FSTAB & SYSTEM CONFIGURATION
# -----------------------------------------------------------------------------
emit_progress "Generating fstab" 50
log "Writing /etc/fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

if [[ "$SWAP_TYPE" == "swapfile" ]]; then
  create_swapfile "$SWAP_SIZE_MB"
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

# Enable display manager if configured
case "$DESKTOP" in
  plasma) arch-chroot /mnt systemctl enable sddm ;;
  gnome)  arch-chroot /mnt systemctl enable gdm ;;
  xfce|i3) arch-chroot /mnt systemctl enable lightdm ;;
esac

# -----------------------------------------------------------------------------
# 9. BOOTLOADER INSTALLATION
# -----------------------------------------------------------------------------
emit_progress "Installing bootloader" 65
log "Deploying $BOOTLOADER ($BOOT_MODE)..."

case "$BOOTLOADER" in
  grub)
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
      # CRITICAL: limine's BIOS stage-2 loader reads /limine-bios.sys from the
      # root of the boot partition at boot time. bios-install alone only
      # embeds stage-1/2 in the MBR gap — without this file present the
      # system fails to boot after install. This was previously missing.
      [[ -f /mnt/usr/share/limine/limine-bios.sys ]] || error "limine package didn't install /usr/share/limine/limine-bios.sys — is 'limine' actually in the package list?"
      cp /mnt/usr/share/limine/limine-bios.sys /mnt/boot/limine-bios.sys
      log "Running Limine BIOS installation on device $DISK..."
      limine bios-install "$DISK"
    fi

    # Generate Limine configuration
    cat <<EOF > /mnt/boot/limine.conf
timeout: 5

/VeilOS
    protocol: linux
    kernel_path: boot:///vmlinuz-linux
    cmdline: root=PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT") rw quiet
    module_path: boot:///initramfs-linux.img
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
options root=PARTUUID=$(blkid -s PARTUUID -o value "$PART_ROOT") rw quiet
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
umount -R /mnt
MOUNTED=0

# Config file holds plaintext root/user passwords — don't leave it lying around.
if command -v shred &>/dev/null; then
  shred -u "$CONFIG_FILE" 2>/dev/null || rm -f "$CONFIG_FILE"
else
  rm -f "$CONFIG_FILE"
fi

emit_progress "Installation complete" 100
log "VeilOS backend installation successfully finished."
