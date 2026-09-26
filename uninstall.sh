#!/usr/bin/env bash
#
# uninstall.sh - remove the synaTudor driver for the Synaptics 06cb:00da
#                fingerprint reader from Debian 13 (trixie) and restore the
#                distro libfprint.
#
# It removes everything install.sh created:
#   * the tudor binaries, D-Bus service and systemd unit
#   * the libfprint-tod driver module, library, headers and .pc files
#   * the udev rules (both the correct copy and upstream's misplaced one)
#   * the fprintd PAM profile
#   * the libfprint-tod build output that replaced the distro libfprint
#
# Options:
#   --purge       also remove build dependencies, source trees and state
#   --purge-data  also delete enrolled fingerprints
#   --keep-sources  keep /opt/synaTudor and /usr/src/libfprint-tod (default)

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

OPT_PURGE=0
OPT_PURGE_DATA=0
OPT_KEEP_SOURCES=0

usage() {
  cat <<EOF
Usage: sudo $0 [--purge] [--purge-data] [--keep-sources]

  --purge        remove build deps installed by install.sh, the source trees
                 in $SRC_DIR and $LBFPRINT_SRC_DIR, and $STATE_DIR
  --purge-data   delete enrolled fingerprints (/var/lib/fprint, ~/tudor-data.db)
  --keep-sources keep the source trees even with --purge
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge)        OPT_PURGE=1 ;;
      --purge-data)   OPT_PURGE_DATA=1 ;;
      --keep-sources) OPT_KEEP_SOURCES=1 ;;
      -h|--help)      usage; exit 0 ;;
      *) err "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------

stop_service() {
  step "Stopping the host launcher"
  if systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${TUDOR_SERVICE%%.service}"; then
    systemctl stop "$TUDOR_SERVICE" 2>/dev/null || true
    # It is a static, D-Bus activated unit, so there is nothing to disable.
    systemctl disable "$TUDOR_SERVICE" 2>/dev/null || true
    ok "$TUDOR_SERVICE stopped"
  else
    info "$TUDOR_SERVICE not installed"
  fi
}

remove_pam() {
  step "Removing the fprintd PAM profile"

  if ! grep -qs pam_fprintd /etc/pam.d/* 2>/dev/null; then
    info "pam_fprintd is not referenced by any PAM stack"
    return 0
  fi

  pam-auth-update --package --remove fprintd >/dev/null 2>&1 || true

  if grep -qs pam_fprintd /etc/pam.d/common-auth 2>/dev/null; then
    if [ -f "${STATE_DIR}/common-auth.bak" ]; then
      cp -a "${STATE_DIR}/common-auth.bak" /etc/pam.d/common-auth
      ok "restored /etc/pam.d/common-auth from ${STATE_DIR}/common-auth.bak"
    else
      sed -i '/pam_fprintd/d' /etc/pam.d/common-auth
      ok "removed pam_fprintd lines from /etc/pam.d/common-auth"
    fi
  else
    ok "fprintd PAM profile removed"
  fi
  info "verify with: grep -r pam_fprintd /etc/pam.d/"
}

remove_files() {
  step "Removing installed files"

  local p
  for p in "${MANAGED_PATHS[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      rm -rf -- "$p"
      info "removed $p"
    fi
  done

  # Soname symlinks / versioned files meson may have created.
  rm -f /usr/lib/"${MULTIARCH}"/libfprint-2-tod.so*
  rm -rf /usr/lib/"${MULTIARCH}"/libfprint-2/tod-1

  ok "driver files removed"
}

restore_libfprint() {
  step "Restoring the distro libfprint"

  local p
  for p in "${LIBFPRINT_PACKAGES[@]}"; do
    if apt-mark showhold 2>/dev/null | grep -qx "$p"; then
      apt-mark unhold "$p" >/dev/null && info "unheld $p"
    fi
  done

  local pkgs=()
  for p in "${LIBFPRINT_PACKAGES[@]}"; do
    pkg_installed "$p" && pkgs+=("$p")
  done

  if [ "${#pkgs[@]}" -gt 0 ]; then
    log "apt-get install --reinstall ${pkgs[*]}"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall "${pkgs[@]}"; then
      ok "reinstalled from the distribution"
    else
      warn "apt reinstall failed, falling back to the backup in $BACKUP_DIR"
      restore_from_backup
    fi
  else
    warn "no libfprint packages recorded; falling back to the backup"
    restore_from_backup
  fi

  ldconfig
  ok "distro libfprint $(dpkg-query -W -f='${Version}' libfprint-2-2 2>/dev/null || echo '?') active"
}

restore_from_backup() {
  local src="${BACKUP_DIR}/libfprint"
  [ -d "$src" ] || { warn "no backup found in $src"; return 0; }

  local rel target
  while IFS= read -r -d '' rel; do
    target="/${rel}"
    install -D -m 0644 "${src}/${rel}" "$target" 2>/dev/null \
      || cp -a "${src}/${rel}" "$target"
    info "restored $target"
  done < <(cd "$src" && find . -type f -print0)

  # The include directory is a directory of headers; make sure it is a real
  # directory again after the TOD-only subdirectory was removed.
  [ -d /usr/include/libfprint-2 ] || install -d -m 0755 /usr/include/libfprint-2
}

purge_packages() {
  step "Removing packages installed by install.sh"

  local before="${STATE_DIR}/packages-before.txt"
  if [ ! -f "$before" ]; then
    warn "no package snapshot in $STATE_DIR - skipping (cannot tell what we added)"
    return 0
  fi

  local added
  added="$(comm -13 "$before" <(snapshot_packages) | grep -v '^$' || true)"
  # fprintd / libpam-fprintd are wanted by other packages on most desktops.
  added="$(printf '%s\n' "$added" | grep -Ev '^(fprintd|libpam-fprintd)$' || true)"

  if [ -z "$added" ]; then
    info "no packages to remove"
    return 0
  fi

  log "apt-get purge $(printf '%s' "$added" | tr '\n' ' ')"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $added \
    || warn "apt-get purge reported errors; check with: dpkg -l | grep -E 'rc'"
  ok "purged"
}

purge_data() {
  step "Removing enrolled fingerprints"

  local u f
  u="$(target_user)"
  if [ -n "$u" ]; then
    for f in "/var/lib/fprint/${u}" "/home/${u}/tudor-data.db"; do
      [ -e "$f" ] || continue
      rm -rf -- "$f"
      info "removed $f"
    done
  fi
  rm -rf /var/lib/tudor
  info "removed /var/lib/tudor"
  ok "enrolled fingerprints deleted"
}

purge_state_and_sources() {
  step "Removing source trees and state"

  if [ "$OPT_KEEP_SOURCES" -eq 0 ]; then
    local d
    for d in "$SRC_DIR" "$LBFPRINT_SRC_DIR"; do
      [ -e "$d" ] || continue
      rm -rf -- "$d"
      info "removed $d"
    done
  else
    info "keeping $SRC_DIR and $LBFPRINT_SRC_DIR"
  fi

  rm -rf "$STATE_DIR"
  ok "removed $STATE_DIR"
}

refresh_system() {
  step "Refreshing the system"
  daemon_reload
  udevadm control --reload-rules || warn "udev reload failed"
  local node
  if node="$(device_node)"; then
    udevadm trigger --action=change --name-match="$node" || true
  fi
  ok "udev rules and systemd units reloaded"
  info "the reader is back to 'not supported by fprintd' until you reinstall"
}

summary() {
  cat <<EOF

${C_BOLD}Uninstall complete${C_RESET}
  * synaTudor driver, libfprint-tod module and udev rules are gone.
  * The distribution libfprint is active again, so fprintd behaves normally.

  Enrolment data was kept. To remove it too:  sudo $0 --purge-data
EOF
}

trap 'rc=$?; if [ "$rc" -ne 0 ]; then err "aborted with exit code $rc at ${BASH_SOURCE[0]}:${BASH_LINENO[0]}"; fi' EXIT

main() {
  parse_args "$@"
  require_root "$0" "$@"

  if [ "${OPT_PURGE_DATA}" -eq 1 ] && [ "$OPT_PURGE" -eq 0 ]; then
    OPT_PURGE=1
  fi

  step "synaTudor / 06cb:00da uninstall"
  info "state directory: $STATE_DIR"

  stop_service
  remove_pam
  remove_files
  restore_libfprint
  refresh_system

  if [ "$OPT_PURGE_DATA" -eq 1 ]; then purge_data; fi
  if [ "$OPT_PURGE" -eq 1 ]; then
    purge_packages
    purge_state_and_sources
  fi

  summary
}

main "$@"
