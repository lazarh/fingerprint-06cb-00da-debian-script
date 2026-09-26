#!/usr/bin/env bash
#
# install.sh - install the unofficial synaTudor driver for the Synaptics
#              06cb:00da fingerprint reader on Debian 13 (trixie).
#
# What it does, in order:
#   1. enables the contrib component (for innoextract) and installs build deps
#   2. backs up the distro libfprint files it is about to overwrite
#   3. builds + installs libfprint-tod (a libfprint fork that can load
#      out-of-tree drivers). It replaces the distro libfprint-2-2 files.
#   4. clones synaTudor and patches it for 06cb:00da
#   5. builds + installs synaTudor (downloads the Lenovo Windows driver and
#      relinks it, so the sensor can be driven on Linux)
#   6. installs a correct udev rule, reloads udev, refreshes systemd
#
# By default it stops there. Fingerprint enrolment and PAM are opt-in:
#   --enroll   run fprintd-enroll for the invoking user
#   --pam      enable the fprintd PAM profile (login / sudo by fingerprint)
#   --hold     apt-mark hold libfprint, so an upgrade cannot silently
#              replace it with a non-TOD build
#
# Re-running is safe: every step is idempotent.

set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$HERE/common.sh"

OPT_PAM=0
OPT_HOLD=0
OPT_ENROLL=0
OPT_FORCE=0
OPT_SKIP_DRIVER_HASH=0
LIBFPRINT_TAG_OVERRIDE=""

BUILD_DEPS=(
  git ca-certificates wget
  build-essential meson ninja-build pkg-config cmake
  innoextract perl
  libglib2.0-dev libgusb-dev libjson-glib-dev libpixman-1-dev
  libnss3-dev libudev-dev libgudev-1.0-dev libcap-dev libseccomp-dev
  libssl-dev libusb-1.0-0-dev libdbus-1-dev libsystemd-dev
  libcairo2-dev
  # systemd-dev ships udev.pc, which this libfprint fork requires.
  systemd-dev
)
RUNTIME_DEPS=( fprintd libpam-fprintd )

usage() {
  cat <<EOF
Usage: sudo $0 [options]

Options:
  --enroll                 run fprintd-enroll for the invoking user
  --pam                    enable the fprintd PAM profile after installing
  --hold                   apt-mark hold the libfprint packages
  --force                  discard local modifications in $SRC_DIR
  --tag <vX.Y.Z+tod1>      use a specific libfprint-tod tag
  --skip-driver-hash-check proceed even if Lenovo's driver .exe changed
  -h, --help               this text

Environment overrides:
  LIBFPRINT_TOD_TAG, SYNATUDOR_PIN, STATE_DIR
EOF
}

# ---------------------------------------------------------------------------

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --enroll)  OPT_ENROLL=1 ;;
      --pam)     OPT_PAM=1 ;;
      --hold)    OPT_HOLD=1 ;;
      --force)   OPT_FORCE=1 ;;
      --skip-driver-hash-check) OPT_SKIP_DRIVER_HASH=1 ;;
      --tag)     LIBFPRINT_TAG_OVERRIDE="${2:-}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *)         err "unknown option: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

preflight() {
  step "Preflight"

  [ "$(id -u)" -eq 0 ] || die "run me with sudo"

  local id ver
  id="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
  ver="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
  if [ "$id" = "13" ] && [ "$ver" = "trixie" ]; then
    ok "Debian 13 (trixie), $MULTIARCH"
  else
    warn "this script is written for Debian 13 (trixie); found ${id:-unknown} (${ver:-unknown})"
  fi

  if lsusb -d "${USB_VENDOR}:${USB_PRODUCT}" >/dev/null 2>&1; then
    ok "reader found: $(lsusb -d "${USB_VENDOR}:${USB_PRODUCT}" | head -n1)"
  else
    warn "no ${USB_VENDOR}:${USB_PRODUCT} device on the USB bus right now."
    warn "the driver will still be installed; plug the reader in afterwards."
  fi

  if [ -d "$SRC_DIR" ] && [ -d "$SRC_DIR/.git" ]; then
    # Our own patches leave the tree dirty, and re-running must stay possible.
    # Only complain about modifications we did not make ourselves.
    local dirty
    dirty="$(git -C "$SRC_DIR" status --porcelain 2>/dev/null | awk '{print $NF}' \
      | grep -vxF -e 'libfprint-tod/src/device.c' \
                   -e 'libfprint-tod/meson.build' \
                   -e 'libfprint-tod/60-tudor-libfprint-tod.rules' || true)"
    if [ -n "$dirty" ]; then
      if [ "$OPT_FORCE" -ne 1 ]; then
        printf '%s\n' "$dirty" | sed 's/^/    /' >&2
        die "$SRC_DIR has local modifications; re-run with --force to discard them
    (stash first if you want to keep them:  git -C $SRC_DIR stash)"
      fi
      warn "discarding local modifications in $SRC_DIR (--force)"
    fi
  fi

  # Never let a function end on a false test: under 'set -e' that would abort
  # the whole script without a message.
  return 0
}

install_dependencies() {
  step "Dependencies"

  # Record what is installed *before* we touch anything, so uninstall.sh --purge
  # can work out exactly which packages this script added.
  snapshot_packages > "${STATE_DIR}/packages-before.txt"

  # innoextract lives in contrib; only touch apt sources if we need it.
  if ! pkg_installed innoextract; then
    ensure_contrib
  fi

  apt_refresh
  log "installing build and runtime packages"
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        "${BUILD_DEPS[@]}" "${RUNTIME_DEPS[@]}"; then
    die "apt-get install failed. If a package was not found, enable contrib
    (innoextract lives there) or install it manually, then re-run."
  fi

  local p
  for p in "${BUILD_DEPS[@]}" "${RUNTIME_DEPS[@]}"; do
    pkg_installed "$p" || die "failed to install required package: $p"
  done
  ok "all ${#BUILD_DEPS[@]} build + ${#RUNTIME_DEPS[@]} runtime packages present"
}

# Pick the libfprint-tod tag matching the distro's libfprint, so the ABI stays
# compatible with the fprintd binary we keep using.
#
# Sets the global LIBFPRINT_TAG. It deliberately does not print the tag on
# stdout: this function also logs progress, and a caller using
# tag="$(detect_libfprint_tag)" would capture that noise as the tag.
LIBFPRINT_TAG=""
detect_libfprint_tag() {
  step "Choosing libfprint-tod tag"

  if [ -n "$LIBFPRINT_TAG_OVERRIDE" ]; then
    info "using --tag ${LIBFPRINT_TAG_OVERRIDE}"
    LIBFPRINT_TAG="$LIBFPRINT_TAG_OVERRIDE"
    return 0
  fi
  if [ -n "${LIBFPRINT_TOD_TAG:-}" ]; then
    info "using LIBFPRINT_TOD_TAG=${LIBFPRINT_TOD_TAG}"
    LIBFPRINT_TAG="$LIBFPRINT_TOD_TAG"
    return 0
  fi

  local dpkgver ver
  dpkgver="$(dpkg-query -W -f='${Version}' libfprint-2-2 2>/dev/null || true)"
  # A dpkg version is epoch:upstream-version-debian-revision, e.g. 1:1.94.9-1.
  # Upstream tags only carry the upstream version, so drop epoch and revision.
  ver="${dpkgver#*:}"
  ver="${ver%-*}"
  if [ -z "$ver" ]; then
    warn "libfprint-2-2 is not installed; assuming 1.94.9"
    ver="1.94.9"
  fi

  local tag="v${ver}+tod1"
  info "distro libfprint: ${dpkgver:-unknown}  ->  trying ${tag}"

  if git ls-remote --exit-code --tags "$LIBFPRINT_TOD_REPO" "refs/tags/${tag}" >/dev/null 2>&1; then
    LIBFPRINT_TAG="$tag"
    return 0
  fi

  err "no such libfprint-tod tag: ${tag}"
  local available
  available="$(git ls-remote --tags "$LIBFPRINT_TOD_REPO" 2>/dev/null \
    | sed -n 's|.*refs/tags/\(v[0-9][^/]*+tod1\)$|\1|p' | sort -V | tr '\n' ' ')"
  if [ -n "$available" ]; then
    err "available tod tags: ${available}"
    err "re-run with:  sudo $0 --tag <tag>"
  else
    err "could not list tags from $LIBFPRINT_TOD_REPO (network problem?)"
  fi
  exit 1
}

# The libfprint-tod build installs over files that belong to libfprint-2-2 /
# libfprint-2-dev. Keep a copy so uninstall.sh can restore them even offline.
backup_distro_libfprint() {
  step "Backing up distro libfprint"

  install -d -m 0755 "$BACKUP_DIR/libfprint"

  local f rel
  for f in \
    "/usr/lib/${MULTIARCH}/libfprint-2.so.2.0.0" \
    "/usr/lib/${MULTIARCH}/pkgconfig/libfprint-2.pc" \
    "/usr/include/libfprint-2" \
    "/usr/share/gir-1.0/FPrint-2.0.gir" \
    "/usr/lib/${MULTIARCH}/girepository-1.0/FPrint-2.0.typelib" \
    "/usr/share/metainfo/org.freedesktop.libfprint.metainfo.xml" \
    "/usr/lib/udev/rules.d/70-libfprint-2.rules" \
    "/usr/lib/udev/hwdb.d/60-autosuspend-libfprint-2.hwdb" \
  ; do
    if [ ! -e "$f" ]; then
      # Not fatal (some of these only exist when the -dev packages are
      # installed), but do not let a wrong path fail silently.
      warn "not present, nothing to back up: $f"
      continue
    fi
    rel="${f#/}"
    mkdir -p "$(dirname "${BACKUP_DIR}/libfprint/${rel}")"
    if [ -d "$f" ]; then
      cp -a "$f" "${BACKUP_DIR}/libfprint/${rel}"
    else
      install -D -m 0644 "$f" "${BACKUP_DIR}/libfprint/${rel}"
    fi
    # Never carry a previous manual install's TOD-only headers into the backup.
    rm -rf "${BACKUP_DIR}/libfprint/${rel}/tod-1"
    info "saved $rel"
  done

  ok "backup stored in ${BACKUP_DIR}/libfprint"
}

# Fail with a readable message instead of meson's bare "cmp: EOF" if Lenovo
# replaced the driver package.
check_lenovo_driver() {
  local url="https://download.lenovo.com/pccbbs/mobiles/r19fp02w.exe"
  local want got
  want="$(tr -d '[:space:]' < "${SRC_DIR}/libtudor/installer.sha")"
  [ -n "$want" ] || return 0

  log "checking Lenovo driver package"
  got="$(wget -q -O - "$url" | sha1sum | cut -d' ' -f1)" || {
    warn "could not download $url (build will retry)"
    return 0
  }

  if [ "$got" = "$want" ]; then
    ok "driver package sha1 matches the pinned hash"
    return 0
  fi

  warn "Lenovo's r19fp02w.exe changed on the server."
  warn "  expected sha1: $want"
  warn "  got      sha1: $got"
  if [ "$OPT_SKIP_DRIVER_HASH" -eq 1 ]; then
    warn "continuing anyway (--skip-driver-hash-check)"
    return 0
  fi
  die "refusing to build against an unverified driver package.
    If you inspected the new package and trust it, re-run with
    --skip-driver-hash-check, or update the pin with:
      echo -n '$got' > $SRC_DIR/libtudor/installer.sha"
}

build_libfprint_tod() {
  step "Building libfprint-tod ($1)"

  if [ ! -d "$LBFPRINT_SRC_DIR/.git" ]; then
    log "cloning $LIBFPRINT_TOD_REPO"
    rm -rf "$LBFPRINT_SRC_DIR"
    git clone --quiet --depth 1 --branch "$1" "$LIBFPRINT_TOD_REPO" "$LBFPRINT_SRC_DIR"
  fi

  cd "$LBFPRINT_SRC_DIR"
  git fetch --quiet --depth 1 origin "refs/tags/$1:refs/tags/$1" 2>/dev/null || true
  git checkout --quiet --force "$1"

  # This fork descends into tests/ and examples/ unconditionally and offers no
  # meson option to skip them; they need a pile of extra dependencies and are
  # useless for building the library.
  if ! grep -q "^#subdir('tests')" meson.build; then
    sed -i -E "s%^([[:space:]]*)subdir\('(tests|examples)'\)(.*)\$%\1#subdir('\2')\3%" meson.build
  fi
  grep -q "^#subdir('tests')" meson.build || die "could not disable tests/ in meson.build"

  rm -rf build
  log "meson setup"
  # -Dtod defaults to true in this fork; doc and introspection are disabled so
  # we do not need gtk-doc, GObject-introspection or their build dependencies.
  meson setup build --prefix=/usr --libdir="/usr/lib/${MULTIARCH}" \
      -Ddoc=false -Dintrospection=false -Dgtk-examples=false \
    || { tail -n 30 build/meson-logs/meson-log.txt 2>/dev/null || true
         die "meson setup failed (see $LBFPRINT_SRC_DIR/build/meson-logs/meson-log.txt)"; }

  log "compiling"
  meson compile -C build -j "$(nproc)" || die "compilation failed"

  log "installing (this replaces the distro libfprint-2-2 files)"
  meson install -C build >/dev/null
  ldconfig
  ok "libfprint-2-tod-1 $(pkg-config --modversion libfprint-2-tod-1 2>/dev/null || echo '?') installed"
}

fetch_syna_tudor() {
  step "Fetching synaTudor"

  if [ ! -d "$SRC_DIR/.git" ]; then
    if [ -e "$SRC_DIR" ]; then
      die "$SRC_DIR exists but is not a git checkout; move it out of the way and re-run"
    fi
    log "cloning $SYNATUDOR_REPO -> $SRC_DIR"
    git clone --quiet "$SYNATUDOR_REPO" "$SRC_DIR"
  fi

  cd "$SRC_DIR"
  log "checking out ${SYNATUDOR_PIN}"
  git fetch --quiet --tags origin
  git checkout --quiet --force "$SYNATUDOR_PIN"
  ok "synaTudor at $(git rev-parse --short HEAD)"
}

# The whole point of this function: upstream only advertises 06cb:00be, so
# without this line fprintd never sees the 06cb:00da reader.
patch_device_id_table() {
  step "Patching synaTudor for ${USB_VENDOR}:${USB_PRODUCT}"

  local f="${SRC_DIR}/libfprint-tod/src/device.c"
  [ -f "$f" ] || die "unexpected layout: $f is missing"

  if grep -q "pid = 0x${USB_PRODUCT}" "$f"; then
    ok "device.c: ${USB_VENDOR}:${USB_PRODUCT} already present"
  else
    # Insert a new entry right after the first (upstream) table entry.
    filter_in_place "$f" awk \
      -v vid="0x${USB_VENDOR}" -v pid="0x${USB_PRODUCT}" '
      { print }
      !done && $0 ~ /^[[:space:]]*\{[[:space:]]*\.vid/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, 1, RLENGTH)
        print indent "{ .vid = " vid ", .pid = " pid " },"
        done = 1
      }
    ' "$f"
    assert_contains "$f" "pid = 0x${USB_PRODUCT}" "device.c id table"
    ok "device.c: added { .vid = 0x${USB_VENDOR}, .pid = 0x${USB_PRODUCT} }"
  fi

  # Install the udev rule into rules.d, not /usr/lib/udev.
  local m="${SRC_DIR}/libfprint-tod/meson.build"
  if grep -q "pkgconfig: 'udevdir'" "$m"; then
    sed -i "s|install_dir: udev_dep.get_variable(pkgconfig: 'udevdir')|install_dir: '/usr/lib/udev/rules.d'|" "$m"
    assert_contains "$m" "install_dir: '/usr/lib/udev/rules.d'" "meson.build udev install_dir"
    ok "meson.build: udev rule now installs into /usr/lib/udev/rules.d"
  else
    warn "meson.build: unexpected udev install_dir, skipping that patch"
  fi
}

# The shipped rule targets the wrong PID and grants no access to the logged-in
# user, so we write our own instead of relying on upstream's copy.
write_udev_rules() {
  step "Installing udev rules"

  local dest="${SRC_DIR}/libfprint-tod/60-tudor-libfprint-tod.rules"
  local p
  write_in_place "$dest" <<EOF
# Synaptics fingerprint readers (synaTudor / libfprint-tod).
# Generated by install.sh - local edits are overwritten.
EOF
  for p in "$USB_PRODUCT_UPSTREAM" "$USB_PRODUCT"; do
    append_in_place "$dest" <<EOF
SUBSYSTEM=="usb", ATTRS{idVendor}=="${USB_VENDOR}", ATTRS{idProduct}=="${p}", ATTRS{dev}=="*", TEST=="power/control", ATTR{power/control}="auto", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="${USB_VENDOR}", ATTR{idProduct}=="${p}", ENV{LIBFPRINT_DRIVER}="Tudor TOD"
EOF
  done
  # Let the user of the active seat session open the sensor without root.
  append_in_place "$dest" <<EOF
SUBSYSTEM=="usb", ATTR{idVendor}=="${USB_VENDOR}", ATTR{idProduct}=="${USB_PRODUCT}", TAG+="uaccess"
EOF

  assert_contains "$dest" "idProduct}==\"${USB_PRODUCT}\"" "generated udev rule"
  ok "wrote $(basename "$dest")"
}

build_syna_tudor() {
  step "Building and installing synaTudor"

  cd "$SRC_DIR"
  check_lenovo_driver

  rm -rf build
  log "meson setup"
  meson setup build --prefix=/usr \
    || { tail -n 30 build/meson-logs/meson-log.txt 2>/dev/null || true
         die "meson setup failed (see $SRC_DIR/build/meson-logs/meson-log.txt)"; }

  log "compiling (downloads + extracts the Lenovo driver on first run)"
  meson compile -C build -j "$(nproc)" || die "compilation failed"

  log "installing"
  meson install -C build >/dev/null
  ldconfig
  daemon_reload

  # meson may have dropped a copy of the rule in the wrong directory.
  rm -f /usr/lib/udev/60-tudor-libfprint-tod.rules

  if [ -x /usr/sbin/tudor/tudor_cli ]; then
    ok "installed /usr/sbin/tudor/tudor_cli"
  else
    die "tudor_cli missing after install"
  fi
}

# The single most important post-install check: if the module does not list
# 06cb:00da, fprintd will silently ignore the reader.
verify_driver_module() {
  step "Verifying the built driver module"

  [ -f "$TUDOR_DRIVER_MODULE" ] || die "driver module missing: $TUDOR_DRIVER_MODULE"

  if verify_id_table "$TUDOR_DRIVER_MODULE"; then
    ok "$TUDOR_DRIVER_MODULE advertises ${USB_VENDOR}:${USB_PRODUCT}"
  else
    die "the built module does not list ${USB_VENDOR}:${USB_PRODUCT}.
    fprintd would ignore the reader. Check that
    $SRC_DIR/libfprint-tod/src/device.c contains
    { .vid = 0x${USB_VENDOR}, .pid = 0x${USB_PRODUCT} }, and rebuild."
  fi
}

activate() {
  step "Activating"

  reload_udev

  # tudor-host-launcher is D-Bus activated (static unit), so it must not be
  # enabled; it is started on demand by the driver.
  systemctl start "$TUDOR_SERVICE" 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet "$TUDOR_SERVICE"; then
    ok "$TUDOR_SERVICE is running"
  else
    warn "$TUDOR_SERVICE is not running; it is D-Bus activated and will start"
    warn "on first use. Check with: journalctl -u $TUDOR_SERVICE -b --no-pager"
  fi

  local node
  if node="$(device_node)"; then
    if device_node_has_acl "$node"; then
      ok "device node $node is accessible to your session"
    else
      warn "device node $node has no ACL."
      warn "log out and back in (or replug the reader) so TAG+=\"uaccess\" applies."
    fi
  fi
}

enable_pam() {
  step "Enabling fingerprint authentication (PAM)"

  local f
  for f in /etc/pam.d/common-auth /etc/pam.d/common-account; do
    [ -f "$f" ] || continue
    [ -e "${STATE_DIR}/$(basename "$f").bak" ] || cp -a "$f" "${STATE_DIR}/$(basename "$f").bak"
  done

  if grep -qs pam_fprintd /etc/pam.d/common-auth; then
    ok "pam_fprintd already present in /etc/pam.d/common-auth"
  else
    pam-auth-update --enable fprintd >/dev/null \
      || warn "pam-auth-update --enable fprintd failed"
  fi

  if grep -qs pam_fprintd /etc/pam.d/common-auth; then
    ok "pam_fprintd enabled for auth (password still works as fallback)"
  else
    warn "could not enable pam_fprintd non-interactively."
    warn "run:  sudo pam-auth-update --force --enable fprintd"
  fi
  info "keep a root shell open while testing PAM changes"
}

hold_libfprint() {
  step "Holding libfprint packages"
  local p
  for p in "${LIBFPRINT_PACKAGES[@]}"; do
    pkg_installed "$p" || continue
    apt-mark hold "$p" >/dev/null && ok "held $p"
  done
  info "an apt upgrade would otherwise install a non-TOD libfprint and break this."
  info "release the hold again with: sudo apt-mark unhold ${LIBFPRINT_PACKAGES[*]}"
}

do_enroll() {
  local user uid bus
  user="$(target_user)"
  [ -n "$user" ] || { warn "cannot determine the user to enrol for; skipping"; return 0; }
  uid="$(id -u "$user")"

  step "Enrolling a fingerprint for $user"

  # sudo usually strips DBUS_SESSION_BUS_ADDRESS, so fall back to the standard
  # per-user session bus socket.
  bus="${DBUS_SESSION_BUS_ADDRESS:-}"
  if [ -z "$bus" ] && [ -S "/run/user/${uid}/bus" ]; then
    bus="unix:path=/run/user/${uid}/bus"
  fi
  if [ -z "$bus" ]; then
    warn "no session bus found for $user - enrol from your desktop session with:"
    warn "  fprintd-enroll"
    return 0
  fi

  info "session bus: $bus"
  info "touch the reader repeatedly when asked"
  sudo -u "$user" \
    env DBUS_SESSION_BUS_ADDRESS="$bus" XDG_RUNTIME_DIR="/run/user/${uid}" \
    fprintd-enroll || warn "fprintd-enroll failed; see the messages above"
}

summary() {
  print_status

  cat <<EOF

${C_BOLD}Next steps${C_RESET}
  1. Enrol a finger (in a graphical session, as your normal user):
       fprintd-enroll
  2. Check it:
       fprintd-list "\$(whoami)"
       fprintd-verify
EOF

  if [ "$OPT_PAM" -eq 0 ]; then
    cat <<EOF
  3. Optional - enable fingerprint login and sudo:
       sudo $0 --pam
EOF
  fi

  cat <<EOF

${C_BOLD}Notes${C_RESET}
  * The libfprint-tod build replaced the distro libfprint-2-2 files.
    To undo everything:  sudo $HERE/uninstall.sh
  * This is an unofficial, reverse-engineered driver. It may stop working
    after a firmware or distro update.
  * State and backups: $STATE_DIR
EOF
}

# Turn a silent 'set -e' abort into a message that says where it happened.
# Without this, a function that happens to end on a false test kills the script
# with no explanation at all.
trap 'rc=$?; if [ "$rc" -ne 0 ]; then err "aborted with exit code $rc at ${BASH_SOURCE[0]}:${BASH_LINENO[0]}"; fi' EXIT

main() {
  parse_args "$@"
  require_root "$0" "$@"
  ensure_state_dir

  preflight
  install_dependencies

  local tag
  detect_libfprint_tag
  tag="$LIBFPRINT_TAG"

  backup_distro_libfprint
  build_libfprint_tod "$tag"

  fetch_syna_tudor
  patch_device_id_table
  write_udev_rules
  build_syna_tudor
  verify_driver_module
  activate

  if [ "$OPT_PAM" -eq 1 ];    then enable_pam;    fi
  if [ "$OPT_HOLD" -eq 1 ];   then hold_libfprint; fi
  if [ "$OPT_ENROLL" -eq 1 ]; then do_enroll;     fi

  summary
}

main "$@"
