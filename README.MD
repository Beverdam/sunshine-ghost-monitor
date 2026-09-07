# CachyOS Sunshine Virtual Display

This folder contains `setup_virtual_display.sh`, a helper script for creating a forced Linux DRM/KMS display for Sunshine on CachyOS.

The goal is to let Sunshine keep capturing a display even when your physical monitor is off, without needing a hardware HDMI or DisplayPort dummy plug.

## Disclaimer

Use this at your own risk. This script changes initramfs and bootloader configuration, forces GPU display connectors on, and can make a physical monitor use a saved EDID instead of its own. Mistakes can cause a black screen, awkward display modes, Sunshine capturing the wrong output, or a system that needs bootloader/kernel parameter cleanup from a TTY or recovery environment.

Read the script, run `--dry-run` first, keep backups, and make sure you know how to undo the changes before using it on a machine you rely on.

## What It Does

The script:

- clones an EDID from any existing real monitor with a readable EDID;
- installs that EDID as `/usr/lib/firmware/edid/virtual-display.bin`;
- adds the EDID to initramfs with a mkinitcpio drop-in;
- adds kernel parameters that force a disconnected GPU connector on;
- regenerates the relevant boot entries where possible;
- provides commands to diagnose, show the active mapping, switch ports, uninstall, and check status.

It does not download a generic EDID. Cloning your real display is safer because it preserves the modes your monitor already supports.

The script is not tied to any monitor brand. It should work with any monitor that exposes a readable EDID through `/sys/class/drm`.

## Requirements

- CachyOS or another Arch-based system using `mkinitcpio` (not `dracut` — the script does not support it; check with `pacman -Qi mkinitcpio dracut 2>/dev/null | grep -E '^Name'`)
- Sunshine already installed
- At least one real monitor connected and awake during install
- At least one unused GPU connector, such as `HDMI-A-1`, `DP-1`, or `DP-3`
- Root privileges for install, switch, and uninstall operations

## Turning Off Or Unplugging The Real Monitor

`video=<connector>:e` forces the virtual connector enabled at the DRM level, which overrides hotplug-detect (HPD). This means the real monitor can be powered off, put to sleep, or physically unplugged after boot without affecting the virtual display — Sunshine keeps capturing the forced connector regardless of the real monitor's state.

This is confirmed reliable on `amdgpu` (open-source AMD driver). Proprietary `nvidia` has historically had flakier support for force-enabled connectors; if you're on nvidia, test this specific behavior before relying on it.

## Command Reference

```bash
sudo ./setup_virtual_display.sh --install
sudo ./setup_virtual_display.sh --switch-port DP-1
sudo ./setup_virtual_display.sh --uninstall
./setup_virtual_display.sh --diagnose
./setup_virtual_display.sh --current
./setup_virtual_display.sh --sunshine
./setup_virtual_display.sh --status
```

Options:

- `--edid PATH` uses an existing EDID binary instead of cloning a connected monitor.
- `--port NAME` picks the disconnected connector to force on.
- `--sunshine-version VER` skips Sunshine version detection and assumes `VER`, which decides whether the script tells you to use a connector name or a numeric `Display Id`.
- `--yes` accepts default answers, `--dry-run` shows changes without writing them.

Aliases:

- `--install` is the default when no mode is passed.
- `--change-port` is an alias for `--switch-port`.
- `--remove` is an alias for `--uninstall`.
- `--active` and `--mapped-port` are aliases for `--current`.
- `--sunshine-output`, `--sunshine-outputs`, and `--output-name` are aliases for `--sunshine`.

## Download Or Copy The Script

After downloading or copying `setup_virtual_display.sh`, make it executable before running it:

```bash
chmod +x setup_virtual_display.sh
```

Then inspect the available commands:

```bash
./setup_virtual_display.sh --help
```

## Quick Start

If you have not already done so, make the script executable:

```bash
chmod +x setup_virtual_display.sh
```

Inspect your connectors:

```bash
./setup_virtual_display.sh --diagnose
```

Example useful output:

```text
connector          status         edid-bytes   edid-path
DP-1               disconnected   0            /sys/class/drm/card1-DP-1/edid
DP-2               connected      256          /sys/class/drm/card1-DP-2/edid
DP-3               disconnected   0            /sys/class/drm/card1-DP-3/edid
HDMI-A-1           disconnected   0            /sys/class/drm/card1-HDMI-A-1/edid
```

In that example, `DP-2` is the real monitor to clone and `HDMI-A-1`, `DP-1`, or `DP-3` can be used as the virtual display target.

Preview the install:

```bash
sudo ./setup_virtual_display.sh --dry-run --edid /sys/class/drm/card1-DP-2/edid --port HDMI-A-1
```

Install for real:

```bash
sudo ./setup_virtual_display.sh --edid /sys/class/drm/card1-DP-2/edid --port HDMI-A-1
```

Reboot after the install.

## Interactive Install

You can also let the script prompt you:

```bash
sudo ./setup_virtual_display.sh
```

It will ask which connected monitor EDID to clone and which disconnected connector to force on.

## Switching The Virtual Port

If you originally mapped the virtual display to `HDMI-A-1` but later want to use `DP-1`, you do not need to clone the EDID again.

Preview:

```bash
sudo ./setup_virtual_display.sh --dry-run --switch-port DP-1
```

Apply:

```bash
sudo ./setup_virtual_display.sh --switch-port DP-1
```

Reboot after switching ports.

Do not switch the virtual display to your real connected monitor port. In the example above, avoid `DP-2` because that is the physical monitor being cloned.

## Uninstalling

Preview removal:

```bash
sudo ./setup_virtual_display.sh --dry-run --uninstall
```

Remove the setup:

```bash
sudo ./setup_virtual_display.sh --uninstall
```

Reboot after uninstalling.

## Status

Show the virtual display mapping active in the current boot:

```bash
./setup_virtual_display.sh --current
```

Equivalent aliases:

```bash
./setup_virtual_display.sh --active
./setup_virtual_display.sh --mapped-port
```

Example output:

```text
Active virtual display mapping from /proc/cmdline:
  HDMI-A-1 -> edid/virtual-display.bin (force-enabled: yes)
    connector status: /sys/class/drm/card1-HDMI-A-1=connected
```

Show the connector inventory, active boot mapping, installed EDID file, mkinitcpio drop-in, and managed bootloader entries:

```bash
./setup_virtual_display.sh --status
```

`--current` reads `/proc/cmdline`, so it reports what is active right now after the last boot. The managed bootloader entries shown by `--status` are the configuration that will be used on the next boot.

## Files Changed

The script may create or update:

```text
/usr/lib/firmware/edid/virtual-display.bin
/etc/mkinitcpio.conf.d/99-virtual-display-edid.conf
```

It may also update one of these bootloader configuration files:

```text
/etc/sdboot-manage.conf
/etc/default/limine
/etc/default/grub
/etc/kernel/cmdline
```

The script writes managed bootloader entries between:

```text
# BEGIN Sunshine virtual display EDID
# END Sunshine virtual display EDID
```

It also removes older one-line entries created by previous versions of this script.

## Backups

Before changing an existing config file, the script creates timestamped backups like:

```text
/etc/sdboot-manage.conf.bak.YYYYMMDD-HHMMSS
/etc/default/grub.bak.YYYYMMDD-HHMMSS
/etc/mkinitcpio.conf.d/99-virtual-display-edid.conf.bak.YYYYMMDD-HHMMSS
```

## What The Kernel Parameters Mean

For a target connector such as `HDMI-A-1`, the script installs parameters like:

```text
drm.edid_firmware=HDMI-A-1:edid/virtual-display.bin video=HDMI-A-1:e
```

Meaning:

- `drm.edid_firmware=...` tells Linux to use the saved EDID for that connector.
- `video=HDMI-A-1:e` forces that connector enabled even when no monitor is plugged in.

## Sunshine Configuration

After reboot, Sunshine should see the forced display.

Open the Sunshine Web UI, usually:

```text
https://localhost:47990
```

Go to:

```text
Configuration -> Audio/Video -> Display Id
```

Since Sunshine [v2026.906.222525](https://github.com/LizardByte/Sunshine/releases/tag/v2026.906.222525), Linux display selection accepts the DRM connector name directly, and that is the recommended value. Set `Display Id` to the connector this script forces on, for example:

```text
HDMI-A-1
```

That same release also changed how KMS numeric display indices are computed, so **numeric `Display Id` values from an older Sunshine may now point at a different monitor**. If you are upgrading, reselect your display by connector name. In logs or config files, this setting may still appear internally as `output_name`.

On Sunshine versions older than v2026.906.222525, connector names are not accepted and you must use Sunshine's own detected numeric display id instead — see [Older Sunshine versions: numeric display id](#older-sunshine-versions-numeric-display-id) below.

You do not have to work out which of the two applies: the script detects your Sunshine version and prints only the advice that matches it. Detection tries, in order, your package manager (`pacman`, `dpkg`, `rpm`, `flatpak`), Sunshine's own log lines, and finally `sunshine --version`. If none of those work, it asks you, or prints both variants when it cannot ask. To skip detection entirely:

```bash
./setup_virtual_display.sh --sunshine --sunshine-version 2026.906.222525
```

Use the helper mode to show the active DRM mapping and relevant Sunshine log lines:

```bash
./setup_virtual_display.sh --sunshine
```

Equivalent aliases:

```bash
./setup_virtual_display.sh --sunshine-output
./setup_virtual_display.sh --sunshine-outputs
./setup_virtual_display.sh --output-name
```

### Older Sunshine versions: numeric display id

On Sunshine releases before v2026.906.222525, `Display Id` does not accept connector names. If the helper shows a Sunshine line like:

```text
Detected display: HDMI-A-1 (id: 3)
```

set Sunshine's `Display Id` to:

```text
3
```

If Sunshine is using KMS, the relevant log format may look like this instead:

```text
-------- Start of KMS monitor list --------
Monitor 1 is DP-1: Example Monitor DP-1
Monitor 0 is DP-2: Example Monitor DP-2
--------- End of KMS monitor list ---------
```

In that case, set Sunshine's `Display Id` to the monitor number before `is`. For the forced `DP-1` display above, use:

```text
1
```

If Sunshine logs say:

```text
Couldn't find monitor [3]
```

then `3` is not valid for the current KMS monitor list. This is also the typical symptom after upgrading to v2026.906.222525 with an old numeric `Display Id`; switch to the connector name.

If the helper does not find display lines, start or restart Sunshine and run it again.

## What If You Plug A Real Monitor Into The Virtual Port?

If you plug a real monitor into the connector being forced by this setup, Linux will still apply the saved virtual EDID to that connector.

That means the real monitor may:

- appear with the cloned monitor's modes;
- be offered the wrong resolution or refresh rate;
- show a black screen if it rejects the forced mode;
- behave strangely with HDR or color capabilities;
- cause Sunshine to capture the wrong display.

This is usually not electrically dangerous, but it can be inconvenient. If you want to use that physical port normally again, switch the virtual display to another disconnected port or uninstall the setup.

## Troubleshooting

If install says no connected monitor EDID was found, run:

```bash
./setup_virtual_display.sh --diagnose
```

At least one connected display should show `edid-bytes` of `128` or higher.

If your monitor is on but EDID bytes are still `0`:

- wake the monitor and make sure it is not asleep;
- check that the cable is connected to the active GPU;
- avoid docking paths or adapters that hide EDID data;
- rerun diagnose;
- pass the EDID path manually if diagnose shows one with bytes.

Manual EDID example:

```bash
sudo ./setup_virtual_display.sh --edid /sys/class/drm/card1-DP-2/edid --port HDMI-A-1
```

If the virtual display does not appear after install:

- confirm you rebooted;
- run `./setup_virtual_display.sh --current`;
- run `./setup_virtual_display.sh --status`;
- run `./setup_virtual_display.sh --sunshine`;
- check that the bootloader entry includes both `drm.edid_firmware=...` and `video=...:e`;
- check that the chosen target connector is disconnected before boot;
- try switching to another disconnected connector.

If `edid-decode` is installed on your system, the script runs it against the cloned EDID and prints any warnings it reports, but does not fail because of them. `edid-decode` flags spec nonconformities that are common even in real, working, shipping monitor EDIDs, so its output here is advisory only — the actual validity gate is the byte-size check (at least 128 bytes, a multiple of 128).

## Common Commands

```bash
./setup_virtual_display.sh --diagnose
./setup_virtual_display.sh --current
./setup_virtual_display.sh --active
./setup_virtual_display.sh --sunshine
./setup_virtual_display.sh --status
sudo ./setup_virtual_display.sh --dry-run --edid /sys/class/drm/card1-DP-2/edid --port HDMI-A-1
sudo ./setup_virtual_display.sh --edid /sys/class/drm/card1-DP-2/edid --port HDMI-A-1
sudo ./setup_virtual_display.sh --dry-run --switch-port DP-1
sudo ./setup_virtual_display.sh --switch-port DP-1
sudo ./setup_virtual_display.sh --dry-run --uninstall
sudo ./setup_virtual_display.sh --uninstall
```
