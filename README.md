# synaTudor driver for the Synaptics 06cb:00da fingerprint reader (Debian 13)

Install / uninstall scripts for the **unofficial, reverse-engineered** `synaTudor`
driver, so that the Synaptics `06cb:00da` fingerprint reader (ThinkPad E14/E15
Gen 2, Ideapad, …) works with `fprintd` on Debian 13 (trixie) / GNOME.

Debian's stock `libfprint` has no driver for this reader, so `fprintd` ignores
it out of the box. `synaTudor` relays the sensor to the vendor's own Windows
driver DLLs, and `libfprint-tod` is a libfprint fork that can load such
out-of-tree driver modules.

> This is not a packaged, supported solution. It may break after a distro or
> firmware update. It is also not a good fit for a machine whose disk is not
> encrypted.

## Quick start

```bash
git clone <this-repo> && cd fingerprint-06cb-00da-debian-script

sudo ./install.sh --pam --hold      # install + enable fingerprint login
fprintd-enroll                       # enrol a finger, in your desktop session
fprintd-verify                       # test it
```

To undo everything:

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --purge         # ... and drop the build dependencies
```

## Requirements

* Debian 13 (trixie), amd64
* a Synaptics `06cb:00da` reader (`lsusb -d 06cb:00da`)
* internet access on first run (apt, GitHub, gitlab.freedesktop.org, Lenovo)
* the `contrib` component — the script enables it for you (`innoextract`)

## What the installer does

1. **Preflight** – checks Debian version, architecture and reader presence.
2. **Dependencies** – installs the build and runtime packages, enabling
   `contrib` first if needed. Records a package snapshot for `--purge`.
3. **Backup** – copies the distro `libfprint` files that step 4 overwrites into
   `/var/lib/synaTudor-00da/backup/`.
4. **libfprint-tod** – clones [`3v1n0/libfprint`](https://gitlab.freedesktop.org/3v1n0/libfprint)
   at the tag matching the installed distro `libfprint` (1.94.9 →
   `v1.94.9+tod1`), skips `tests/` and `examples/`, disables docs and
   introspection, and installs it. **This replaces the distro
   `libfprint-2-2` files** — unavoidable, and the reason for the backup and for
   `uninstall.sh`.
5. **synaTudor** – clones [`Popax21/synaTudor`](https://github.com/Popax21/synaTudor)
   at a pinned revision, applies three patches (below), builds and installs it.
   The build downloads Lenovo's `r19fp02w.exe` driver package, verifies its
   SHA-1, and extracts `synaFpAdapter104.dll` / `synaWudfBioUsb104.dll`.
6. **Verification** – reads the driver module's binary device-ID table back and
   refuses to continue unless it really advertises `06cb:00da`.
7. **Activate** – installs a correct udev rule, reloads udev, starts
   `tudor-host-launcher` (D-Bus activated, so never `systemctl enable`d).

### The three patches, and why they matter

| File | Change | Why |
| --- | --- | --- |
| `libfprint-tod/src/device.c` | add `{ .vid = 0x06cb, .pid = 0x00da }` to `tudor_ids[]` | **upstream only lists `06cb:00be`.** Without this, `fprintd` never sees the reader and only the standalone `tudor_cli` works. |
| `libfprint-tod/60-tudor-libfprint-tod.rules` | add `00da` rules, `TAG+="uaccess"` | upstream's rule targets the wrong PID and grants the logged-in user no access, so opening the sensor fails with `LIBUSB_ERROR_ACCESS`. |
| `libfprint-tod/meson.build` | install the rule to `/usr/lib/udev/rules.d` | upstream installs it to `udevdir` (`/usr/lib/udev`), which is not a rules directory, so udev never reads it. |

Each patch is applied idempotently and verified; the script aborts if an anchor
is not found rather than producing a silently broken build.

## Options

### `install.sh`

| Option | Effect |
| --- | --- |
| `--pam` | enable the `fprintd` PAM profile (login, sudo, …). Password auth stays enabled as a fallback. |
| `--hold` | `apt-mark hold` the `libfprint` packages, so a routine `apt upgrade` cannot silently replace the TOD build with a non-TOD one. |
| `--enroll` | run `fprintd-enroll` for the invoking user (needs a graphical session). |
| `--force` | discard local modifications in `/opt/synaTudor`. |
| `--tag <tag>` | use a specific `libfprint-tod` tag, e.g. `v1.95.1+tod1`. |
| `--skip-driver-hash-check` | build even if Lenovo changed `r19fp02w.exe`. |

Environment overrides: `SRC_DIR`, `LBFPRINT_SRC_DIR`, `STATE_DIR`,
`SYNATUDOR_PIN`, `LIBFPRINT_TOD_TAG`.

Re-running `install.sh` is safe; every step is idempotent.

### `uninstall.sh`

| Option | Effect |
| --- | --- |
| `--purge` | also remove the packages the installer added, `/opt/synaTudor`, `/usr/src/libfprint-tod` and the state directory. |
| `--purge-data` | also delete enrolled fingerprints (`/var/lib/fprint/<user>`, `~/tudor-data.db`). Implies `--purge`. |
| `--keep-sources` | keep the source trees even with `--purge`. |

`uninstall.sh` restores the distribution `libfprint` with
`apt-get install --reinstall libfprint-2-2 libfprint-2-dev gir1.2-fprint-2.0`,
falling back to the backup in `/var/lib/synaTudor-00da/backup/` if apt cannot
reach the network. It also removes the PAM profile via
`pam-auth-update --package --remove fprintd`, restoring the pre-install
`common-auth` backup when one exists.

`fprintd` and `libpam-fprintd` are never purged, even with `--purge`, because
other packages on a desktop usually depend on them.

## Files the installer adds

```
/usr/sbin/tudor/{libtudor.so,tudor_cli,tudor_host,tudor_host_launcher}
/usr/lib/systemd/system/tudor-host-launcher.service
/usr/share/dbus-1/system.d/net.reactivated.TudorHostLauncher.conf
/usr/share/dbus-1/system-services/net.reactivated.TudorHostLauncher.service
/usr/lib/<triplet>/libfprint-2-tod.so{,.1}
/usr/lib/<triplet>/libfprint-2/tod-1/libtudor_tod.so
/usr/lib/<triplet>/pkgconfig/libfprint-2-tod-1.pc
/usr/include/libfprint-2/tod-1/
/usr/lib/udev/rules.d/60-tudor-libfprint-tod.rules
/opt/synaTudor/            (source checkout, patched)
/usr/src/libfprint-tod/    (source checkout)
/var/lib/synaTudor-00da/   (package snapshot + libfprint backup)
```

Files it **overwrites** (restored by `uninstall.sh`):

```
/usr/lib/<triplet>/libfprint-2.so.2.0.0     (libfprint-2-2)
/usr/lib/<triplet>/libfprint-2.pc           (libfprint-2-dev)
/usr/include/libfprint-2/*.h                (libfprint-2-dev)
/usr/lib/udev/rules.d/70-libfprint-2.rules  (libfprint-2-2)
/usr/share/metainfo/org.freedesktop.libfprint.metainfo.xml
```

## Usage after installing

```bash
fprintd-enroll                  # enrol (in a desktop session)
fprintd-list "$(whoami)"        # what is enrolled
fprintd-verify                  # test
sudo -k && sudo true            # test sudo; press Enter without a password, then touch
```

With `--pam`, the fingerprint works for the display manager, `sudo`, `su`,
`pkexec` and polkit. Depending on the display manager you may need to press
Enter with the password field empty first.

For debugging, the standalone CLI bypasses `fprintd` (and its device-ID table
entirely). It must **not** run as root — it refuses, because it has to drop
privileges:

```bash
/usr/sbin/tudor/tudor_cli "$HOME/tudor-data.db" -P0x00da
```

## Troubleshooting

**`fprintd-enroll` says no device / permission denied**

The udev rule has not been applied to the current device. Log out and back in,
replug the reader, or reboot, then check:

```bash
ls -l /dev/bus/usb/001/003      # expect a '+' (ACL) on the permissions
getfacl /dev/bus/usb/001/003
```

`TAG+="uaccess"` needs an active seat session. From a pure TTY or over SSH
there is no such session, so either log in graphically or use the
`plugdev` rule that the script installs (`sudo usermod -aG plugdev "$USER"`,
then log in again).

**`fprintd` still ignores the reader**

Check the driver module really knows the device — the installer does this, but
you can repeat it:

```bash
grep -n '0x00da' /opt/synaTudor/libfprint-tod/src/device.c
journalctl -u fprintd -b --no-pager
journalctl -u tudor-host-launcher -b --no-pager
```

**`LIBUSB_ERROR_ACCESS` from `tudor_cli`** – same udev problem as above.

**The build fails with `synaFpAdapter108.dll not found`**

Lenovo changed the driver package. The pinned revision `31dfdb0` expects the
`*104.dll` generation, which is what the current download provides. If Lenovo
publishes a new generation, refresh the pin:

```bash
git -C /opt/synaTudor fetch --tags
git -C /opt/synaTudor log --oneline --all -- libtudor/meson.build | head
```

**An `apt upgrade` broke it**

`libfprint-2-2` was upgraded to a build without TOD support. Re-run
`./install.sh`, or use `--hold` to prevent it.

## Notes and caveats

* The install **replaces the distro `libfprint`** with the TOD fork. `fprintd`
  keeps working because the fork ships a full `libfprint-2`, and the tag is
  chosen to match the distro version for ABI compatibility.
* If your `apt` sources include a newer suite (e.g. `forky`/testing) at higher
  priority, a plain `apt install libfprint-2-2` pulls a non-TOD build. Use
  `--hold`, or pin `libfprint-2-2` in `apt-mark`.
* `tudor-host-launcher` is a static, D-Bus-activated unit. `systemctl enable`
  warns and does nothing; that is expected.
* The `PE file contains unsupported …` warnings from `tudor_cli` come from the
  Win32 compatibility layer and are harmless.
* The upstream reverse-engineering project
  ([0x4f53/ThinkPad-E14-fingerprint](https://github.com/0x4f53/ThinkPad-E14-fingerprint))
  is archived; this driver tracks the vendor DLLs, not that project.
# fingerprint-06cb-00da-debian-script
