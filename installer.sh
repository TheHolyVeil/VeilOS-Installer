#!/usr/bin/env bash
# veilos-installer — VeilOS YAD installer
# Sequential wizard (Wayland-safe — no X11 notebook/plug mode)
# Installed to /usr/local/bin/veilos-installer on the live ISO.
# Assets live at /usr/share/veilos/installer/

set -euo pipefail

ASSETS_DIR="/usr/share/veilos/installer"
LOGO_WELCOME="$ASSETS_DIR/logo-welcome.png"
LOGO_SUMMARY="$ASSETS_DIR/logo-summary.png"
BACKEND="/usr/lib/veilos/install-backend.sh"
CONFIG_FILE="/tmp/veilos-install.conf"

WIN_W=720
WIN_H=540
WIZARD_TOTAL=9
WIZARD_STEP=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

declare -A TR
declare -a DISK_ROWS=()
declare -a TZ_OPTIONS=()
declare -a KEYMAP_OPTIONS=()
declare -a MIRROR_OPTIONS=()
BOOTLOADER_OPTIONS=""

BOOT_MODE=""
DISK_NAME=""
DISK=""
FILESYSTEM=""
BOOTLOADER=""
LOCALE=""
KEYMAP=""
TIMEZONE=""
DESKTOP=""
HOSTNAME=""
ROOT_PASSWORD=""
CREATE_USER=""
USERNAME=""
USER_PASSWORD=""
SUDO_ENABLED=""
MIRROR_COUNTRY=""
DETECTED_LOCALE="en_US.UTF-8"
DETECTED_KEYMAP="us"
RAM_MB=0
SWAP_TYPE=""
SWAP_SIZE_MB=""
LOGIN_MANAGER=""
LOGIN_MANAGER_CMD=""

log()   { printf "${GREEN}[veilos]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[warn]${RESET} %s\n" "$*"; }
error() {
  printf "${RED}[error]${RESET} %s\n" "$*" >&2
  exit 1
}

# Always append --center at the end so action flags (--error, --progress, etc.) come first
yad_dialog() { yad "$@" --center; }

wizard_title() {
  printf "VeilOS Installer — %s (%s/%s)" "$1" "$2" "${WIZARD_TOTAL}"
}

step_banner() {
  local name="$1" num="$2"
  printf "<span color='#888888'>Step %s/%s: %s</span>" "${num}" "${WIZARD_TOTAL}" "${name}"
}

wizard_nav() {
  # 0=next  1=back  2=cancel
  local rc=$1
  case "$rc" in
  0) WIZARD_STEP=$((WIZARD_STEP + 1)) ;;
  1) WIZARD_STEP=$((WIZARD_STEP > 1 ? WIZARD_STEP - 1 : 1)) ;;
  *) exit 1 ;;
  esac
}

# =============================================================================
# DETECTION & DATA BUILDERS
# =============================================================================

normalize_timezone() {
  local tz="$1"
  case "$tz" in
  UTC | GMT | UCT) printf "Etc/UTC" ;;
  *) printf "%s" "$tz" ;;
  esac
}

auto_detect_timezone() {
  local detected=""
  if command -v timedatectl &>/dev/null; then
    detected=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [[ -z "$detected" ]] && command -v curl &>/dev/null; then
    detected=$(curl -fsS --max-time 5 https://ipapi.co/timezone/ 2>/dev/null || true)
  fi
  TIMEZONE="$(normalize_timezone "${detected:-Etc/UTC}")"
  log "Timezone: $TIMEZONE"
}

auto_detect_locale() {
  local sys
  sys=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | cut -d_ -f1 | cut -d. -f1)
  case "$sys" in
  de) DETECTED_LOCALE="de_DE.UTF-8" ;;
  fr) DETECTED_LOCALE="fr_FR.UTF-8" ;;
  es) DETECTED_LOCALE="es_ES.UTF-8" ;;
  ja) DETECTED_LOCALE="ja_JP.UTF-8" ;;
  pt) DETECTED_LOCALE="pt_BR.UTF-8" ;;
  *)  DETECTED_LOCALE="en_US.UTF-8" ;;
  esac
  log "Locale: $DETECTED_LOCALE"
}

auto_detect_keymap() {
  if command -v localectl &>/dev/null; then
    DETECTED_KEYMAP=$(localectl status 2>/dev/null | awk -F: '/VC Keymap/ {gsub(/^ +| +$/,"",$2); print $2}')
  fi
  DETECTED_KEYMAP="${DETECTED_KEYMAP:-us}"
  log "Keymap: $DETECTED_KEYMAP"
}

auto_detect_ram() {
  RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  log "Detected RAM: ${RAM_MB}MiB"
}

network_online() {
  ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null
}

live_boot_disks() {
  # Resolve the physical disk(s) backing the live medium so we never offer
  # to let the user format the drive they booted from.
  local -a srcs=() out=() src disk
  srcs+=("$(findmnt -no SOURCE / 2>/dev/null || true)")
  for mp in /run/archiso/bootmnt /run/miso/bootmnt; do
    [[ -d "$mp" ]] && srcs+=("$(findmnt -no SOURCE "$mp" 2>/dev/null || true)")
  done
  for src in "${srcs[@]}"; do
    [[ -n "$src" ]] || continue
    disk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
    [[ -n "$disk" ]] && out+=("$disk")
  done
  printf '%s\n' "${out[@]}"
}

build_disk_rows() {
  DISK_ROWS=()
  local line
  local -a live_disks
  readarray -t live_disks < <(live_boot_disks)

  while IFS= read -r line; do
    local NAME="" SIZE="" MODEL="" SERIAL="" TRAN="" TYPE=""

    # Safely parse key="value" output without eval
    while [[ "$line" =~ ([A-Z]+)=\"([^\"]*)\" ]]; do
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      case "$key" in
        NAME) NAME="$val" ;;
        SIZE) SIZE="$val" ;;
        MODEL) MODEL="$val" ;;
        SERIAL) SERIAL="$val" ;;
        TRAN) TRAN="$val" ;;
        TYPE) TYPE="$val" ;;
      esac
      line="${line#*"${BASH_REMATCH[0]}"}"
    done

    [[ "$TYPE" == "disk" ]] || continue
    [[ -n "$NAME" ]] || continue
    [[ "$NAME" == zram* || "$NAME" == ram* || "$NAME" == fd* ]] && continue
    printf '%s\n' "${live_disks[@]}" | grep -qx "$NAME" && continue

    DISK_ROWS+=("$NAME" "$SIZE" "${MODEL:-unknown}" "${SERIAL:-—}" "${TRAN:-—}")
  done < <(lsblk -d -n -P -o NAME,SIZE,MODEL,SERIAL,TRAN,TYPE -e7 2>/dev/null)

  # Fallback if parsable output unavailable (older lsblk)
  if [[ ${#DISK_ROWS[@]} -eq 0 ]]; then
    local name size model serial tran dtype
    while read -r name size model serial tran dtype; do
      [[ "$dtype" == "disk" ]] || continue
      [[ -n "$name" ]] || continue
      [[ "$name" == zram* || "$name" == ram* || "$name" == fd* ]] && continue
      printf '%s\n' "${live_disks[@]}" | grep -qx "$name" && continue
      DISK_ROWS+=("$name" "$size" "${model:-unknown}" "${serial:-—}" "${tran:-—}")
    done < <(lsblk -d -n -o NAME,SIZE,MODEL,SERIAL,TRAN,TYPE -e7 2>/dev/null)
  fi

  [[ ${#DISK_ROWS[@]} -gt 0 ]] || error "No disks found"
}

scan_disk_warnings() {
  local disk="/dev/$1"
  local -a warns=()
  local part fstype label

  while read -r part fstype label; do
    [[ "$part" == "$1" ]] && continue
    case "$fstype" in
    ntfs | exfat) warns+=("Windows partition: /dev/$part") ;;
    vfat)
      if [[ "$label" == *EFI* || "$label" == *efi* ]]; then
        warns+=("EFI System Partition: /dev/$part")
      else
        warns+=("FAT partition: /dev/$part")
      fi
      ;;
    ext4 | btrfs | xfs) warns+=("Linux $fstype: /dev/$part") ;;
    esac
  done < <(lsblk -n -o NAME,FSTYPE,PARTLABEL "$disk" 2>/dev/null)

  if command -v blkid &>/dev/null; then
    while read -r _ type _; do
      [[ "$type" == "gpt" || "$type" == "dos" ]] && warns+=("Partition table ($type) on $disk")
    done < <(blkid -p -o export "$disk" 2>/dev/null | awk -F= '/^PTTYPE=/{print $2}')
  fi

  if [[ ${#warns[@]} -gt 0 ]]; then
    printf '%s\n' "${warns[@]}"
  else
    printf "No existing OS partitions detected (disk may still contain data).\n"
  fi
}

build_timezone_options() {
  TZ_OPTIONS=()
  local tz
  while IFS= read -r tz; do
    [[ -n "$tz" ]] || continue
    if [[ "$tz" == "$TIMEZONE" ]]; then
      TZ_OPTIONS+=("^$tz")
    else
      TZ_OPTIONS+=("$tz")
    fi
  done < <(find /usr/share/zoneinfo -type f \
    ! -path '*/posix/*' ! -path '*/right/*' \
    | sed 's|^/usr/share/zoneinfo/||' | LC_ALL=C sort)
}

build_keymap_options() {
  local -a common=(us de fr es uk br-abnt2 jp dvorak)
  local km seen="$DETECTED_KEYMAP"
  KEYMAP_OPTIONS=()

  if [[ -n "$seen" ]]; then
    KEYMAP_OPTIONS+=("^$seen")
  fi

  for km in "${common[@]}"; do
    [[ "$km" == "$seen" ]] && continue
    KEYMAP_OPTIONS+=("$km")
  done

  [[ ${#KEYMAP_OPTIONS[@]} -gt 0 ]] || KEYMAP_OPTIONS=(^us)
}

build_mirror_options() {
  MIRROR_OPTIONS=("^automatic")
  local c
  for c in US GB DE FR CA AU JP NL SE CH; do
    MIRROR_OPTIONS+=("$c")
  done
}

boot_mode() {
  if [[ -d /sys/firmware/efi ]]; then
    printf "efi"
  else
    printf "bios"
  fi
}

boot_mode_label() {
  if [[ "$BOOT_MODE" == "efi" ]]; then
    printf "UEFI"
  else
    printf "BIOS (legacy)"
  fi
}

boot_mode_banner() {
  if [[ "$BOOT_MODE" == "efi" ]]; then
    printf "<span color='#00e5c8'><b>Boot mode: UEFI</b></span> — GPT partition table, FAT32 EFI System Partition"
  else
    printf "<span color='#c792ea'><b>Boot mode: BIOS (legacy)</b></span> — MBR partition table, ext4 /boot partition"
  fi
}

build_bootloader_options() {
  if [[ "$BOOT_MODE" == "efi" ]]; then
    BOOTLOADER_OPTIONS="^grub!systemd-boot!limine"
  else
    BOOTLOADER_OPTIONS="^grub!limine"
  fi
}

validate_bootloader() {
  if [[ "$BOOT_MODE" == "bios" && "$BOOTLOADER" == "systemd-boot" ]]; then
    yad_dialog --error --title="VeilOS Installer" --width=480 \
      --text="<b>systemd-boot requires UEFI firmware.</b>\n\nThis system booted in BIOS mode. Choose GRUB or Limine."
    return 1
  fi
  return 0
}

partition_plan_text() {
  local disk="$1" fs="$2" mode
  mode=$(boot_mode)
  local plan="" root_num=2 swap_line=""
  if [[ "${SWAP_TYPE:-none}" == "partition" ]]; then
    root_num=3
    swap_line="  <tt>${disk}2</tt> — $((SWAP_SIZE_MB))MiB — swap\n"
  fi
  if [[ "$mode" == "efi" ]]; then
    plan+="<b>Partition plan (UEFI)</b>\n"
    plan+="  <tt>${disk}1</tt> — 512 MiB — FAT32 — <tt>/boot</tt> (ESP)\n"
    plan+="${swap_line}"
    plan+="  <tt>${disk}${root_num}</tt> — remainder — <tt>${fs}</tt> — <tt>/</tt> (root)\n"
  else
    plan+="<b>Partition plan (BIOS)</b>\n"
    plan+="  <tt>${disk}1</tt> — 1 GiB — ext4 — <tt>/boot</tt>\n"
    plan+="${swap_line}"
    plan+="  <tt>${disk}${root_num}</tt> — remainder — <tt>${fs}</tt> — <tt>/</tt> (root)\n"
  fi
  if [[ "${SWAP_TYPE:-none}" == "swapfile" ]]; then
    plan+="  <tt>/swapfile</tt> — $((SWAP_SIZE_MB))MiB — on root\n"
  fi
  plan+="\n<span color='#FF8C00'><b>All data on ${disk} will be destroyed.</b></span>"
  printf "%b" "$plan"
}

# =============================================================================
# TRANSLATIONS
# =============================================================================

load_translations() {
  local lang="$1"
  TR[welcome]="Welcome to VeilOS"
  TR[welcome_desc]="Arch-based Linux with a Wayland compositor.\n\n<span color='#FF8C00'><b>Warning: selected disk will be erased.</b></span>"
  TR[disk_select]="Select target disk"
  TR[install]="Install"
  TR[cancel]="Cancel"
  TR[running]="Installing VeilOS..."
  TR[complete]="Installation complete!"
  TR[reboot]="Reboot now?"

  case "$lang" in
  de) TR[welcome]="Willkommen bei VeilOS" ;;
  fr) TR[welcome]="Bienvenue sur VeilOS" ;;
  es) TR[welcome]="Bienvenido a VeilOS" ;;
  ja) TR[welcome]="VeilOSへようこそ" ;;
  pt) TR[welcome]="Bem-vindo ao VeilOS" ;;
  esac
}

# =============================================================================
# REQUIREMENTS (pre-wizard)
# =============================================================================

check_requirements() {
  log "Checking requirements..."
  if ! network_online; then
    yad_dialog --warning --title="VeilOS Installer" --width=560 \
      --button="Continue:0" --button="Cancel:1" \
      --text="<b>No network detected</b>\n\nConnect in the Network step or continue offline (may fail)."
    [[ $? -eq 0 ]] || exit 1
  fi

  local ram_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  if [[ $ram_gb -lt 4 ]]; then
    yad_dialog --warning --title="VeilOS Installer" --width=560 \
      --text="<b>Low memory (${ram_gb}GB)</b>\n\n4GB+ recommended."
  fi

  local max_disk_bytes
  max_disk_bytes=$(lsblk -d -n -b -o SIZE,TYPE,NAME -e7 2>/dev/null | awk '$2=="disk" && $3 !~ /^(zram|ram|fd)/ {print $1}' | sort -n | tail -n 1)

  local max_disk_gb=$(( ${max_disk_bytes:-0} / 1024 / 1024 / 1024 ))
  [[ $max_disk_gb -ge 20 ]] || error "No target drive with at least 20GB space found (largest drive: ${max_disk_gb}GB)"

  [[ -f "$BACKEND" ]] || error "Backend not found: $BACKEND"
}

# =============================================================================
# SEQUENTIAL WIZARD (Wayland-compatible)
# =============================================================================

run_sequential_wizard() {
  WIZARD_STEP=1
  local rc line

  while [[ $WIZARD_STEP -le $WIZARD_TOTAL ]]; do
    case $WIZARD_STEP in
    1)
      local welcome_img=()
      [[ -f "$LOGO_WELCOME" ]] && welcome_img=(--image="$LOGO_WELCOME")
      yad_dialog --title="$(wizard_title Welcome 1)" \
        --width=$WIN_W --height=$WIN_H \
        "${welcome_img[@]}" \
        --text="$(step_banner Welcome 1)\n\n$(boot_mode_banner)\n\n<b>${TR[welcome]}</b>\n\n${TR[welcome_desc]}" \
        --button="Next:0" --button="Cancel:1"
      [[ $? -eq 0 ]] || exit 1
      WIZARD_STEP=2
      ;;
    2)
      line=$(yad_dialog --title="$(wizard_title Disk 2)" \
        --width=$WIN_W --height=$WIN_H \
        --list \
        --text="$(step_banner Disk 2)\n\n$(boot_mode_banner)\n\n${TR[disk_select]}\n\n<span color='red'><b>All data on the chosen disk will be erased.</b></span>" \
        --column="Disk" --column="Size" --column="Model" --column="Serial" --column="Bus" \
        --button="Next:0" --button="Back:1" --button="Cancel:2" \
        "${DISK_ROWS[@]}")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { [[ $rc -eq 0 ]] && continue; wizard_nav "$rc"; continue; }
      DISK_NAME=$(printf "%s" "$line" | cut -d'|' -f1)
      DISK="/dev/$DISK_NAME"
      wizard_nav 0
      ;;
    3)
      local boot_note=""
      [[ "$BOOT_MODE" == "bios" ]] &&
        boot_note="\n\n<span color='#888888'>systemd-boot is UEFI-only and hidden on BIOS systems.</span>"
      local swap_size_cb
      swap_size_cb="^2 GiB!Same as RAM (${RAM_MB}MiB)!Half RAM!2x RAM (hibernate)!Custom"
      line=$(yad_dialog --title="$(wizard_title Storage 3)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field="$(step_banner Storage 3):lbl" "" \
        --field=":lbl" "$(boot_mode_banner)${boot_note}" \
        --field="Root filesystem:cb" "^btrfs!ext4!xfs" \
        --field="Bootloader:cb" "$BOOTLOADER_OPTIONS" \
        --field="Swap:cb" "^none!swapfile!partition" \
        --field="Swap size:cb" "$swap_size_cb" \
        --field="Custom swap size (e.g. 4G, 512M — only used if Swap size=Custom):" "" \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }

      readarray -t storage <<< "$line"
      FILESYSTEM="${storage[2]:-btrfs}"
      BOOTLOADER="${storage[3]:-grub}"
      validate_bootloader || continue

      SWAP_TYPE="${storage[4]:-none}"
      local swap_preset="${storage[5]:-2 GiB}"
      local swap_custom="${storage[6]:-}"

      if [[ "$SWAP_TYPE" == "none" ]]; then
        SWAP_SIZE_MB=0
      else
        case "$swap_preset" in
          "2 GiB")               SWAP_SIZE_MB=2048 ;;
          "Same as RAM"*)        SWAP_SIZE_MB=$RAM_MB ;;
          "Half RAM")            SWAP_SIZE_MB=$((RAM_MB / 2)) ;;
          "2x RAM (hibernate)")  SWAP_SIZE_MB=$((RAM_MB * 2)) ;;
          Custom)
            if [[ "$swap_custom" =~ ^([0-9]+)[Gg]$ ]]; then
              SWAP_SIZE_MB=$(( ${BASH_REMATCH[1]} * 1024 ))
            elif [[ "$swap_custom" =~ ^([0-9]+)[Mm]?$ ]]; then
              SWAP_SIZE_MB="${BASH_REMATCH[1]}"
            else
              yad_dialog --error --title="VeilOS Installer" --width=480 \
                --text="Custom swap size must look like <tt>4G</tt> or <tt>512M</tt>."
              continue
            fi
            ;;
          *) SWAP_SIZE_MB=2048 ;;
        esac
        [[ "$SWAP_SIZE_MB" -gt 0 ]] || { yad_dialog --error --title="VeilOS Installer" --width=480 --text="Swap size must be greater than 0."; continue; }
      fi
      wizard_nav 0
      ;;
    4)
      local tz_cb km_cb
      tz_cb=$(IFS='!'; echo "${TZ_OPTIONS[*]}")
      km_cb=$(IFS='!'; echo "${KEYMAP_OPTIONS[*]}")
      line=$(yad_dialog --title="$(wizard_title Locale 4)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field="$(step_banner Locale 4):lbl" "" \
        --field="System locale:cb" "^${DETECTED_LOCALE}!en_US.UTF-8!de_DE.UTF-8!fr_FR.UTF-8!es_ES.UTF-8!ja_JP.UTF-8!pt_BR.UTF-8" \
        --field="Console keymap:cb" "$km_cb" \
        --field="Timezone:cb" "$tz_cb" \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }

      readarray -t locale <<< "$line"
      LOCALE="${locale[1]:-$DETECTED_LOCALE}"
      KEYMAP="${locale[2]:-$DETECTED_KEYMAP}"
      TIMEZONE="${locale[3]:-$TIMEZONE}"
      wizard_nav 0
      ;;
    5)
      line=$(yad_dialog --title="$(wizard_title Desktop 5)" \
        --width=$WIN_W --height=$WIN_H \
        --list --radiolist \
        --text="$(step_banner Desktop 5)" \
        --column=Pick --column=Desktop --column=Notes \
        --button="Next:0" --button="Back:1" --button="Cancel:2" \
        TRUE  veil   "VeilOS compositor (AUR)" \
        FALSE sway   "Sway + Woven (AUR)" \
        FALSE plasma "KDE Plasma" \
        FALSE gnome  "GNOME" \
        FALSE xfce   "XFCE" \
        FALSE i3     "i3")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }
      # FIX: Fetch index -f2 (Desktop Name) instead of -f1 (Radio selection TRUE/FALSE)
      DESKTOP=$(printf "%s" "$line" | cut -d'|' -f2)

      local lm_line
      lm_line=$(yad_dialog --title="$(wizard_title Desktop 5)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field=":lbl" "Login manager for $DESKTOP" \
        --field="Login manager:cb" "^auto (desktop default)!sddm!gdm!lightdm!velogin!none!custom" \
        --field=":lbl" "velogin installs TheHolyVeil/veilTDC's VeilLogin automatically. custom runs your own command below." \
        --field="Custom install command (runs inside the chroot as root — only used if Login manager=custom):" "" \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$lm_line" ]] || { wizard_nav "$rc"; continue; }
      readarray -t lm <<< "$lm_line"
      LOGIN_MANAGER="${lm[1]:-auto (desktop default)}"
      LOGIN_MANAGER_CMD="${lm[3]:-}"
      if [[ "$LOGIN_MANAGER" == "custom" && -z "$LOGIN_MANAGER_CMD" ]]; then
        yad_dialog --error --title="VeilOS Installer" --width=480 \
          --text="Login manager is set to custom but no install command was given."
        continue
      fi
      wizard_nav 0
      ;;
    6)
      line=$(yad_dialog --title="$(wizard_title Users 6)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field="$(step_banner Users 6):lbl" "" \
        --field="Hostname" "veilos" \
        --field="Root password:hd" "" \
        --field="Confirm root password:hd" "" \
        --field="Create user account:chk" TRUE \
        --field="Username" "user" \
        --field="User password (blank = same as root):hd" "" \
        --field="User has sudo:chk" TRUE \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }

      readarray -t users <<< "$line"
      HOSTNAME="${users[1]:-veilos}"
      ROOT_PASSWORD="${users[2]}"
      local root_confirm="${users[3]}"
      CREATE_USER="${users[4]:-FALSE}"
      USERNAME="${users[5]:-user}"
      USER_PASSWORD="${users[6]}"
      SUDO_ENABLED="${users[7]:-TRUE}"
      [[ -n "$ROOT_PASSWORD" ]] || { yad_dialog --error --title="VeilOS Installer" --text="Root password is required."; continue; }
      [[ "$ROOT_PASSWORD" == "$root_confirm" ]] || { yad_dialog --error --title="VeilOS Installer" --text="Root passwords do not match."; continue; }
      if [[ "$CREATE_USER" == "TRUE" ]]; then
        CREATE_USER="true"
        [[ -n "$USERNAME" ]] || USERNAME="user"
        [[ -z "$USER_PASSWORD" ]] && USER_PASSWORD="$ROOT_PASSWORD"
        [[ "$SUDO_ENABLED" == "TRUE" ]] && SUDO_ENABLED="true" || SUDO_ENABLED="false"
      else
        CREATE_USER="false"
        USERNAME=""
        USER_PASSWORD=""
        SUDO_ENABLED="false"
      fi
      wizard_nav 0
      ;;
    7)
      local net_status
      if network_online; then
        net_status="<span color='#00e5c8'><b>Online</b></span> — ready for pacstrap"
      else
        net_status="<span color='#c792ea'><b>Offline</b></span> — configure before installing"
      fi
      line=$(yad_dialog --title="$(wizard_title Network 7)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field="$(step_banner Network 7):lbl" "" \
        --field="Status:lbl" "$net_status" \
        --field="Open network manager (nmtui) now:chk" FALSE \
        --field=":lbl" "Tip: <tt>nmtui</tt> or <tt>nmcli</tt> from a terminal also works." \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 ]] || { wizard_nav "$rc"; continue; }

      readarray -t net <<< "$line"
      if [[ "${net[2]:-FALSE}" == "TRUE" ]]; then
        launch_nmtui
      fi
      wizard_nav 0
      ;;
    8)
      local mir_cb
      mir_cb=$(IFS='!'; echo "${MIRROR_OPTIONS[*]}")
      line=$(yad_dialog --title="$(wizard_title Mirror 8)" \
        --width=$WIN_W --height=$WIN_H \
        --form --separator=$'\n' \
        --field="$(step_banner Mirror 8):lbl" "" \
        --field="Mirror country:cb" "$mir_cb" \
        --field=":lbl" "Automatic uses reflector to pick the fastest mirror." \
        --button="Next:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }

      readarray -t mirror <<< "$line"
      MIRROR_COUNTRY="${mirror[1]:-automatic}"
      wizard_nav 0
      ;;
    9)
      if [[ "${SWAP_TYPE:-none}" == "partition" ]]; then
        local disk_bytes disk_mb
        disk_bytes=$(lsblk -b -d -n -o SIZE "$DISK" 2>/dev/null || echo 0)
        disk_mb=$((disk_bytes / 1024 / 1024))
        if (( disk_mb > 0 && SWAP_SIZE_MB + 15360 > disk_mb )); then
          yad_dialog --error --title="VeilOS Installer" --width=520 \
            --text="Requested swap (${SWAP_SIZE_MB}MiB) leaves less than 15GiB for root on a ${disk_mb}MiB disk.\n\nGo back and shrink the swap size or pick a swapfile instead."
          WIZARD_STEP=3
          continue
        fi
      fi
      local summary_img=() plan
      [[ -f "$LOGO_SUMMARY" ]] && summary_img=(--image="$LOGO_SUMMARY")
      plan=$(partition_plan_text "$DISK" "$FILESYSTEM")
      line=$(yad_dialog --title="$(wizard_title Summary 9)" \
        --width=$WIN_W --height=$WIN_H \
        "${summary_img[@]}" \
        --form --separator=$'\n' \
        --field="$(step_banner Summary 9):lbl" "" \
        --field=":lbl" "$plan" \
        --field="Disk <tt>${DISK_NAME}</tt> — type name to confirm:txt" "" \
        --button="Install:0" --button="Back:1" --button="Cancel:2")
      rc=$?
      [[ $rc -eq 0 && -n "$line" ]] || { wizard_nav "$rc"; continue; }

      readarray -t summary <<< "$line"
      local disk_confirm="${summary[2]:-}"
      [[ "$disk_confirm" == "$DISK_NAME" ]] || {
        yad_dialog --error --title="VeilOS Installer" --width=480 --text="Type <tt>${DISK_NAME}</tt> exactly to confirm."
        continue
      }
      [[ -f "/usr/share/zoneinfo/$TIMEZONE" ]] || error "Invalid timezone: $TIMEZONE"
      WIZARD_STEP=$((WIZARD_STEP + 1))
      ;;
    esac
  done

  show_final_confirmation
}

launch_nmtui() {
  if ! command -v nmtui &>/dev/null; then
    warn "nmtui not installed"
    return
  fi
  for term in kitty foot alacritty xterm; do
    if command -v "$term" &>/dev/null; then
      case "$term" in
      kitty) kitty --hold nmtui ;;
      foot)  foot nmtui ;;
      *)     "$term" -e nmtui ;;
      esac
      return
    fi
  done
  warn "No terminal found to run nmtui"
}

show_final_confirmation() {
  local os_warn plan confirm_text
  os_warn=$(scan_disk_warnings "$DISK_NAME")
  plan=$(partition_plan_text "$DISK" "$FILESYSTEM")

  confirm_text="<b>Final confirmation</b>\n\n${plan}\n\n<b>Existing partitions on ${DISK}:</b>\n"
  while IFS= read -r w; do
    confirm_text+="  • $w\n"
  done <<<"$os_warn"
  confirm_text+="\n<b>Settings</b>\n"
  confirm_text+="  Boot mode: <tt>$(boot_mode_label)</tt>\n"
  confirm_text+="  Locale: <tt>$LOCALE</tt>  Keymap: <tt>$KEYMAP</tt>\n"
  confirm_text+="  Timezone: <tt>$TIMEZONE</tt>  Mirror: <tt>$MIRROR_COUNTRY</tt>\n"
  confirm_text+="  Bootloader: <tt>$BOOTLOADER</tt>  Desktop: <tt>$DESKTOP</tt>\n"
  confirm_text+="  Login manager: <tt>${LOGIN_MANAGER:-auto}</tt>\n"
  confirm_text+="  Swap: <tt>${SWAP_TYPE:-none}</tt>"
  [[ "${SWAP_TYPE:-none}" != "none" ]] && confirm_text+="  (${SWAP_SIZE_MB}MiB)"
  confirm_text+="\n  Hostname: <tt>$HOSTNAME</tt>"

  yad_dialog --title="VeilOS Installer" --width=$WIN_W --height=$WIN_H \
    --text="$confirm_text" \
    --button="Proceed:0" --button="Cancel:1"
  [[ $? -eq 0 ]] || exit 1

  log "Disk: $DISK | FS: $FILESYSTEM | TZ: $TIMEZONE | Keymap: $KEYMAP"
}

write_config() {
  rm -f "$CONFIG_FILE"

  # IMPORTANT: the backend `source`s this file as root. Interpolating values
  # straight into double quotes let a password/hostname containing $(...) ,
  # backticks, or a stray " break out and run as root when sourced. %q quotes
  # every value so it's always treated as a literal string.
  (
    umask 077
    {
      printf 'DISK=%q\n' "$DISK"
      printf 'FILESYSTEM=%q\n' "$FILESYSTEM"
      printf 'BOOTLOADER=%q\n' "$BOOTLOADER"
      printf 'BOOT_MODE=%q\n' "$BOOT_MODE"
      printf 'LOCALE=%q\n' "$LOCALE"
      printf 'KEYMAP=%q\n' "$KEYMAP"
      printf 'TIMEZONE=%q\n' "$TIMEZONE"
      printf 'MIRROR_COUNTRY=%q\n' "$MIRROR_COUNTRY"
      printf 'HOSTNAME=%q\n' "$HOSTNAME"
      printf 'ROOT_PASSWORD=%q\n' "$ROOT_PASSWORD"
      printf 'CREATE_USER=%q\n' "$CREATE_USER"
      printf 'USERNAME=%q\n' "$USERNAME"
      printf 'USER_PASSWORD=%q\n' "$USER_PASSWORD"
      printf 'SUDO_ENABLED=%q\n' "$SUDO_ENABLED"
      printf 'DESKTOP=%q\n' "$DESKTOP"
      printf 'SWAP_TYPE=%q\n' "$SWAP_TYPE"
      printf 'SWAP_SIZE_MB=%q\n' "$SWAP_SIZE_MB"
      printf 'LOGIN_MANAGER=%q\n' "$LOGIN_MANAGER"
      printf 'LOGIN_MANAGER_CMD=%q\n' "$LOGIN_MANAGER_CMD"
    } >"$CONFIG_FILE"
  )
  log "Config written to $CONFIG_FILE"
}

run_installation() {
  local logfile="/tmp/veilos-install.log"
  local exitcode_file="/tmp/veilos-install.exitcode"
  local install_status=0

  : >"$logfile"
  rm -f "$exitcode_file"

  # NOTE: exit status of `cmd | tee | yad --progress` is yad's exit status
  # (the last stage of the pipe), NOT the backend's — a failed partition step
  # or pacstrap error used to get reported as a successful install. The
  # backend now writes its real exit code to $exitcode_file via a trap; that
  # file is the source of truth, this pipeline's own $? is not.
  while IFS= read -r line; do
    if [[ "$line" =~ VEILOS_PROGRESS:([^:]+):([0-9]+) ]]; then
      echo "${BASH_REMATCH[2]}"
      echo "# ${BASH_REMATCH[1]}"
    fi
  done < <(sudo bash "$BACKEND" 2>&1 | tee "$logfile") | yad_dialog --progress \
    --title="VeilOS Installer" \
    --auto-close --no-escape \
    --width=600 --height=150 \
    --value=0 \
    --text="${TR[running]}"

  if [[ -f "$exitcode_file" ]]; then
    install_status=$(<"$exitcode_file")
  else
    # Backend crashed before it could even set the trap (e.g. sudo denied) —
    # treat missing sentinel as failure rather than assuming success.
    install_status=1
  fi

  if command -v shred &>/dev/null; then
    shred -u "$CONFIG_FILE" 2>/dev/null || rm -f "$CONFIG_FILE"
  else
    rm -f "$CONFIG_FILE"
  fi

  if [[ "$install_status" -ne 0 ]]; then
    yad_dialog --error --title="VeilOS Installer" --width=560 \
      --text="Installation failed (exit ${install_status}).\n\nLog: <tt>$logfile</tt>"
    exit 1
  fi

  yad_dialog --question --title="VeilOS Installer" --width=520 \
    --text="<b>${TR[complete]}</b>\n\n${TR[reboot]}" && sudo reboot
}

main() {
  command -v yad &>/dev/null || error "yad is required"
  check_requirements
  BOOT_MODE=$(boot_mode)
  log "Firmware boot mode: $(boot_mode_label)"
  auto_detect_timezone
  auto_detect_locale
  auto_detect_keymap
  auto_detect_ram
  load_translations "$(printf "%s" "$DETECTED_LOCALE" | cut -d_ -f1)"

  build_disk_rows
  build_bootloader_options
  build_timezone_options
  build_keymap_options
  build_mirror_options

  run_sequential_wizard
  write_config
  run_installation
}

main "$@"
