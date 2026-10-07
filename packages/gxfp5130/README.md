# gxfp5130-stack (local package)

The **Goodix GXFP5130** scanner stack (Huawei MateBook GT 14, ENZH-XX) on Ubuntu 26.04:
kernel transport (DKMS), patched libfprint with the `gxfpmoc` driver, tools and a healthcheck.

## What is inside and where it installs

| Path | What it is |
|---|---|
| `/usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0` | libfprint from the `libfprint/` fork with the `gxfpmoc` driver + our `fdt-wait-up` patch. Shadows the system `libfprint-2-2` (in `/etc/ld.so.conf` the `/usr/local` directory comes before `/usr`) |
| `/usr/local/bin/gxfp_{capture,psk_tool,recovery}` | capture, PSK provisioning, recovery |
| `/usr/local/bin/gxfp-healthcheck` | check: the patched library is in place and loaded by `fprintd` |
| `/usr/src/gxfp-0.1.0/` | sources of the DKMS module `gxfp` (registered in postinst) |
| `/etc/udev/rules.d/60-gxfp.rules`, `/etc/systemd/system/fprintd.service.d/gxfp.conf` | access to `/dev/gxfp` for `fprintd` |
| `/usr/share/doc/gxfp5130-stack/` | this README, the `fdt-wait-up.patch` patch, expected md5 sums |

## Provenance

* upstream: `github.com/Metrohan/gxfp5130-linux`, commit `786e210e0e31828c00dd3beae1fbc008960d5555`
  (vendors the kernel driver and the libfprint fork by **Void755**);
* the local change `patches/fdt-wait-up.patch` — for firmware `GF_GCC_EC_20069`:
  1. `gxfp_fdt_flow_feed_record()`: in `WAIT_UP` mode the statuses `0x0080`/`0x0082` count as a
     "finger up" event (otherwise activation never completed and anything failed with
     `fdt wait-up retry failed: Connection timed out (-110)`);
  2. `FDT_WAIT_UP_MAX_RETRIES` `3 → 20` (~15 s): the sensor reports "finger up" after 1.4–1.8 s,
     while the 2.25 s window aborted enrollment halfway (and `fprintd` deletes the template at the
     start of an enrollment — so a failed enrollment means losing the fingerprint);
* the patch was submitted upstream: **PR #14** (<https://github.com/Metrohan/gxfp5130-linux/pull/14>).

## Dependencies and pitfalls

* `Breaks: libfprint-2-2 (>> 1:1.95.1+tod1-0ubuntu2), fprintd (>> 1.94.5-4)` — a deliberate safeguard:
  the library is built against the ABI of these versions. On an upgrade attempt apt will hold them back
  and say so; the procedure is to rebuild the stack (reinstall the package from fresh sources) and only
  then upgrade. To lift the restriction, remove the `Breaks` line in `scripts/build-packages.sh`;
* under Secure Boot the module must be signed: `mok_signing_key`/`mok_certificate` in
  `/etc/dkms/framework.conf` and a key enrolled in MOK (see `docs/04-secureboot-mok.md`).
  Without that DKMS will not build the module (`Key was rejected by service`);
* the **sensor PSK** (`/var/lib/fprintd/gxfp/psk_raw32.bin`) is not part of the package — it is per-device.
  Provisioning is done once: `sudo scripts/provision-psk.sh` from the upstream sources
  (or `--replace` if the key was already flashed, e.g. from Windows);
* `/dev/gxfp` can only be opened by a process with `CAP_SYS_ADMIN` — that is why `fprintd` runs as root,
  and the tools are launched manually via `sudo`.

## Update and rebuild

    sh scripts/build-packages.sh                 # rebuild dist/*.deb from the upstream pins
    sudo dpkg -i dist/gxfp5130-stack_*_amd64.deb # postinst rebuilds the DKMS module

The kernel module is rebuilt automatically on kernel updates (`AUTOINSTALL=yes`); our patch
lives in userspace, so a kernel update does not affect it.

## Check after installation

    gxfp-healthcheck                 # -> gxfp: OK
    fprintd-list "$USER"             # -> #0: right-index-finger (if a fingerprint is enrolled)
    fprintd-verify                   # touch the sensor

## Removal

    sudo apt remove gxfp5130-stack   # removes the DKMS module, libfprint, tools, udev/drop-in
    sudo apt purge  gxfp5130-stack   # plus the configs in /etc

Fingerprints (`fprintd-delete`) and the PSK are not removed automatically — if desired,
`sudo rm -rf /var/lib/fprintd/gxfp`.
