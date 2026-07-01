#!/usr/bin/env bash
set -Eeuo pipefail

EDID_PATH="/usr/lib/firmware/edid/virtual-display.bin"
MKINITCPIO_DROPIN="/etc/mkinitcpio.conf.d/99-virtual-display-edid.conf"
FIRMWARE_RELATIVE_PATH="edid/virtual-display.bin"
MANAGED_BEGIN="# BEGIN Sunshine virtual display EDID"
MANAGED_END="# END Sunshine virtual display EDID"

DRY_RUN=0
ASSUME_YES=0
SOURCE_EDID=""
TARGET_PORT=""
MODE="install"
MODE_SET=0
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<USAGE
Usage: sudo ./setup_virtual_display.sh [mode] [options]

Creates a forced DRM/KMS display for Sunshine by cloning an existing monitor EDID.

Warning:
  Use at your own risk. This script changes initramfs/bootloader configuration
  and forces GPU display connectors on. Run --dry-run first and know how to
  undo the changes before using it on a machine you rely on.

Modes:
  --install             Install or reinstall the virtual display setup (default)
  --switch-port NAME    Keep the EDID, but remap the virtual display to another disconnected port
  --uninstall           Remove the EDID, mkinitcpio drop-in, and bootloader kernel parameters
  --diagnose            Print DRM connector and EDID details, then exit
  --current             Show the virtual display mapping active in this boot, then exit
  --sunshine            Show Sunshine Display Id hints from recent service logs, then exit
  --status              Show installed files and managed bootloader entries, then exit

Options:
  --edid PATH     Use an existing EDID binary instead of selecting a connected monitor
  --port NAME     Use this disconnected connector, for example HDMI-A-1 or DP-2
  --yes           Accept the default choices when a prompt is needed
  --dry-run       Show what would change without writing files or running generators
  -h, --help      Show this help

Notes:
  - Run this while the monitor you want to clone is connected and awake.
  - This script does not download generic EDIDs; cloned monitor EDIDs are safer.
  - After reboot, set Sunshine's Linux Display Id from Sunshine's own detected display logs.
USAGE
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

set_mode() {
  local requested="$1"

  if (( MODE_SET )) && [[ "$MODE" != "$requested" ]]; then
    die "Choose only one mode. Already selected --$MODE, then got --$requested."
  fi

  MODE="$requested"
  MODE_SET=1
}

run() {
  if (( DRY_RUN )); then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

write_file() {
  local path="$1"
  local mode="$2"
  local content="$3"

  if (( DRY_RUN )); then
    log "[dry-run] write $path"
    printf '%s\n' "$content"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  install -Dm"$mode" "$tmp" "$path"
  rm -f "$tmp"
}

backup_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0

  local backup="${path}.bak.${TIMESTAMP}"
  run cp -a "$path" "$backup"
  log "Backed up $path to $backup"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

edid_size() {
  local file="$1"
  if [[ -f "$file" ]]; then
    wc -c < "$file" 2>/dev/null | tr -d '[:space:]'
  else
    printf '0\n'
  fi
}

validate_edid() {
  local file="$1"
  [[ -f "$file" ]] || die "EDID file does not exist: $file"

  local size
  size="$(edid_size "$file")"
  [[ "$size" =~ ^[0-9]+$ ]] || die "Could not determine EDID size: $file"
  (( size >= 128 )) || die "EDID is too small (${size} bytes): $file"
  (( size % 128 == 0 )) || die "EDID size should be a multiple of 128 bytes (${size} bytes): $file"

  if command -v edid-decode >/dev/null 2>&1; then
    if ! edid-decode "$file" >/dev/null; then
      log "Warning: edid-decode reported issues with $file (continuing; size checks already passed)."
    fi
  fi
}

connector_name_from_dir() {
  local dir_name="$1"
  printf '%s\n' "${dir_name#card*-}"
}

list_connected_edids() {
  local status_file dir port size
  shopt -s nullglob
  for status_file in /sys/class/drm/*/status; do
    [[ "$(cat "$status_file")" == "connected" ]] || continue
    dir="$(dirname "$status_file")"
    size="$(edid_size "$dir/edid")"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size >= 128 )) || continue
    port="$(connector_name_from_dir "$(basename "$dir")")"
    printf '%s\t%s\n' "$port" "$dir/edid"
  done
  shopt -u nullglob
}

list_any_nonempty_edids() {
  local status_file dir port status size
  shopt -s nullglob
  for status_file in /sys/class/drm/*/status; do
    dir="$(dirname "$status_file")"
    port="$(connector_name_from_dir "$(basename "$dir")")"
    status="$(cat "$status_file")"
    size="$(edid_size "$dir/edid")"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    (( size >= 128 )) || continue
    printf '%s\t%s\t%s\t%s\n' "$port" "$status" "$size" "$dir/edid"
  done
  shopt -u nullglob
}

list_disconnected_ports() {
  local status_file dir port
  shopt -s nullglob
  for status_file in /sys/class/drm/*/status; do
    [[ "$(cat "$status_file")" == "disconnected" ]] || continue
    dir="$(dirname "$status_file")"
    port="$(connector_name_from_dir "$(basename "$dir")")"
    printf '%s\n' "$port"
  done
  shopt -u nullglob
}

diagnose_drm() {
  local status_file dir port status size found=0

  log "DRM connector inventory:"
  printf '%-18s %-14s %-12s %s\n' "connector" "status" "edid-bytes" "edid-path"
  printf '%-18s %-14s %-12s %s\n' "---------" "------" "----------" "---------"

  shopt -s nullglob
  for status_file in /sys/class/drm/*/status; do
    found=1
    dir="$(dirname "$status_file")"
    port="$(connector_name_from_dir "$(basename "$dir")")"
    status="$(cat "$status_file")"
    size="$(edid_size "$dir/edid")"
    printf '%-18s %-14s %-12s %s\n' "$port" "$status" "$size" "$dir/edid"
  done
  shopt -u nullglob

  if (( ! found )); then
    log "No DRM connector status files were found under /sys/class/drm."
  fi

  log
  log "For cloning, at least one connected display should show edid-bytes >= 128."
  log "If your monitor is on but all EDIDs are 0 bytes, wake the display, check the active GPU/cable/dock path, then rerun this."
}

connector_status_summary() {
  local port="$1"
  local matches=()
  local status_file status summaries=()

  shopt -s nullglob
  matches=(/sys/class/drm/card*-"$port"/status)
  shopt -u nullglob

  if (( ${#matches[@]} == 0 )); then
    printf 'not found under /sys/class/drm'
    return
  fi

  for status_file in "${matches[@]}"; do
    status="$(cat "$status_file")"
    summaries+=("$(dirname "$status_file")=$status")
  done

  local IFS=', '
  printf '%s' "${summaries[*]}"
}

show_current_mapping() {
  local cmdline words word port found=0
  local mapped_ports=()
  local force_ports=()

  log "Active virtual display mapping from /proc/cmdline:"

  if [[ ! -r /proc/cmdline ]]; then
    log "  /proc/cmdline is not readable on this system."
    return
  fi

  cmdline="$(cat /proc/cmdline)"
  read -r -a words <<< "$cmdline"

  for word in "${words[@]}"; do
    if [[ "$word" == drm.edid_firmware=*":$FIRMWARE_RELATIVE_PATH" ]]; then
      port="${word#drm.edid_firmware=}"
      port="${port%%:*}"
      mapped_ports+=("$port")
      found=1
    fi

    if [[ "$word" =~ ^video=([^:[:space:]]+):e$ ]]; then
      force_ports+=("${BASH_REMATCH[1]}")
    fi
  done

  if (( ! found )); then
    log "  none found"
    log "  This boot is not currently using $FIRMWARE_RELATIVE_PATH."
    return
  fi

  for port in "${mapped_ports[@]}"; do
    if port_in_list "$port" "${force_ports[@]}"; then
      log "  $port -> $FIRMWARE_RELATIVE_PATH (force-enabled: yes)"
    else
      log "  $port -> $FIRMWARE_RELATIVE_PATH (force-enabled: no; missing video=${port}:e)"
    fi
    log "    connector status: $(connector_status_summary "$port")"
  done
}

print_matching_sunshine_logs() {
  local label="$1"
  shift
  local lines=()

  log "$label"
  if ! command -v journalctl >/dev/null 2>&1; then
    log "  journalctl is not available on this system."
    return 1
  fi

  mapfile -t lines < <("$@" 2>/dev/null | grep -Ei 'detected display|display.*id|id.*display|output_name|output name|monitor [0-9]+ is|couldn.*find monitor|adapter|encoder|monitor|kms|drm' | tail -n 100 || true)

  if (( ${#lines[@]} == 0 )); then
    log "  no matching Sunshine display/output lines found"
    return 1
  fi

  printf '%s\n' "${lines[@]}" | sed 's/^/  /'
  return 0
}

show_sunshine_hints() {
  log "Sunshine Display Id helper"
  log
  show_current_mapping
  log

  log "Sunshine Web UI path:"
  log "  Configuration -> Audio/Video -> Display Id"
  log
  log "On Linux, set Display Id to Sunshine's detected display id, not necessarily the DRM connector name."
  log "Sunshine's config/logs may still refer to this setting internally as output_name."
  log "When Sunshine is using KMS, prefer lines like: Monitor 1 is DP-1."
  log "In that example, DP-1's Display Id is 1. If logs say Couldn't find monitor [3], then 3 is wrong for the current monitor list."
  log
  log "Looking for display/output hints in Sunshine logs from this boot:"

  if ! command -v journalctl >/dev/null 2>&1; then
    log "  journalctl is not available on this system."
    return
  fi

  local found=0
  if print_matching_sunshine_logs "User service logs: journalctl --user -u sunshine -b" journalctl --user -u sunshine -b --no-pager; then
    found=1
  fi
  log
  if print_matching_sunshine_logs "System service logs: journalctl -u sunshine -b" journalctl -u sunshine -b --no-pager; then
    found=1
  fi

  log
  if (( ! found )); then
    log "No Sunshine display lines were found. Start or restart Sunshine, then run this again."
    log "You can also inspect manually:"
    log "  journalctl --user -u sunshine -b"
    log "  journalctl -u sunshine -b"
  else
    log "Use the display id shown by Sunshine for the forced connector in Display Id."
  fi
}

choose_index() {
  local max_index="$1"
  local prompt="$2"
  local choice

  if (( ASSUME_YES )); then
    printf '0\n'
    return
  fi

  while true; do
    read -r -p "$prompt [0]: " choice
    choice="${choice:-0}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= max_index )); then
      printf '%s\n' "$choice"
      return
    fi
    log "Please choose a number from 0 to $max_index."
  done
}

select_source_edid() {
  if [[ -n "$SOURCE_EDID" ]]; then
    validate_edid "$SOURCE_EDID"
    return
  fi

  mapfile -t connected < <(list_connected_edids)
  if (( ${#connected[@]} == 0 )); then
    mapfile -t any_edids < <(list_any_nonempty_edids)
    if (( ${#any_edids[@]} > 0 )); then
      log "No connector reported both connected and non-empty EDID, but these EDID files are readable:"
      local j any_port any_status any_size any_path
      for j in "${!any_edids[@]}"; do
        any_port="${any_edids[$j]%%$'\t'*}"
        any_status="${any_edids[$j]#*$'\t'}"
        any_status="${any_status%%$'\t'*}"
        any_size="${any_edids[$j]#*$'\t'*$'\t'}"
        any_size="${any_size%%$'\t'*}"
        any_path="${any_edids[$j]##*$'\t'}"
        log "  [$j] $any_port status=$any_status bytes=$any_size ($any_path)"
      done

      local any_choice
      any_choice="$(choose_index "$((${#any_edids[@]} - 1))" "Clone which EDID?")"
      SOURCE_EDID="${any_edids[$any_choice]##*$'\t'}"
      validate_edid "$SOURCE_EDID"
      return
    fi

    diagnose_drm
    die "No connected monitor EDID found. Turn your monitor on, or pass --edid /path/to/file.bin."
  fi

  log "Connected monitor EDIDs:"
  local i port edid
  for i in "${!connected[@]}"; do
    port="${connected[$i]%%$'\t'*}"
    edid="${connected[$i]#*$'\t'}"
    log "  [$i] $port ($edid)"
  done

  local choice
  choice="$(choose_index "$((${#connected[@]} - 1))" "Clone which monitor EDID?")"
  SOURCE_EDID="${connected[$choice]#*$'\t'}"
  validate_edid "$SOURCE_EDID"
}

select_target_port() {
  if [[ -n "$TARGET_PORT" ]]; then
    local matches=()
    local status_file status
    local found_disconnected=0

    shopt -s nullglob
    matches=(/sys/class/drm/card*-"$TARGET_PORT"/status)
    shopt -u nullglob

    if (( ${#matches[@]} > 0 )); then
      for status_file in "${matches[@]}"; do
        status="$(cat "$status_file")"
        [[ "$status" == "disconnected" ]] && found_disconnected=1
      done
      (( found_disconnected )) || die "$TARGET_PORT exists, but it is not disconnected. Choose an empty connector."
    else
      log "Warning: could not find $TARGET_PORT under /sys/class/drm; continuing because --port was explicit."
    fi
    return
  fi

  mapfile -t disconnected < <(list_disconnected_ports)
  (( ${#disconnected[@]} > 0 )) || die "No disconnected DRM connectors found. Leave one GPU output physically empty and try again."

  log "Disconnected connectors available for the virtual display:"
  local i
  for i in "${!disconnected[@]}"; do
    log "  [$i] ${disconnected[$i]}"
  done

  local choice
  choice="$(choose_index "$((${#disconnected[@]} - 1))" "Use which disconnected connector?")"
  TARGET_PORT="${disconnected[$choice]}"
}

install_edid() {
  log "Installing cloned EDID to $EDID_PATH"
  if (( DRY_RUN )); then
    log "[dry-run] install -Dm0644 $SOURCE_EDID $EDID_PATH"
  else
    install -Dm0644 "$SOURCE_EDID" "$EDID_PATH"
  fi
}

configure_mkinitcpio() {
  log "Configuring mkinitcpio drop-in: $MKINITCPIO_DROPIN"
  backup_file "$MKINITCPIO_DROPIN"
  write_file "$MKINITCPIO_DROPIN" "0644" "FILES+=(\"$EDID_PATH\")"
}

port_in_list() {
  local needle="$1"
  shift || true

  local port
  for port in "$@"; do
    [[ "$port" == "$needle" ]] && return 0
  done

  return 1
}

rewrite_shell_config() {
  local file="$1"
  local managed_line="${2:-}"

  [[ -f "$file" ]] || return 0

  if (( DRY_RUN )); then
    log "[dry-run] rewrite $file without previous virtual display entries"
    if [[ -n "$managed_line" ]]; then
      log "[dry-run] append managed block:"
      log "$MANAGED_BEGIN"
      log "$managed_line"
      log "$MANAGED_END"
    fi
    return
  fi

  local tmp
  tmp="$(mktemp)"
  awk \
    -v begin="$MANAGED_BEGIN" \
    -v end="$MANAGED_END" \
    -v firmware="$FIRMWARE_RELATIVE_PATH" \
    '
      $0 == begin { skipping = 1; next }
      $0 == end { skipping = 0; next }
      skipping { next }
      $0 == "# Sunshine virtual display EDID" { next }
      index($0, firmware) { next }
      { print }
    ' "$file" > "$tmp"

  if [[ -n "$managed_line" ]]; then
    printf '\n%s\n%s\n%s\n' "$MANAGED_BEGIN" "$managed_line" "$MANAGED_END" >> "$tmp"
  fi

  backup_file "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

rewrite_plain_cmdline() {
  local file="$1"
  local params="${2:-}"
  local current words word old_ports filtered param_words

  [[ -f "$file" ]] || return 0

  current="$(tr '\n' ' ' < "$file")"
  old_ports=()
  filtered=()
  read -r -a words <<< "$current"

  for word in "${words[@]}"; do
    if [[ "$word" =~ ^drm\.edid_firmware=([^:[:space:]]+):edid/virtual-display\.bin$ ]]; then
      old_ports+=("${BASH_REMATCH[1]}")
      continue
    fi
    filtered+=("$word")
  done

  words=("${filtered[@]}")
  filtered=()
  for word in "${words[@]}"; do
    if [[ "$word" =~ ^video=([^:[:space:]]+):e$ ]] && port_in_list "${BASH_REMATCH[1]}" "${old_ports[@]}"; then
      continue
    fi
    filtered+=("$word")
  done

  if [[ -n "$params" ]]; then
    read -r -a param_words <<< "$params"
    filtered+=("${param_words[@]}")
  fi

  if (( DRY_RUN )); then
    log "[dry-run] rewrite $file as:"
    printf '%s\n' "${filtered[*]}"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${filtered[*]}" > "$tmp"
  backup_file "$file"
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

run_boot_generator() {
  if [[ -f /etc/sdboot-manage.conf ]] && command -v sdboot-manage >/dev/null 2>&1; then
    run sdboot-manage gen
    return
  fi

  if [[ -f /etc/default/limine ]] && command -v limine-mkinitcpio >/dev/null 2>&1; then
    run limine-mkinitcpio
    return
  fi

  if [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
    run grub-mkconfig -o /boot/grub/grub.cfg
    return
  fi

  log "No supported boot entry generator was detected; regenerate boot entries manually if your setup requires it."
}

configure_bootloader() {
  local params="drm.edid_firmware=${TARGET_PORT}:${FIRMWARE_RELATIVE_PATH} video=${TARGET_PORT}:e"

  log "Kernel parameters to install:"
  log "  $params"

  if [[ -f /etc/sdboot-manage.conf ]] && command -v sdboot-manage >/dev/null 2>&1; then
    log "Detected CachyOS systemd-boot via sdboot-manage."
    rewrite_shell_config \
      "/etc/sdboot-manage.conf" \
      "LINUX_OPTIONS=\"\${LINUX_OPTIONS:-} $params\""
    run_boot_generator
    return
  fi

  if [[ -f /etc/default/limine ]] && command -v limine-mkinitcpio >/dev/null 2>&1; then
    log "Detected CachyOS Limine."
    rewrite_shell_config \
      "/etc/default/limine" \
      "KERNEL_CMDLINE[default]+=\" $params\""
    run_boot_generator
    return
  fi

  if [[ -f /etc/default/grub ]] && command -v grub-mkconfig >/dev/null 2>&1; then
    log "Detected GRUB."
    rewrite_shell_config \
      "/etc/default/grub" \
      "GRUB_CMDLINE_LINUX_DEFAULT=\"\${GRUB_CMDLINE_LINUX_DEFAULT:-} $params\""
    run_boot_generator
    return
  fi

  if [[ -f /etc/kernel/cmdline ]]; then
    log "Detected plain /etc/kernel/cmdline."
    rewrite_plain_cmdline "/etc/kernel/cmdline" "$params"
    log "No boot entry generator was detected; regenerate your boot entries if your setup requires it."
    return
  fi

  log "Could not identify a supported bootloader config automatically."
  log "Add these kernel parameters manually:"
  log "  $params"
}

remove_bootloader_config() {
  local changed=0
  local file

  for file in /etc/sdboot-manage.conf /etc/default/limine /etc/default/grub; do
    if [[ -f "$file" ]] && grep -Fq "$FIRMWARE_RELATIVE_PATH" "$file"; then
      log "Removing virtual display kernel parameters from $file"
      rewrite_shell_config "$file"
      changed=1
    fi
  done

  if [[ -f /etc/kernel/cmdline ]] && grep -Fq "$FIRMWARE_RELATIVE_PATH" /etc/kernel/cmdline; then
    log "Removing virtual display kernel parameters from /etc/kernel/cmdline"
    rewrite_plain_cmdline "/etc/kernel/cmdline"
    changed=1
  fi

  if (( changed )); then
    log "Bootloader kernel parameters were removed."
  else
    log "No virtual display kernel parameters found in supported bootloader configs."
  fi
}

rebuild_initramfs() {
  if ! command -v mkinitcpio >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      log "[dry-run] mkinitcpio not found here; would run mkinitcpio -P on CachyOS."
      return
    fi
    die "Required command not found: mkinitcpio"
  fi
  log "Rebuilding initramfs with mkinitcpio -P"
  run mkinitcpio -P
}

remove_installed_file() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    log "Already absent: $path"
    return
  fi

  backup_file "$path"
  log "Removing $path"
  run rm -f "$path"
}

install_virtual_display() {
  log "CachyOS Sunshine virtual display setup"
  log

  select_source_edid
  select_target_port

  log
  log "Selected EDID: $SOURCE_EDID"
  log "Selected virtual connector: $TARGET_PORT"
  log

  install_edid
  configure_mkinitcpio
  rebuild_initramfs
  configure_bootloader

  log
  log "Done. Reboot to apply the forced virtual display."
  log "After reboot, verify with: cat /sys/class/drm/card*-${TARGET_PORT}/status"
  log "For Sunshine on Linux, use Sunshine's detected display id/logs for Display Id; do not assume it equals $TARGET_PORT."
}

switch_virtual_port() {
  log "Switching Sunshine virtual display mapping"
  log

  if [[ ! -f "$EDID_PATH" ]]; then
    if (( DRY_RUN )); then
      log "[dry-run] $EDID_PATH is not present here; would require an installed EDID on CachyOS."
    else
      die "$EDID_PATH does not exist. Run --install first."
    fi
  else
    validate_edid "$EDID_PATH"
  fi

  select_target_port

  log
  log "Selected virtual connector: $TARGET_PORT"
  log

  configure_bootloader

  log
  log "Done. Reboot to move the forced virtual display to $TARGET_PORT."
}

uninstall_virtual_display() {
  log "Removing Sunshine virtual display setup"
  log

  remove_bootloader_config
  remove_installed_file "$MKINITCPIO_DROPIN"
  remove_installed_file "$EDID_PATH"
  rebuild_initramfs
  run_boot_generator

  log
  log "Done. Reboot to remove the forced virtual display."
}

show_status() {
  local size

  diagnose_drm
  log
  show_current_mapping
  log
  log "Installed virtual display files:"

  size="$(edid_size "$EDID_PATH")"
  if [[ "$size" =~ ^[0-9]+$ ]] && (( size >= 128 )); then
    log "  EDID: present at $EDID_PATH ($size bytes)"
  else
    log "  EDID: absent or unreadable at $EDID_PATH"
  fi

  if [[ -f "$MKINITCPIO_DROPIN" ]]; then
    log "  mkinitcpio drop-in: present at $MKINITCPIO_DROPIN"
  else
    log "  mkinitcpio drop-in: absent at $MKINITCPIO_DROPIN"
  fi

  log
  log "Managed bootloader entries:"
  local file found=0
  for file in /etc/sdboot-manage.conf /etc/default/limine /etc/default/grub /etc/kernel/cmdline; do
    if [[ -f "$file" ]] && grep -Fq "$FIRMWARE_RELATIVE_PATH" "$file"; then
      found=1
      log "  $file"
      grep -F "$FIRMWARE_RELATIVE_PATH" "$file" | sed 's/^/    /'
    fi
  done
  (( found )) || log "  none found in supported config files"
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --install)
        set_mode "install"
        shift
        ;;
      --switch-port|--change-port)
        [[ $# -ge 2 ]] || die "$1 requires a connector name"
        set_mode "switch"
        TARGET_PORT="$2"
        shift 2
        ;;
      --uninstall|--remove)
        set_mode "uninstall"
        shift
        ;;
      --status)
        set_mode "status"
        shift
        ;;
      --current|--active|--mapped-port)
        set_mode "current"
        shift
        ;;
      --sunshine|--sunshine-output|--sunshine-outputs|--output-name)
        set_mode "sunshine"
        shift
        ;;
      --edid)
        [[ $# -ge 2 ]] || die "--edid requires a path"
        SOURCE_EDID="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die "--port requires a connector name"
        TARGET_PORT="$2"
        shift 2
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --diagnose)
        set_mode "diagnose"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if (( EUID != 0 && DRY_RUN == 0 )) && [[ "$MODE" =~ ^(install|switch|uninstall)$ ]]; then
    die "Run as root: sudo ./setup_virtual_display.sh"
  fi

  require_cmd install
  require_cmd mktemp
  require_cmd wc
  require_cmd tr
  require_cmd sed
  require_cmd awk

  case "$MODE" in
    install)
      install_virtual_display
      ;;
    switch)
      switch_virtual_port
      ;;
    uninstall)
      uninstall_virtual_display
      ;;
    diagnose)
      diagnose_drm
      ;;
    current)
      show_current_mapping
      ;;
    sunshine)
      show_sunshine_hints
      ;;
    status)
      show_status
      ;;
    *)
      die "Unsupported mode: $MODE"
      ;;
  esac
}

main "$@"
