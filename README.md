# HUAWEI MateBook GT 14 (ENZH-XX): Linux enablement — notes, patches, local packages

Everything needed to make the *HUAWEI MateBook GT 14 (ENZH-XX, Meteor Lake)* work under
Ubuntu 26.04 with kernel 7.0.0-38, as patches plus two buildable local `.deb` packages:
the fingerprint reader and the webcam. Plus documentation for the rest of the laptop:
diagnostics, Secure Boot + MOK, PAM fingerprint login, auto-brightness (ALS), keyboard
layout switch, and eGPU/Thunderbolt experiments.

None of this is forking for the sake of forking: upstreams are pinned to **exact commits**
and our changes are minimal patches on top of them.

## TL;DR

Checks first, then build + install, removal last — details in **Quick start** below:

```sh
sudo ./scripts/install.sh --dry-run     # hardware/deps/Secure Boot checks only
sudo ./scripts/install.sh               # fetch + patches + build + install + healthchecks
sudo ./scripts/uninstall.sh [--purge]   # remove
```

No secrets are stored here — the fingerprint sensor PSK and the MOK key are per-device.
This repo is not affiliated with Huawei, Goodix, GalaxyCore or the upstream projects; see `NOTICE`.

## What gets fixed, and how

| Device | Symptom in stock Ubuntu | What this repository does |
|---|---|---|
| Fingerprint Goodix GXFP5130 (eSPI) | reader not visible, `libfprint` without the `gxfpmoc` driver | DKMS module `gxfp`, a libfprint fork with our `fdt-wait-up` patch (firmware `GF_GCC_EC_20069`), tools, PSK provisioning |
| Camera GalaxyCore GC2607 (IPU6) | no camera in the media graph | DKMS modules `gc2607` and `ipu-bridge-gc2607` (ACPI HID `GCTI2607`) |
| Same camera, colour | greenish, washed-out picture | tuning file `gc2607.yaml` with a `Ccm` matrix (the stock `uncalibrated.yaml` ships `Ccm` commented out) |
| Webcam for applications | apps see only the raw IPU6 nodes | user unit `gc2607-vcam.service` (`libcamerasrc` → v4l2loopback `/dev/video60`) |
| External GPU / Thunderbolt | — | documentation only (`docs/08`): no drivers needed, everything is already in the kernel and Mesa |

## Requirements

* Ubuntu **26.04**, kernel **7.0.0-38-generic** (the kernel version matters: some packages are ABI-pinned);
* to build: `build-essential dkms meson ninja-build cmake patch curl`;
  for the camera additionally `libcamera-tools`, for the virtual camera — `v4l2-relayd` and
  `linux-main-modules-v4l2loopback-$(uname -r)`, for fingerprint login — `libpam-fprintd`;
* with **Secure Boot** — a MOK key enrolled in the firmware, and `mok_signing_key`/`mok_certificate`
  in `/etc/dkms/framework.conf`; the procedure is in `docs/04-secureboot-mok.md`.
  Without this DKMS will not build the modules ("Key was rejected by service").

## Quick start

```sh
git clone https://github.com/fstronin/matebook-gt-14-linux.git
cd matebook-gt-14-linux

sudo ./scripts/install.sh --dry-run   # checks: model, dependencies, Secure Boot, loopback
sudo ./scripts/install.sh             # build packages + install + healthcheck
```

The installer: (1) verifies the DMI model `ENZH-XX` (otherwise only with `--force`), (2) checks
dependencies and Secure Boot, (3) fetches upstreams at the pinned commits and applies the patches,
(4) builds and installs `dist/gxfp5130-stack_*_amd64.deb` and `dist/gc2607-camera-stack_*_amd64.deb`,
(5) runs `gxfp-healthcheck` and `cam-healthcheck` and prints what is left to do by hand.

Flags: `--dry-run` (checks only), `--skip-build` (use the ready `.deb` files from `dist/`),
`--force` (allow a different model). The `JOBS=N` variable sets build parallelism.

## Steps that cannot be automated

1. **Fingerprint sensor PSK** — per-device, not shipped in the package (and it must not be):
   `cd build/upstream/gxfp && sudo ./scripts/provision-psk.sh` (or `--replace` if the sensor
   is already provisioned, for example from Windows).
2. **Enrollment:** `fprintd-enroll -f right-index-finger "$USER"`, then `fprintd-verify`.
   Sensor rhythm: place the finger → ~1 s → remove → ~1 s pause (details in `docs/02`).
3. **MOK** — with Secure Boot (see above), before the first DKMS build.
4. Fingerprint login/sudo via PAM — optional: `docs/05-fingerprint-login-pam.md`.

## Verification

```sh
gxfp-healthcheck && cam-healthcheck          # both must say OK
cam -l                                       # Internal front camera (\_SB_.PC00.LNK0)
LIBCAMERA_LOG_LEVELS=IPAProxy:DEBUG cam -l 2>&1 | grep 'Using tuning file'   # -> gc2607.yaml
systemctl --user is-active gc2607-vcam.service
```

What was actually measured on this machine (details and methods are in `docs/`):

* fingerprint: `fprintd-verify` → `verify-match` for `#0: right-index-finger`; before the patch
  activation aborted with `fdt wait-up retry failed: Connection timed out (-110)`;
* camera/colour: application through `/dev/video60` — G/B ratio 1.136 → 1.026, saturation
  0.090 → 0.118; direct libcamera path — saturation 0.119 → 0.175 (clipping ~2 %);
* virtual camera: 26–28.6 fps (2–5 fps before the `sync=false` fix);
* external GPU (RX 7600M XT in a Thunderbolt dock): `vkcube` → "RADV NAVI33", offload with
  `DRI_PRIME=pci-0000_06_00_0` — see `docs/08`.

## Repository layout

```
docs/                 01-diagnostics.md         what the hardware is, how to read logs/ACPI
                      02-fingerprint-gxfp5130.md reader: device, DKMS, patch, PSK, debugging
                      03-camera-gc2607.md        camera: IPU6, tuning file, CCM, virtual camera
                      04-secureboot-mok.md       Secure Boot, signing DKMS with a MOK key
                      05-fingerprint-login-pam.md  fingerprint login and sudo (pam-auth-update)
                      06-auto-brightness-als.md  auto-brightness from the ambient-light sensor
                      07-layout-switch.md        keyboard layout switch (XKB/IBus)
                      08-egpu-hi-gt-cube.md      external GPU over Thunderbolt: what works, what does not
patches/              fdt-wait-up.patch          patch against upstream gxfp5130-linux (PR #14)
                      ipu-bridge-GCTI2607.patch  ipu-bridge diff against torvalds v7.0
                      gc2607.yaml                libcamera simple-IPA tuning file with Ccm
                      derive-ccm.py              recompute the Ccm matrix without a chart (grey-world)
packages/gxfp5130/    README.md, gxfp-healthcheck, 60-gxfp.rules, fprintd-gxfp.conf
packages/gc2607/      README.md, cam-healthcheck, gc2607-vcam.service
scripts/              build-packages.sh          fetch + patches + build + dpkg-deb → dist/
                      install.sh                 checks + build + install + healthcheck
                      uninstall.sh               package removal
```

Technical details, the provenance of each package, the `Breaks` caveats and the upgrade
order are in `packages/*/README.md` and the corresponding `docs/`.

## Caveats

* **This model only.** The Thunderbolt ports, the camera ACPI nodes (`\_SB_.PC00.LNK0`), the `Ccm`
  matrix and the sensor PSK are all characteristics of this specific unit/model. On another model,
  read `docs/` and re-verify.
* **No secrets here**, and none will ever land here: the sensor PSK, the MOK key (`MOK.priv`) and
  fingerprints are not added to the repository.
* Kernel versions: after a kernel update the DKMS modules rebuild themselves, but
  `linux-main-modules-v4l2loopback-$(uname -r)` has to be installed — otherwise `/dev/video60`
  disappears (postinst prints the exact command, `cam-healthcheck` catches it).
* The fingerprint package declares `Breaks: libfprint-2-2 (>> …), fprintd (>> …)` deliberately:
  the library is built against a specific ABI. The order is: rebuild the stack from a fresh source,
  then upgrade (see `packages/gxfp5130/README.md`).

## Licenses and credits

Upstream code keeps its own licenses; our scripts and patches are GPL-2.0 (`LICENSE`),
the library part is LGPL-2.1 (`LICENSE.LGPL-2.1`). Provenance, authors and project links are in
`NOTICE`. The project is not affiliated with Huawei, Goodix, GalaxyCore or the upstream authors.
