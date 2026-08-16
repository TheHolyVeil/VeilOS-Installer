# VeilOS Installer + Plymouth Theme

## What's here

- `installer.sh` — the YAD-based graphical wizard. Runs on the live ISO,
  collects disk/filesystem/bootloader/swap/desktop/login-manager choices,
  writes a config file, and hands off to the backend.
- `install-backend.sh` — does the actual work: partitioning, formatting,
  pacstrap, chroot config, bootloader install, branding, onboard tools.
  Root only, called by `installer.sh` via `sudo`.
- `plymouth-theme-veilos/` — the boot splash theme (`veilos.plymouth`,
  `background.png`, `logo.png`). Deep purple, matches the VeilOS palette.

## Live ISO requirements

The backend expects these to already exist **on the live ISO itself**
(not just in a repo somewhere) — it checks for each and degrades gracefully
(warns and skips) if one's missing, except where noted:

| Path on live ISO | Used for |
|---|---|
| `/usr/lib/veilos/plymouth/veilos/` | Plymouth theme (this bundle's `plymouth-theme-veilos/` folder, copied there) |
| `/usr/lib/veilos/setup-veil.sh` | Copied to `/usr/local/bin` on the install |
| `/usr/lib/veilos/setup-sway-woven.sh` | Copied to `/usr/local/bin` on the install |
| `/etc/os-release` | Copied verbatim into the install (must already say VeilOS) |
| `/etc/fastfetch` | Copied verbatim into the install |
| `/etc/pacman.conf` (with `[veilos]` repo entry) | **Required.** Used to fetch `machina`/`yay-bin`/`glasspad`, and copied into the install afterward so the finished system can still update from it |
| `limine` package installed live-side | **Required if BOOTLOADER=limine and BOOT_MODE=bios.** Must be present on the live ISO, not just pacstrapped into the target — `bios-install` runs from the live environment |

## Installing the Plymouth theme onto your ISO

Drop the whole `plymouth-theme-veilos/` folder into your archiso profile's
`airootfs` at:

```
airootfs/usr/lib/veilos/plymouth/veilos/
├── veilos.plymouth
├── background.png
└── logo.png
```

That's it — the backend detects it automatically, pulls in the `plymouth`
package, installs the theme, patches `mkinitcpio.conf`, and adds `splash`
to the kernel command line for whichever bootloader gets picked.

## What the backend does, roughly in order

1. Pre-flight checks (required tools present, disk is valid and not the live
   medium, `[veilos]` repo resolves, swap/login-manager config is valid)
2. Partition + format (GPT/UEFI or MBR/BIOS, FAT32 `/boot` either way, optional
   swap partition)
3. Mount, rank mirrors, `pacstrap` the base system + desktop + onboard tools
4. Copy `pacman.conf`, mirrorlist, and VeilOS branding into the install
5. System config (hostname, locale, timezone), users
6. Bootloader install (grub/limine/systemd-boot) + Plymouth if available
7. Unmount, done


