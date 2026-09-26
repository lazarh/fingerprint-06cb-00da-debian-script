#!/usr/bin/env bash
# common.sh - shared helpers for install.sh / uninstall.sh
#
# Synaptics 06cb:00da fingerprint reader on Debian 13 (trixie).
# This file is meant to be sourced, not executed.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# USB id of the reader we support.
USB_VENDOR="06cb"
USB_PRODUCT="00da"
# The other Synaptics reader the upstream project also knows about.
USB_PRODUCT_UPSTREAM="00be"

# Where we keep state (package list, backups of overwritten distro files).
STATE_DIR="${STATE_DIR:-/var/lib/synaTudor-00da}"
BACKUP_DIR="${STATE_DIR}/backup"

# Source trees.
SRC_DIR="${SRC_DIR:-/opt/synaTudor}"
LBFPRINT_SRC_DIR="${LBFPRINT_SRC_DIR:-/usr/src/libfprint-tod}"

# Upstream projects.
SYNATUDOR_REPO="${SYNATUDOR_REPO:-https://github.com/Popax21/synaTudor.git}"
# 31dfdb0 is the revision that expects synaFpAdapter104.dll /
# synaWudfBioUsb104.dll, which is what Lenovo's r19fp02w.exe ships today.
SYNATUDOR_PIN="${SYNATUDOR_PIN:-31dfdb0}"
LIBFPRINT_TOD_REPO="${LIBFPRINT_TOD_REPO:-https://gitlab.freedesktop.org/3v1n0/libfprint.git}"

# Debian multiarch triplet.
MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"

# Driver + module paths.
TUDOR_DRIVER_MODULE="/usr/lib/${MULTIARCH}/libfprint-2/tod-1/libtudor_tod.so"
TUDOR_UDEV_RULE="/usr/lib/udev/rules.d/60-tudor-libfprint-tod.rules"
TUDOR_SERVICE="tudor-host-launcher.service"

# Everything the installer creates outside of dpkg's database.
# uninstall.sh removes exactly these paths.
readonly MANAGED_PATHS=(
  "/usr/sbin/tudor"
  "/usr/lib/systemd/system/tudor-host-launcher.service"
  "/usr/share/dbus-1/system.d/net.reactivated.TudorHostLauncher.conf"
  "/usr/share/dbus-1/system-services/net.reactivated.TudorHostLauncher.service"
  "/usr/lib/${MULTIARCH}/libfprint-2-tod.so"
  "/usr/lib/${MULTIARCH}/libfprint-2-tod.so.1"
  "/usr/lib/${MULTIARCH}/libfprint-2/tod-1"
  "/usr/lib/${MULTIARCH}/pkgconfig/libfprint-2-tod-1.pc"
  "/usr/include/libfprint-2/tod-1"
  "/usr/share/gtk-doc/html/libfprint-2"
  "${TUDOR_UDEV_RULE}"
  # The upstream meson.build installs the rule to udevdir (/usr/lib/udev),
  # which is not a rules directory. We remove this stray copy if we find it.
  "/usr/lib/udev/60-tudor-libfprint-tod.rules"
)

# Files that belong to distro packages but get overwritten by the
# libfprint-tod build. Restored by uninstall.sh.
readonly LIBFPRINT_PACKAGES=(
  "libfprint-2-2"
  "libfprint-2-dev"
  "gir1.2-fprint-2.0"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
info() { printf '     %s\n' "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%serr: %s%s\n'  "$C_RED"    "$*" "$C_RESET" >&2; }
die()  { err "$*"; exit 1; }

step() {
  printf '\n%s>>> %s%s\n' "$C_BOLD" "$*" "$C_RESET"
}

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Privilege / environment helpers
# ---------------------------------------------------------------------------

# Re-exec the calling script through sudo when we are not root.
# Usage: require_root "$0" "$@"
require_root() {
  [ "$(id -u)" -eq 0 ] && return 0
  have sudo || die "must run as root (sudo is not installed)"

  local self="${1:-}"; shift || true
  case "$self" in
    /*) ;;
    "")  die "internal error: require_root needs the script path" ;;
    *)  self="$PWD/$self" ;;
  esac

  info "re-executing under sudo..."
  exec sudo -- "$self" "$@"
}

# The user we enroll fingerprints for / report status about.
target_user() {
  local u="${SUDO_USER:-${USER:-}}"
  [ -n "$u" ] && [ "$u" != "root" ] || u=""
  printf '%s' "$u"
}

ensure_state_dir() {
  install -d -m 0755 "$STATE_DIR"
  install -d -m 0755 "$BACKUP_DIR"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# Snapshot every installed package, so we can later compute exactly which
# packages this script added (and therefore may purge).
snapshot_packages() {
  dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u
}

# Verify that an edit actually landed; abort loudly otherwise. Guards against
# upstream reformatting the file and silently producing a broken build.
assert_contains() {
  local file="$1" needle="$2" what="$3"
  grep -qF -- "$needle" "$file" \
    || die "patch failed: $what (could not find '$needle' in $file after patching)"
}

# Replace a file's contents, keeping its inode/permissions.
write_in_place() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "$tmp"
  cat "$tmp" > "$dest"
  rm -f "$tmp"
}

# Append stdin to a file, keeping its inode/permissions.
append_in_place() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat > "$tmp"
  cat "$tmp" >> "$dest"
  rm -f "$tmp"
}

# Filter a file through a filter command, replacing it in place.
#
# Never write the output of a filter back into the file it is reading: the
# shell truncates the output file before the filter gets to open its input.
# Usage: filter_in_place <file> <filter> [args...]
filter_in_place() {
  local f="$1"; shift
  local tmp
  tmp="$(mktemp "${f}.XXXXXX")"
  if ! "$@" > "$tmp"; then
    rm -f "$tmp"
    die "filter_in_place: '$*' failed for $f"
  fi
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# APT helpers
# ---------------------------------------------------------------------------

apt_refresh() {
  log "apt-get update"
  apt-get update -qq
}

# Add the contrib component (needed for innoextract) if it is missing.
# Handles both deb822 (.sources) and one-line (.list) formats, and is a no-op
# when contrib is already enabled.
ensure_contrib() {
  local f changed=0
  shopt -s nullglob

  for f in /etc/apt/sources.list.d/*.sources; do
    grep -qE '^Components:.*(^|[[:space:]])contrib([[:space:]]|$)' "$f" && continue
    log "enabling contrib in $f"
    filter_in_place "$f" awk '
      /^Components:/ {
        if ($0 !~ /(^|[[:space:]])contrib([[:space:]]|$)/) {
          sub(/[[:space:]]*$/, ""); print $0 " contrib"; next
        }
      }
      { print }
    ' "$f"
    changed=1
  done

  for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
    [ -f "$f" ] || continue
    grep -qE '(^|[[:space:]])contrib([[:space:]]|$)' "$f" && continue
    log "enabling contrib in $f"
    filter_in_place "$f" awk '
      /^[[:space:]]*#/ || NF == 0 { print; next }
      / contrib([[:space:]]|$)/   { print; next }
                                   { $0 = $0 " contrib"; print }
    ' "$f"
    changed=1
  done

  shopt -u nullglob
  [ "$changed" -eq 1 ] || info "contrib already enabled"
  return 0
}

# ---------------------------------------------------------------------------
# udev / systemd helpers
# ---------------------------------------------------------------------------

# Current device node for our reader, e.g. /dev/bus/usb/001/003
device_node() {
  local line bus num
  line="$(lsusb -d "${USB_VENDOR}:${USB_PRODUCT}" 2>/dev/null | head -n1)" || true
  [ -n "$line" ] || return 1
  bus="$(printf '%s' "$line" | sed -n 's/^Bus \([0-9]\{3\}\) Device .*/\1/p')"
  num="$(printf '%s' "$line" | sed -n 's/^Bus [0-9]\{3\} Device \([0-9]\{3\}\):.*/\1/p')"
  [ -n "$bus" ] && [ -n "$num" ] || return 1
  printf '/dev/bus/usb/%s/%s' "$bus" "$num"
}

# Permissions string for a device node, e.g. "crw-rw-r--+".
device_node_perms() {
  ls -l "$1" 2>/dev/null | awk '{print $1}'
}

# Succeeds when the device node carries a POSIX ACL. udev's TAG+="uaccess"
# adds one for the user of the active seat session, which is what allows a
# normal user to open the sensor. Avoids depending on getfacl(1).
device_node_has_acl() {
  local perms
  perms="$(device_node_perms "$1")"
  case "$perms" in
    *+*) return 0 ;;
    *)   return 1 ;;
  esac
}

reload_udev() {
  log "reloading udev rules"
  udevadm control --reload-rules || warn "udevadm control --reload-rules failed"
  local node
  if node="$(device_node)"; then
    udevadm trigger --action=change --name-match="$node" \
      || warn "could not re-trigger rules for $node (unplug the reader or reboot)"
  else
    warn "reader not found on the bus; rules apply after the next plug/reboot"
  fi
}

daemon_reload() {
  systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# Verification helpers
# ---------------------------------------------------------------------------

# The libfprint-tod module advertises the readers it supports in a static
# FpIdEntry table baked into the shared object. Upstream's table only lists
# 06cb:00be, which is why fprintd does not see 06cb:00da unless we patch it.
#
# FpIdEntry's layout has changed between libfprint versions; both the
# {u32 pid; u32 vid} and the {u16 vid; u16 pid} orderings are checked.
verify_id_table() {
  local so="$1" hex
  [ -f "$so" ] || return 1
  hex="$(od -An -v -tx1 "$so" | tr -d ' \n')"
  case "$hex" in
    *da000000cb060000*|*cb060000da000000*|*cb06da00*|*da0006cb*) return 0 ;;
    *) return 1 ;;
  esac
}

# Human readable summary of what the reader looks like right now.
print_status() {
  step "Status"

  if lsusb -d "${USB_VENDOR}:${USB_PRODUCT}" >/dev/null 2>&1; then
    ok "reader present: $(lsusb -d "${USB_VENDOR}:${USB_PRODUCT}" | head -n1)"
  else
    warn "reader ${USB_VENDOR}:${USB_PRODUCT} not found on the USB bus"
  fi

  local node
  if node="$(device_node)"; then
    if device_node_has_acl "$node"; then
      ok "device node $node ($(device_node_perms "$node")) carries an ACL - your session can open it"
    else
      warn "device node $node ($(device_node_perms "$node")) has no ACL."
      warn "your session cannot open the sensor; log out and back in or replug it."
    fi
  fi

  if verify_id_table "$TUDOR_DRIVER_MODULE"; then
    ok "driver module knows ${USB_VENDOR}:${USB_PRODUCT}"
  else
    warn "driver module does NOT list ${USB_VENDOR}:${USB_PRODUCT} - fprintd will ignore the reader"
  fi

  if systemctl is-active --quiet "$TUDOR_SERVICE"; then
    ok "$TUDOR_SERVICE is active"
  elif systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${TUDOR_SERVICE%%.service}"; then
    info "$TUDOR_SERVICE is installed but idle (D-Bus activated, starts on demand)"
  else
    warn "$TUDOR_SERVICE is not installed"
  fi

  if [ -f "$TUDOR_UDEV_RULE" ]; then
    ok "udev rule installed: $TUDOR_UDEV_RULE"
  else
    warn "udev rule missing: $TUDOR_UDEV_RULE"
  fi
}
