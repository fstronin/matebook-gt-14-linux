# 02. Goodix GXFP5130 fingerprint reader

## What this hardware is

- ACPI device `GXFP5130:00` (`\_SB_.SPBA`); there is no in-kernel Linux driver for it —
  `fprintd-list` answers "No devices available".
- The sensor is not accessible directly: commands go through the **eSPI mailbox EC** (0xFE800000) + a GPIO handshake;
  the kernel module creates a character device `/dev/gxfp` (`10:262`), and userspace talks to it.
- Provisioning: TLS-PSK, the key (32 bytes) is stored in `/var/lib/fprintd/gxfp/psk_raw32.bin`.

## Source

`github.com/Metrohan/gxfp5130-linux`, commit `786e210e0e31828c00dd3beae1fbc008960d5555`
(the libfprint fork `Void755/libfprint` is vendored into it).
The local patch for firmware `GF_GCC_EC_20069` — see the section "2026-10-07: fixed …" below;
it has also been sent upstream: **PR https://github.com/Metrohan/gxfp5130-linux/pull/14**
(fork `fstronin/gxfp5130-linux`, branch `fix/fdt-wait-up-fw-20069`).

## Installation procedure (what was actually done)

```sh
# 0. packages: compiler, DKMS, cmake/meson, mbedtls, glib, gusb, pixman, nss, cairo, opencv, doctest
#    full list — see the dependency checks in scripts/install.sh (the one-off first-install log
#    is not shipped in this repository)

# 1. sources
curl -sL -o gxfp.tar.gz https://codeload.github.com/Metrohan/gxfp5130-linux/tar.gz/refs/heads/main && tar xzf gxfp.tar.gz

# 2. build as user (check that it compiles under 7.0.0-30)
make -C kernel -j22                                   # → kernel/gxfp.ko
cmake -S userspace -B build/userspace -DCMAKE_BUILD_TYPE=Release && cmake --build build/userspace -j22

# 3. DKMS + userspace + udev + drop-in (root) — the upstream project's script, run from inside
#    the cloned sources (this repository fetches them into build/upstream/gxfp/):
sudo scripts/install.sh        # copies kernel/ → /usr/src/gxfp-0.1.0, dkms build/install,
                               # installs gxfp_capture|gxfp_psk_tool|gxfp_recovery into /usr/local/bin,
                               # 60-gxfp.rules, fprintd.service.d/gxfp.conf

# 4. libfprint fork (otherwise the distro libfprint has no gxfp driver)
meson setup build/libfprint libfprint --wipe --prefix=/usr/local --libdir=lib/x86_64-linux-gnu \
      -Ddrivers=gxfp -Ddoc=false -Dintrospection=false -Dgtk-examples=false \
      -Dudev_rules=disabled -Dudev_hwdb=disabled
meson compile -C build/libfprint -j22 && sudo meson install -C build/libfprint && sudo ldconfig
# the driver is compiled into the library (not separate .so files), /usr/local comes before /usr
#   → ldd /usr/libexec/fprintd | grep libfprint  ⇒ /usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2

# 5. queue the MOK key for enrollment + reboot (see 04-secureboot-mok.md)

# 6. PSK provisioning and check
sudo modprobe gxfp                       # until the MOK key is enrolled: "Key was rejected by service"
sudo scripts/provision-psk.sh            # upstream script (build/upstream/gxfp/scripts/provision-psk.sh);
                                         # uploads the key; if the sensor was already provisioned — --replace
sudo gxfp_capture --psk-raw32 /var/lib/fprintd/gxfp/psk_raw32.bin   # check the TLS session (finger)
fprintd-list $USER                       # → Fingerprints for user … GXFP5130 (press) … right-index-finger
fprintd-enroll && fprintd-verify
```

Since 2026-10-07 the stack is installed and updated as the **local package `gxfp5130-stack`** (see the
section "Package `gxfp5130-stack`" below) — the steps below remain as the history of the first install
and as the rebuild path, should the package ever need to be built again.

## Pitfalls (verified in practice)

- **`/dev/gxfp` is root-only**: `gxfp_uapi_open()` contains `if (!capable(CAP_SYS_ADMIN)) return -EPERM;`
  Therefore `open()` from a user gives `EPERM`, and the `uaccess` ACL from the udev rule is useless.
  `fprintd` runs as root — that is enough.
- **A single reader**: if a reader is already open, the driver returns `-EBUSY`. If `gxfp_capture` is
  running, `fprintd-enroll` fails with `open(/dev/gxfp) failed: Device or resource busy`.
  Check the holder: `fuser -v /dev/gxfp`; kill a stuck `gxfp_capture` with `kill -9`
  (it ignores SIGTERM while it is blocked on a read from the sensor).
- **Before the MOK key is enrolled** the module does not load: `modprobe gxfp` → `Key was rejected by service`
  (this is expected: the module is already signed, but the key is not yet in NVRAM).
- Fingerprint enrollment works only with your finger: press it flat, in the center; some
  firmwares are sensitive to the touch area (see the upstream README).

## Verification (expected output)

```sh
lsmod | grep gxfp                          # gxfp 249856 0/1
ls -l /dev/gxfp                            # crw-rw----+ root root 10, 262
fprintd-list $USER                         # Goodix GXFP5130 eSPI Fingerprint Sensor (press), #0: right-index-finger
journalctl -k -b | grep -i gxfp
gxfp-healthcheck                           # → gxfp: OK — patched libfprint is in place and loaded by fprintd
dpkg -l gxfp5130-stack                     # → ii gxfp5130-stack 0.1.0+localpatch1
dpkg -S /usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0   # → gxfp5130-stack
systemctl --user is-active gxfp-healthcheck.timer              # → active (checked once a week)
```

## 2026-10-07: fixed `fdt wait-up retry failed: Connection timed out`

Symptom: `fprintd-enroll` / `fprintd-verify` / `gxfp_capture` failed after ~13 s **before** the
prompt to touch the finger. PSK provisioning, the ACK commands and the transport all worked.

### Root cause (measured on the raw `/dev/gxfp` wire)

Firmware `GF_GCC_EC_20069` on a "fresh" sensor answers an armed `FDT_UP` (0x34) with a record whose
status is **0x0082**, not the expected 0x0200:

```
TX 36 23 00 09 01 00*24 00*8 47                    FDT_MODE(0x36)
TX 34 23 00 0a 01 00*24 00*8 48                    FDT_UP(0x34)
RX b0 03 00 36 05 bc   /   RX b0 03 00 34 05 be    ACK
RX 34 11 00 82 00 06 00 06 00 06 00 06 00 06 00 06 00 06 00 b9    status 0x0082
```

`fdt_status_to_events()` in `userspace/src/flow/fdt.c` treats 0x0080/0x0082 as
`GXFP_FDT_EVENT_REVERSE`, and `gxfp_fdt_flow_feed_record()` reacts to REVERSE **only** in
`WAIT_DOWN` mode. In `WAIT_UP` the record is simply swallowed → `state != UP` → 3 retries of 750 ms →
`-ETIMEDOUT` → the error text from `src/flow/session.c:673`. At the same time the same file, in
`fdt_base_table_update_from_frame()`, already treats 0x0080/0x0082 as equivalent to 0x0200
("finger is up, here is the down baseline") — all that was missing was the mapping to an event.

Status map, captured after the fix (one continuous session):

| status | when it arrives | meaning |
|---|---|---|
| `0x0082` | reply to `FDT_UP`, finger has not been pressed yet | "no finger" (idle) |
| `0x0002` | reply to `FDT_DOWN` on a press | finger pressed + touchflag + up baseline |
| `0x0200` | after the finger is lifted; on a "warmed-up" sensor — also on idle | finger lifted + down baseline |

### What was changed (two edits, in both twin files)

Files: `userspace/src/flow/fdt.c` **and** `libfprint/libfprint/drivers/gxfpmoc/src/flow/fdt.c`
(the copies are byte-for-byte identical — both must be edited).

1. `gxfp_fdt_flow_feed_record()`: in `WAIT_UP` mode, statuses 0x0080/0x0082 additionally yield
   `GXFP_FDT_EVENT_UP`. Without this the activation never completes at all.
2. `FDT_WAIT_UP_MAX_RETRIES 3 → 20` (the window for lifting the finger, ~2.25 s → ~15 s). Measurement:
   the sensor reports "finger lifted" after 1.4–1.8 s even if the finger is lifted instantly, so
   enrollment aborted at stage 11 of 17 — and by that time fprintd had already erased the template.
   Along with this, both copies of `fdt_retry_test.c` (`userspace/tests/` and
   `libfprint/libfprint/drivers/gxfpmoc/tests/`) raise the test budget to `20`
   (`flow.wait_up_retries = 20`) and additionally assert that `3` is still retryable — that assertion
   fails if the budget is lowered back, so it guards the budget itself, while `20` only pins the new
   expiry point.

### Rebuild and install

```sh
cd build/gxfp                                         # tree fetched+patched by scripts/build-packages.sh --no-fetch
cmake --build build/userspace -j"$(nproc)"           # gxfp_capture/psk_tool/recovery + unit test
./build/userspace/gxfp_fdt_retry_test                # must pass
sudo systemctl stop fprintd
sudo meson compile -C build/libfprint -j"$(nproc)"   # build/libfprint is owned by root
sudo meson install -C build/libfprint && sudo ldconfig
for t in gxfp_capture gxfp_psk_tool gxfp_recovery; do
  sudo install -o root -g root -m0755 build/userspace/$t /usr/local/bin/$t
done
sudo systemctl start fprintd
```

The kernel module was **not changed**: there is no need to rebuild DKMS/`gxfp.ko`, and on a kernel
upgrade it is rebuilt normally from `/usr/src/gxfp-0.1.0` (the changes are only in userspace/libfprint).

### Package `gxfp5130-stack` — the canonical way to install and remove

Since 2026-10-07 the entire stack (patched libfprint + tools + kernel sources for DKMS + the udev rule
and the fprintd drop-in) is managed by a local `.deb`: system updates do not overwrite it, and removal
and accounting are handled by `dpkg`/`apt`.

| What | Where |
|---|---|
| Package | `gxfp5130-stack 0.1.0+localpatch1` — `dist/gxfp5130-stack_0.1.0+localpatch1_amd64.deb` |
| Build/rebuild of the package | `sh scripts/build-packages.sh` (fetches the upstreams at the pinned commits, applies `patches/fdt-wait-up.patch`, verifies the expected md5 sums and packages both `.deb`s into `dist/`; an unpatched build will not make it into the package) |
| Install | `sudo ./scripts/install.sh` (or `sudo dpkg -i dist/gxfp5130-stack_*_amd64.deb`) |
| Health check | `gxfp-healthcheck` + user timer `gxfp-healthcheck.timer` (weekly; on a problem — a notification with the repair command) |
| Patch and expected md5 | `patches/fdt-wait-up.patch`; the manifest ships in the package as `/usr/share/doc/gxfp5130-stack/expected-md5.txt` |
| Package README (provenance, patch, update procedure) | `/usr/share/doc/gxfp5130-stack/README.md` |

The package declares `Depends` from the real `ldd` dependencies and `Breaks: libfprint-2-2 (>> 1:1.95.1+tod1-0ubuntu2),
fprintd (>> 1.94.5-4)`: if the distribution tries to upgrade those packages, apt holds them back and says so —
this is protection against a "silent" revert, where a new fprintd would load the system libfprint.
The update procedure is therefore: rebuild the stack (`sh scripts/build-packages.sh`), install it
(`sudo ./scripts/install.sh --skip-build`), and only then upgrade.

Useful commands: `dpkg -L gxfp5130-stack` (what belongs to the package), `dpkg -S <file>` (who owns a
file), `sudo apt remove gxfp5130-stack` (remove the stack, configs in `/etc` stay),
`sudo apt purge gxfp5130-stack` (together with the configs).

### Rolling back the patch

If the stack is installed as the package (the normal case):

```sh
sudo apt remove gxfp5130-stack      # DKMS module + libfprint + tools + udev/drop-in
sudo apt purge  gxfp5130-stack      # plus the /etc configs
```

A full rollback "as it was before the patch" — from a backup of the pre-patch binaries
(`libfprint-2.so.2.0.0`, `gxfp_capture`, `gxfp_psk_tool`, `gxfp_recovery`) taken before installing
(no such backup is shipped in this repository): put them back into `/usr/local/lib/x86_64-linux-gnu/`
and `/usr/local/bin/`, then `sudo ldconfig` (remove the package first, otherwise dpkg will consider
the files its own).

Or restore the sources: in both copies of `fdt.c` delete the block
`if ((events & GXFP_FDT_EVENT_REVERSE) && flow->mode == GXFP_FDT_MODE_WAIT_UP)` and revert
`FDT_WAIT_UP_MAX_RETRIES` to `3` (+ the literal in both tests), then rebuild the same way.

### Side effect of the bug: a lost fingerprint

fprintd deletes the finger template **at the start** of enrollment. The enrollment at 19:32:23 failed on exactly
this error → the directory `/var/lib/fprint/fstronin/gxfp/0` disappeared, `fprintd-list` started answering
"no fingers enrolled", and `fprintd-verify` — `NoEnrolledPrints: Failed to discover prints`.
It looks like a separate storage breakage, but it is the same bug. The cure is to enroll again:
`sudo fprintd-enroll -f right-index-finger fstronin`.

### Enrollment rhythm (important)

**touch the finger → hold for ~1 s → lift immediately → pause ~1 s → repeat (17 times).**
`fprintd-enroll` does not print "lift your finger" (only `Enroll result: enroll-stage-passed`, and only
after the fact), so you cannot wait for a prompt.

### Separate note: the kernel trace is unavailable under Secure Boot

`echo 1 > /sys/kernel/debug/gxfp/trace_enable` gives `EPERM` even as root: with
`lockdown=integrity`, `debugfs_locked_down()` (fs/debugfs/file.c) returns `-EPERM` for any debugfs
file whose mode is not strictly `0444`. `trace_dump` (0400) is readable, while `trace_enable`
(0600) and `trace_clear` (0200) are not. Workaround: build the module with `GXFP_TRACE_DEFAULT_ENABLE 1`
(`kernel/driver/gxfp_trace.c`) or add a module parameter. The advice from the upstream README does not
work on a locked-down kernel.

### How this was found (method)

The entire exchange can be dumped at exactly two points in userspace: `gxfp_dev_send_packet()` and
`gxfp_dev_read_record()` in `userspace/src/io/dev.c` — both TX and RX go through them. Plus the
`gxfp-irq` counter in `/proc/interrupts` (it shows whether replies arrive at all).
The fix itself is the numbered patch `patches/fdt-wait-up.patch` (sent upstream as PR #14, see above).

## Rollback

```sh
sudo apt remove gxfp5130-stack      # scanner stack: DKMS module + libfprint + tools + udev/drop-in
sudo apt purge  gxfp5130-stack      # plus /etc configs (udev rule, fprintd drop-in)
sudo reboot
```

If the package is not on the system (the stack was installed manually): `sudo dkms remove gxfp/0.1.0 --all`,
`sudo rm -rf /usr/local/lib/x86_64-linux-gnu/libfprint-2* /usr/local/bin/gxfp_*`,
`sudo rm -f /etc/udev/rules.d/60-gxfp.rules /etc/systemd/system/fprintd.service.d/gxfp.conf`,
then `sudo ldconfig && sudo depmod -a && sudo systemctl daemon-reload && sudo reboot`.

Fingerprints (`fprintd-delete`) and the PSK are not removed automatically — if desired,
`sudo rm -rf /var/lib/fprintd/gxfp`.
