#!/usr/bin/env bash
# install-backend.sh — VeilOS installer backend
# Reads /tmp/veilos-install.conf and executes the actual installation
# Usage: install-backend.sh [--debug]

DEBUG_MODE=false
if [[ "$1" == "--debug" ]]; then
  DEBUG_MODE=true
  echo "DEBUG MODE ENABLED - No destructive operations will be performed"
fi

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

CONFIG_FILE="/tmp/veilos-install.conf"
INSTALL_LOG="/var/log/veilos-install.log"

log() { echo -e "${GREEN}[veilos]${RESET} $*"; }
warn() { echo -e "${YELLOW}[warn]${RESET} $*" >&2; }
error() {
  echo -e "${RED}[error]${RESET} $*" >&2
  exit 1
}

progress_step() {
  local name="$1" pct="$2"
  echo "VEILOS_PROGRESS:${name}:${pct}"
}

[[ -f "$CONFIG_FILE" ]] || error "Config not found: $CONFIG_FILE"
source "$CONFIG_FILE"

[[ -n "$DISK" ]] || error "DISK not set"
[[ -n "$FILESYSTEM" ]] || error "FILESYSTEM not set"
[[ -n "$BOOTLOADER" ]] || error "BOOTLOADER not set"
[[ -n "$BOOT_MODE" ]] || BOOT_MODE=$([[ -d /sys/firmware/efi ]] && echo efi || echo bios)
[[ "$BOOTLOADER" != "systemd-boot" || "$BOOT_MODE" == "efi" ]] ||
  error "systemd-boot requires UEFI firmware (detected: $BOOT_MODE)"
[[ -n "$DESKTOP" ]] || error "DESKTOP not set"
[[ -n "$LOCALE" ]] || LOCALE="en_US.UTF-8"
[[ -n "$KEYMAP" ]] || KEYMAP="us"
[[ -n "$TIMEZONE" ]] || TIMEZONE="Etc/UTC"
[[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || error "Invalid timezone: $TIMEZONE"
[[ -n "$HOSTNAME" ]] || HOSTNAME="veilos"
[[ -n "$MIRROR_COUNTRY" ]] || MIRROR_COUNTRY="automatic"

log "Starting VeilOS installation..."
log "Target: $DISK | $FILESYSTEM | $BOOTLOADER | $DESKTOP"

# =============================================================================
# MIRROR
# =============================================================================

configure_mirrors() {
  progress_step "Configuring mirrors" 5
  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would configure mirrors ($MIRROR_COUNTRY)"
    return 0
  fi

  if [[ "$MIRROR_COUNTRY" == "automatic" ]]; then
    if command -v reflector &>/dev/null; then
      reflector --latest 20 --sort rate --save /etc/pacman.d/mirrorlist || warn "reflector failed"
    fi
  elif command -v reflector &>/dev/null; then
    reflector --country "$MIRROR_COUNTRY" --latest 10 --sort rate --save /etc/pacman.d/mirrorlist ||
      warn "reflector country $MIRROR_COUNTRY failed"
  fi
}

# =============================================================================
# PARTITIONING
# =============================================================================

partition_disk() {
  progress_step "Partitioning disk" 10
  log "Partitioning $DISK..."

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would partition $DISK"
    BOOT_TYPE=$([[ -d /sys/firmware/efi ]] && echo efi || echo bios)
    return 0
  fi

  umount -R /mnt 2>/dev/null || true

  if [[ -d /sys/firmware/efi ]]; then
    log "EFI mode"
    BOOT_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 100%
    BOOT_TYPE="efi"
  else
    log "BIOS mode"
    BOOT_PARTITION="${DISK}1"
    ROOT_PARTITION="${DISK}2"
    parted -s "$DISK" mklabel msdos
    parted -s "$DISK" mkpart primary ext4 1MiB 1025MiB
    parted -s "$DISK" set 1 boot on
    parted -s "$DISK" mkpart primary ext4 1025MiB 100%
    BOOT_TYPE="bios"
  fi

  partprobe "$DISK" || true
  sleep 2
  log "Partitions: $BOOT_PARTITION (boot), $ROOT_PARTITION (root)"
}

format_partitions() {
  progress_step "Formatting partitions" 20
  log "Formatting ($FILESYSTEM)..."

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would format partitions"
    return 0
  fi

  if [[ "$BOOT_TYPE" == "efi" ]]; then
    mkfs.fat -F32 "$BOOT_PARTITION" -n BOOT
  else
    mkfs.ext4 -F "$BOOT_PARTITION" -L BOOT
  fi

  case "$FILESYSTEM" in
  btrfs) mkfs.btrfs -f "$ROOT_PARTITION" -L root ;;
  ext4) mkfs.ext4 -F "$ROOT_PARTITION" -L root ;;
  xfs) mkfs.xfs -f "$ROOT_PARTITION" -L root ;;
  *) error "Unknown filesystem: $FILESYSTEM" ;;
  esac
}

mount_partitions() {
  progress_step "Mounting partitions" 25
  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would mount partitions"
    return 0
  fi

  mkdir -p /mnt /mnt/boot
  mount "$ROOT_PARTITION" /mnt
  mount "$BOOT_PARTITION" /mnt/boot
}

run_pacstrap() {
  progress_step "Installing base system" 35
  log "Running pacstrap..."

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would run pacstrap"
    return 0
  fi

  local packages=(
    base linux linux-firmware grub efibootmgr limine systemd-boot
    networkmanager vim nano zsh git sudo openssh fastfetch kbd
  )

  pacstrap -K /mnt "${packages[@]}"
}

generate_fstab() {
  progress_step "Generating fstab" 50
  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would generate fstab"
    return 0
  fi
  genfstab -U /mnt >>/mnt/etc/fstab
}

chroot_setup() {
  progress_step "Configuring system" 55
  log "Chroot setup..."

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would configure chroot"
    return 0
  fi

  if [[ -d /run/archiso/bootmnt/arch/boot/archiso_root/etc ]]; then
    cp -r /run/archiso/bootmnt/arch/boot/archiso_root/etc/* /mnt/etc/ 2>/dev/null ||
      warn "Could not copy archiso configs"
  fi

  echo "$HOSTNAME" >/mnt/etc/hostname

  if grep -q "^#*$LOCALE" /mnt/etc/locale.gen; then
    sed -i "s/^#$LOCALE/$LOCALE/" /mnt/etc/locale.gen
  elif ! grep -q "^$LOCALE" /mnt/etc/locale.gen; then
    echo "$LOCALE UTF-8" >>/mnt/etc/locale.gen
  fi
  echo "LANG=$LOCALE" >/mnt/etc/locale.conf
  arch-chroot /mnt locale-gen

  arch-chroot /mnt localectl set-keymap "$KEYMAP" 2>/dev/null ||
    echo "KEYMAP=$KEYMAP" >/mnt/etc/vconsole.conf

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
  arch-chroot /mnt hwclock --systohc 2>/dev/null || true

  mkdir -p /mnt/var/log

  if [[ -f /tmp/veilinit-splash ]]; then
    install -Dm755 /tmp/veilinit-splash /mnt/usr/local/bin/veilinit-splash
  fi

  log "Chroot environment prepared"
}

install_bootloader() {
  progress_step "Installing bootloader" 65
  log "Bootloader: $BOOTLOADER"

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would install $BOOTLOADER"
    return 0
  fi

  cat >/tmp/chroot_bootloader.sh <<'CHROOTEOF'
#!/usr/bin/env bash
set -e
BOOTLOADER="$1"
BOOT_TYPE="$2"
DISK="$3"

case "$BOOTLOADER" in
grub)
  if [[ "$BOOT_TYPE" == "efi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=VeilOS
  else
    grub-install --target=i386-pc "$DISK"
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
  ;;
systemd-boot)
  if [[ "$BOOT_TYPE" != "efi" ]]; then
    echo "systemd-boot requires UEFI firmware"
    exit 1
  fi
  bootctl install
  mkdir -p /boot/loader/entries
  cat >/boot/loader/entries/veilos.conf <<EOF
title VeilOS
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=LABEL=root rw
EOF
  ;;
limine)
  mkdir -p /boot/limine /boot/EFI/BOOT
  if [[ -f /usr/share/limine/BOOTX64.EFI ]]; then
    cp /usr/share/limine/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI
  fi
  if [[ -f /usr/share/limine/limine-bios.sys ]]; then
    cp /usr/share/limine/limine-bios.sys /boot/limine/
  fi
  cat >/boot/limine/limine.cfg <<EOF
timeout: 5
default_entry: 1

/veilos
    protocol: linux
    path: boot():/vmlinuz-linux
    cmdline: root=LABEL=root rw quiet
    module_path: boot():/initramfs-linux.img
EOF
  if [[ "$BOOT_TYPE" == "efi" ]]; then
    limine limine-install "$DISK" 2>/dev/null || true
  else
    limine limine-install "$DISK" 2>/dev/null || true
  fi
  ;;
*)
  echo "Unknown bootloader: $BOOTLOADER"
  exit 1
  ;;
esac
CHROOTEOF

  chmod +x /tmp/chroot_bootloader.sh
  arch-chroot /mnt /tmp/chroot_bootloader.sh "$BOOTLOADER" "$BOOT_TYPE" "$DISK"
  rm -f /tmp/chroot_bootloader.sh
}

setup_users() {
  progress_step "Creating users" 75
  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would configure users"
    return 0
  fi

  cat >/tmp/chroot_users.sh <<'CHROOTEOF'
#!/usr/bin/env bash
set -e
ROOT_PASSWD="$1"
CREATE_USER="$2"
USERNAME="$3"
USER_PASSWD="$4"
SUDO_ENABLED="$5"

echo "root:$ROOT_PASSWD" | chpasswd

if [[ "$CREATE_USER" == "true" ]]; then
  useradd -m -s /usr/bin/zsh "$USERNAME"
  echo "$USERNAME:$USER_PASSWD" | chpasswd
  if [[ "$SUDO_ENABLED" == "true" ]]; then
    usermod -aG wheel "$USERNAME"
    echo "%wheel ALL=(ALL:ALL) ALL" >/etc/sudoers.d/wheel
    chmod 440 /etc/sudoers.d/wheel
  fi
fi
CHROOTEOF

  chmod +x /tmp/chroot_users.sh
  arch-chroot /mnt /tmp/chroot_users.sh "$ROOT_PASSWORD" "$CREATE_USER" "$USERNAME" "$USER_PASSWORD" "$SUDO_ENABLED"
  rm -f /tmp/chroot_users.sh
}

setup_desktop() {
  progress_step "Installing desktop" 85
  log "Desktop: $DESKTOP"

  if [[ "$DEBUG_MODE" == true ]]; then
    log "[DEBUG] Would install desktop $DESKTOP"
    return 0
  fi

  case "$DESKTOP" in
  veil) log "Install veil from AUR after reboot: yay -S veil" ;;
  sway) log "Install sway/woven from AUR after reboot" ;;
  plasma) arch-chroot /mnt pacman -S --noconfirm plasma plasma-wayland-session ;;
  gnome) arch-chroot /mnt pacman -S --noconfirm gnome ;;
  xfce) arch-chroot /mnt pacman -S --noconfirm xfce4 xfce4-terminal ;;
  i3) arch-chroot /mnt pacman -S --noconfirm i3-wm i3status i3lock ;;
  *) warn "Unknown desktop: $DESKTOP" ;;
  esac
}

main() {
  if [[ "$DEBUG_MODE" == true ]]; then
    BOOT_TYPE=$([[ -d /sys/firmware/efi ]] && echo efi || echo bios)
    log "====== DEBUG: INSTALLATION PLAN ======"
    log "Disk: $DISK ($BOOT_MODE)"
    log "  Bootloader: $BOOTLOADER"
    log "  ${DISK}1 — boot"
    log "  ${DISK}2 — root ($FILESYSTEM)"
    log "Locale: $LOCALE | Keymap: $KEYMAP | TZ: $TIMEZONE"
    log "Mirror: $MIRROR_COUNTRY | Bootloader: $BOOTLOADER"
    log "Desktop: $DESKTOP | Hostname: $HOSTNAME"
    log "====== END DEBUG ======"
    return 0
  fi

  configure_mirrors
  progress_step "Starting" 2
  partition_disk
  format_partitions
  mount_partitions
  run_pacstrap
  generate_fstab
  chroot_setup
  install_bootloader
  setup_users
  setup_desktop

  progress_step "Finishing" 95
  cp /tmp/veilos-install.log /mnt/var/log/veilos-install.log 2>/dev/null || true
  umount -R /mnt 2>/dev/null || warn "Unmount failed"

  progress_step "Complete" 100
  log "============================================"
  log "VeilOS installation complete!"
  log "============================================"
}

main "$@"
