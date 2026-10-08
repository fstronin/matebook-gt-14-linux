# Log: what was done and when (2026-10-06 → 08, HUAWEI ENZH-XX)

Times are machine-local (EET), approximate per step.

| Time | Step | Outcome |
|---|---|---|
| 18:52 | boot, hardware diagnostics | camera and scanner detected by the kernel, but without drivers (see `01-diagnostics.md`) |
| ~19:25 | conclusion: camera is GalaxyCore GC2607 (ACPI `GCTI2607`), scanner is Goodix GXFP5130 (ACPI `GXFP5130`); no drivers in the kernel | plan: DKMS + MOK |
| 19:37 | `pkexec apt install`: `build-essential dkms meson cmake … mbedtls/opencv/glib … doctest-dev libcamera-tools`, `linux-main-modules-ipu6-7.0.0-30-generic`, `linux-main-modules-v4l2loopback-7.0.0-30-generic` | toolchain ready (`gcc`, `dkms ≥3.2`) |
| 19:38 | build as a user: `gxfp.ko`, `gc2607.ko`, `ipu-bridge.ko` against `7.0.0-30-generic` | all three built without changes |
| 19:39 | MOK key generation (`/var/lib/shim-signed/mok/`), `mok_signing_key`/`mok_certificate` in `/etc/dkms/framework.conf`, DKMS install of `gxfp`, `gc2607`, `ipu-bridge-gc2607`, libfprint fork (meson → `/usr/local`) | everything MOK-signed; `modprobe` before enrollment: `Key was rejected by service` (expected) |
| ~19:42 | queueing the key (`mokutil --import … --hash-file`, non-interactive) → **reboot** → blue `Enroll MOK` menu (password — see the author's local notes) | key enrolled, modules load |
| 19:46 | `post-reboot-setup.sh`: `modprobe gxfp/gc2607/ipu_bridge`, PSK provisioning, `fprintd-enroll` | fingerprint `right-index-finger`; `fprintd-list` sees GXFP5130 |
| 19:49 | camera: `cam -l` → "Internal front camera (`\_SB_.PC00.LNK0`)", a frame captured via libcamera (software ISP) | camera works without the Intel HAL |
| 19:56 | fingerprint login: `pam-auth-update --enable fprintd` | `pam_fprintd` first in `/etc/pam.d/common-auth`, password as fallback (verified with `sudo`) |
| 20:01 | `fix-dkms-source.sh`: `gc2607` source moved from a symlink in `/var/tmp` to the real folder `/usr/src/gc2607-0.3.1`; `gxfp` tree → root | rebuild of all three modules from permanent sources verified (as on a kernel upgrade) |
| 20:02 | created the `~/bootstrap-notes` folder with documentation | `README.md`, `01…05`, `scripts/`, `logs/`, `backups/`, `evidence/` |
| 20:10 | virtual camera for Zoom: `v4l2loopback` (`/dev/video60` "GC2607 Virtual Camera") + `v4l2-relayd`, system units disabled, user service `gc2607-vcam.service` created | device appeared in Zoom's list |
| 20:14 | pitfall #1 found: a caps filter is not allowed in `-i` (`gst_parse_launch` as one line → `no element "video"`) | `-i "libcamerasrc ! videoconvert"` |
| 20:25 | pitfall #2: without `queue` in `-o` the client got 1.7 fps (v4l2sink blocked the chain) → added `queue max-size-buffers=2 leaky=upstream` | measured: 300 frames in 10.4 s = **28.9 fps**, frames are live (md5 of neighbours differ) |
| 20:26 | check in Zoom by the user | **image smooth, issue closed** |
| 20:33 | complaint about "broken" auto-brightness: found ALS `acpi-als` → `iio-sensor-proxy` → `gsd-power` (`ambient-enabled=true`); the sensor reported 11 lx (0 in the dark) and the brightness drifted to 87/800 | `ambient-enabled=false`, brightness restored to 219 via `logind` |
| 20:37 | task: Ctrl+1 → English, Ctrl+2 → Russian. Established: `input-sources current` in GNOME 50 is "deprecated and ignored", D-Bus `Shell.Eval` is disabled, there are no stock APIs → wrote the shell extension `layout-switch@fstronin` (internal `getInputSourceManager()` + `activateInputSource(source, true)`) | extension enabled in `enabled-extensions`; a relogin is needed to load it (Wayland does not restart the shell) |

## 2026-10-07: fingerprint — 5 tries instead of one

Problem: `sudo` asked for the fingerprint **once** and fell straight through to the password.

| Time | Step | Outcome |
|---|---|---|
| 00:57 | config analysis: `/etc/pam.d/common-auth:17` → `pam_fprintd.so max-tries=1 timeout=10 # debug`; reading the `pam_fprintd` 1.94.5 source (`pam/pam_fprintd.c`) | cause: the `max_tries` counter decrements on `verify-no-match`, so with 1 try it immediately returns `PAM_MAXTRIES` → `default=ignore` → `pam_unix` → password; an expired `timeout` leaves the module with no retries |
| 00:57–00:59 | test without a physical finger: `pam_start_confdir()` + copies of the `sudo` stack with a `debug` token | journal: `debug on`, `max_tries specified as: 5`, `timeout specified as: 10 secs`; option order matters — `debug` must come first |
| 00:57–00:59 | established regarding the `# debug` in Ubuntu's line | it is an **inert** comment: libpam terminates the line at `#`, the `debug` token never reaches the module (with `# debug` — not a single line in the journal, with a plain `debug` — there are lines) |
| 00:57–00:59 | incidentally: the `success=end` line in the profile/`/var/lib/pam/auth` is a pam-auth-update pseudo-value; against a live libpam it yields `PAM pam_parse: expecting jump number` | `#` comments and `end` confirmed experimentally, in the live file `success=3` |
| 01:01:20–01:01:27 | edit via `pkexec`: `sed -i 's/max-tries=1/max-tries=5/' /etc/pam.d/common-auth /usr/share/pam-configs/fprintd` | both lines → `max-tries=5 timeout=10` |
| 01:01:50 | control run on the **already modified** stack (`pam_start_confdir` + copy with `debug`) | `pam_fprintd(sudo:auth): max_tries specified as: 5`, no parse errors, `VerifyStart` goes to `Device/0` |
| 01:05 | documentation: `05-fingerprint-login-pam.md` rewritten (number of tries, semantics of `max-tries`/`timeout`, `# debug`, polkit via `other`), edits to `README.md`, `CHANGELOG.md`, `scripts/verify-all.sh`, `/var/tmp/hw/README.md` + its copy `logs/var-tmp-hw-README.md` | see below |

Verified after the change:

```
grep fprintd /etc/pam.d/common-auth          → [success=3 default=ignore] pam_fprintd.so max-tries=5 timeout=10 # debug
grep fprintd /usr/share/pam-configs/fprintd  → [success=end default=ignore] pam_fprintd.so max-tries=5 timeout=10 # debug
journalctl (control run)                     → pam_fprintd(sudo:auth): max_tries specified as: 5
```

Expected behaviour: up to five rounds of "Place your right index finger…" on "not recognized", then
`Password:`. A timeout (no finger presented) still aborts the tries immediately — 5 tries means
5 "not recognized", worst-case pause ≈ 5 × 10 s. To check on your own machine: `sudo -k && sudo true`.
Why the live `/etc/pam.d/common-auth` is edited and not just `/usr/share/pam-configs/fprintd`
(and why `pam-auth-update` will not revert the change) — see `05-fingerprint-login-pam.md`.

## 2026-10-07 (evening): camera "disappeared" after the move to kernel 7.0.0-38

Complaint: "the webcam does not work now, again only ipu devices are available in the system".

| Time | Step | Outcome |
|---|---|---|
| 18:33 | diagnostics: `v4l2-ctl --list-devices` → only `ipu6` (`/dev/video0..47`), no `/dev/video60`; `gc2607-vcam.service` — `activating (auto-restart)`, restart counter 101 | camera is not exposed to applications |
| 18:33 | `modinfo v4l2loopback` → "Module not found"; journal: `systemd-modules-load: Failed to find module 'v4l2loopback'` (since 13:20 — the first boot on 7.0.0-38) | cause #1: the `linux-main-modules-v4l2loopback-*` package is pinned to the kernel ABI and was installed only for -30 |
| 18:35 | check that the sensor is intact: `cam -l` → `Internal front camera`; `cam -c1 -C60` → 29.9 fps; the `Intel IPU6 ISYS Capture` nodes existed on -30 as well (boot log -3) | camera and libcamera are fine, only the path into v4l2loopback is at fault |
| 18:36 | `apt install linux-main-modules-v4l2loopback-7.0.0-38-generic` (7.0.0-38.38), `modprobe v4l2loopback`, restart of the user service | `/dev/video60` "GC2607 Virtual Camera", 1280×720 YUYV, service `active` |
| 18:37–18:50 | the client gets 1.8–3.3 fps instead of ~29. Isolation: camera directly — 27.7 fps (166 frames in 6 s), loopback with `videotestsrc ! v4l2sink` — 30 fps, all three `-o` variants (no `queue` / `leaky=downstream` / `leaky=upstream`) — 3.3 fps | cause #2 — inside the relayd → basesink chain |
| 18:50 | `GST_DEBUG=appsrc:5,appsink:5,v4l2sink:4,basesink:4`: 292 buffers in 20 s; `basesink: A lot of buffers are being dropped`, `There may be a timestamping problem, or this computer is too slow` | `v4l2sink` synchronizes output to the clock and drops relayd buffers (`appsrc is-live=true format=DEFAULT`) as late |
| 18:51 | unit edit: `v4l2sink … sync=false` (+ copy `scripts/gc2607-vcam.service`) | 26.4 fps |
| 18:52 | verification: `gst` client 300 frames in 10.5 s (28.6 fps), `v4l2-ctl --stream-count=200` → 27.97 fps, 59/60 unique jpeg frames, no basesink warnings | defect closed |
| 18:52 | boot simulation: `modprobe -r v4l2loopback` → `systemctl restart systemd-modules-load` → `Inserted module 'v4l2loopback'`, `/dev/video60` with the right label | will come up by itself after a reboot |
| 18:55 | documentation: the kernel-ABI warning and the `sync=true` pitfall in `03-camera-gc2607.md`, section 8 in `scripts/verify-all.sh`, edits to `README.md` | — |

The same failure bisected by layer (all measurements with the client `v4l2src device=/dev/video60 ! fakesink`):

```
camera (libcamerasrc → YUY2 1280x720 → jpeg)      27.7 fps   ← source is fine
loopback (videotestsrc → v4l2sink → client)       30.0 fps   ← loopback is fine
relayd (-o without queue / leaky=downstream / upstream) 3.3 fps   ← basesink synchronization
relayd (-o … + v4l2sink sync=false)               26.4 fps   ← the fix
```

## 2026-10-07 (evening, 2): camera colour — CCM enabled

Complaint: "the camera works, but the colours are all greenish and pale".

| Time | Step | Outcome |
|---|---|---|
| 20:26 | frame measurement: linear means R=0.2476 G=0.2563 B=0.2256 (G/B=1.137), saturation 0.119; in `uncalibrated.yaml` the `Ccm` algorithm is commented out, AWB in the simple IPA is grey-world over sensor sums | cause: sensor primaries ≠ sRGB, no CCM |
| 20:30 | relayd path check: YUY2 round-trip on synthetic colours (white 253/253/253, red 252/0/0, blue 0/0/250) — matches the gst reference | the YUY2 path does not spoil colours, the ISP is at fault |
| 20:33 | sweep of `blackLevel` in the tuning file (16/32/48/64/96) | 32 already over-subtracts (78/90/59, saturation 0.40) — the key is not set, auto-guessing is kept |
| 20:37 | `scripts/derive-ccm.py`: `D = diag(1.0353, 1.1370)` (neutrality) + `S(0.5)` (saturation) → `/usr/share/libcamera/ipa/simple/gc2607.yaml`, copy `scripts/gc2607.yaml` | libcamera: `Using tuning file …/gc2607.yaml` |
| 20:38 | A/B on the same path (`/dev/video60`, `evidence/color-{before,after}.jpg`) | saturation 0.090 → **0.118** (+31 %), neutrality G/R 1.031 → **1.009**, G/B 1.136 → **1.026** |
| 20:38 | cost and clipping check | 27.6 fps, clipping 0.01 %/0.2 %, `v4l2-relayd` ~10 % of one core |

Directly through `libcamerasrc` the residual shift disappears completely (G/R=1.003, G/B=0.994),
saturation 0.119 → 0.175. Details and limitations — `03-camera-gc2607.md`, section
"Colour: the `gc2607.yaml` tuning file (CCM)".

Additionally (the question "will it survive a restart"): an `ExecStartPre` was added to the user
service that waits for `/dev/video60` for up to 10 s. Previously the first attempt on login failed
(a race with device/ACL creation) and systemd brought the service up only after 2 s — now the camera
is there right away. A simulated system boot (unload the module → `systemctl restart systemd-modules-load`
→ start the service) gave `NRestarts=0` and zero errors in the journal; the colour after it is the same
(G/R=1.011, G/B=1.024 on the app path), 27.2 fps. A real reboot was not performed.

## 2026-10-07 (evening, 3): eGPU + scanner fix (FW 20069) + local package + PR

| Time | Step | Outcome |
|---|---|---|
| ~18:30–19:00 | eGPU (WIKO Hi GT Cube, RX 7600M XT): port and cable sweep, ACPI analysis (`SSDT13 TcssSsdt`, `SSDT21 UsbCTabl`, `SSDT25 xh_mtlp4`) and live GNVS reads via `acpi_call` (`TP1D=0x05`, `TP4D=0x1d`; `TDM0` disabled, `TDM1`/`TRP3` enabled; `UCMS=0`) | the ports are distinguishable: the **far** Type-C = Thunderbolt 4, the one near the jack = plain USB-C (an eGPU will not come up there) |
| ~19:00–19:30 | false leads and their rollback: `pcie_port_pm=off`, a D0 udev rule for TB PCI, `thunderbolt host_reset=0`, loading `typec/ucsi_acpi/intel_pmc_mux`, trying `thunderbolt.force_power` | did not help (**everything rolled back**, the system is stock); the cause was a stuck dock, not the kernel. `/sys/class/typec` is empty — the firmware exposes UCSI as disabled |
| 19:32 | the dock came alive: a full power cycle of the Cube (unplug the 140 W adapter for a minute) + cold boot | the TB link came up: `boltctl` → Hi GT Cube (authorized, stored, 40 Gbit/s = 2×20), `lspci` → `06:00.0 [1002:7480]`, `amdgpu` picked it up by itself (nothing needs to be installed) |
| 19:33–19:36 | an external monitor on the dock would not come up: mutter does not take outputs of the "hot" GPU (`Mutter.DisplayConfig` only saw `eDP-1`), forced `uevent`s did not help | the fix — boot/relogin with the dock **already connected**; after a reboot `card0-DP-4` is visible and the picture is there. Also, the card's BAR stays at 256 MB (normal for a TB3 tunnel) |
| 19:37 | game offload: `DRI_PRIME=pci-0000_06_00_0 VK_LOADER_DRIVERS_SELECT='*radeon*'` (what GNOME/`switcheroo` sets too), wrapper `~/.local/bin/egpu-run` | `vkcube` → "Selected GPU 0: AMD Radeon RX 7600M XT (RADV NAVI33)" on Wayland; `glxinfo -B` → `radeonsi, navi33, ACO` |
| 19:10–21:35 | the scanner stopped working: `fdt wait-up retry failed: Connection timed out (-110)` on any activation. A hexdump probe of `/dev/gxfp` + reading the code | root cause: FW `GF_GCC_EC_20069` answers `FDT_UP` with status **`0x0082`**, which the driver ignored in `WAIT_UP` mode; plus a 2.25 s release window against a real 1.4–1.8 s |
| 21:36–21:45 | two minimal edits in **both** copies of `fdt.c` (+ test), rebuild, 17/17 enrollment | `fprintd-verify` → `verify-match` (the first "no-match" failure was due to incomplete contact). Incidentally: the enrollment that died at 19:32 wiped the template (fprintd deletes it **at the start** of enrollment) — the fingerprint was enrolled again |
| 21:40–21:43 | the patch was frozen as a `diff -u` against the pinned commit `786e210` (+ copies of the files, reference md5s) and scripts `gxfp-rebuild.sh` / `gxfp-build-deb.sh` | reproducibility and protection against patch loss (the working tree in `/var/tmp` is cleaned after 30 days) |
| 21:44–21:45 | local package `gxfp5130-stack 0.1.0+localpatch1` (96 files, 712 KB): patched libfprint + utilities + DKMS sources + udev/drop-in; `Depends` from real `ldd`, `Breaks` on newer `libfprint-2-2`/`fprintd`; `gxfp-healthcheck` + user timer | scanner stack under dpkg control; a weekly check catches an ABI change/library substitution |
| 21:48 | patch proposed upstream: fork `fstronin/gxfp5130-linux`, branch `fix/fdt-wait-up-fw-20069` | **PR #14** — https://github.com/Metrohan/gxfp5130-linux/pull/14 (open, +45/−3) |
| 21:56–21:59 | the same approach for the camera: script `scripts/gc2607-build-deb.sh` + `scripts/cam-healthcheck`, package **`gc2607-camera-stack 0.3.1+localpatch1`** (37 KB): both DKMS modules, the `Ccm` tuning file, user units `gc2607-vcam.service` + `cam-healthcheck.{service,timer}`, docs with the `ipu-bridge-vs-v7.0.patch` diff | `Depends: dkms, kmod, libcamera-ipa`, `Recommends: v4l2-relayd`; the libcamera version is not pinned (a silent breakage is not critical here — the healthcheck suffices) |
| 22:00 | package installation: postinst rebuilt both DKMS modules for `7.0.0-38`; user units moved to `/usr/lib/systemd/user/` and enabled globally (`systemctl --global enable`), the personal copy from `~/.config` removed (backup — `backups/gc2607-vcam.service.bak`) | `dpkg -S` confirms ownership of the tuning file, units, `cam-healthcheck` and both trees in `/usr/src`; `FragmentPath=/usr/lib/systemd/user/gc2607-vcam.service`, service `active`, `/dev/video60` alive |

## Final state (camera — 18:52, PAM — 01:01, scanner — 21:45, eGPU — 19:37)

```
dkms status            → acpi-call, gxfp, gc2607, ipu-bridge-gc2607, hwlogo — installed (kernels -30 and -38)
lsmod                  → gxfp, gc2607, ipu_bridge, v4l2loopback, hwlogo loaded
lsmod | grep v4l2loopback → loaded (package linux-main-modules-v4l2loopback-7.0.0-38-generic, ABI-dependent!)
fprintd-list fstronin  → GXFP5130 (press): #0 right-index-finger
grep fprintd /etc/pam.d/common-auth → pam_fprintd.so max-tries=5 timeout=10 # debug
cam -l                 → Internal front camera (\_SB_.PC00.LNK0)
grep 'Using tuning file' (IPAProxy:DEBUG) → /usr/share/libcamera/ipa/simple/gc2607.yaml (CCM)
scripts/derive-ccm.py measure → linear G/R≈1.00, G/B≈1.00 (directly), on the app path G/R=1.009 G/B=1.026
v4l2-ctl --list-devices→ GC2607 Virtual Camera → /dev/video60
gst client /dev/video60→ 300 frames in 10.5 s = 28.6 fps (v4l2sink … sync=false)
systemctl --user       → gc2607-vcam.service active + enabled (ExecStartPre waits for /dev/video60)
mokutil --sb-state     → SecureBoot enabled (modules are signed and load)
fprintd-verify         → verify-match (after the fdt.c fix; see 02-fingerprint-gxfp5130.md)
gxfp-healthcheck       → gxfp: OK — patched libfprint is in place and loaded by fprintd (timer gxfp-healthcheck.timer — enabled)
dpkg -l gxfp5130-stack → ii 0.1.0+localpatch1 (scanner stack under dpkg control; patch — upstream PR #14)
boltctl list           → WIKO Hi GT Cube: authorized + stored; lspci → 06:00.0 [1002:7480] (eGPU, 08-egpu-hi-gt-cube.md)
```

`fprintd` may show `inactive` — it is started over D-Bus on first access (this is normal).

## What was left unused

- The Intel camera stack (`ipu6-camera-hal`, `icamerasrc`, `ipu6-drivers`/PSYS) — cloned into
  `/var/tmp/hw`, not needed: libcamera + software ISP were enough. Kept as a fallback.
- The package `linux-main-modules-ipu6-7.0.0-30-generic` (Canonical-signed `intel-ipu6-psys` and
  sensor modules) is installed but not used in the current setup.
- The system units `v4l2-relayd.service` / `v4l2-relayd@gc2607.service` are disabled (the user
  service replaces them).
- Camera: the `gc2607.yaml` tuning file **is installed** as of 2026-10-07 (CCM: neutrality + saturation),
  but it has no chart-based calibration — the matrix was derived self-consistently (`scripts/derive-ccm.py`);
  the driver does not expose selection rectangles; `dovdd/dvdd` are dummy regulators.

## 2026-10-08: review on PR #14 — the vendored copy of the retry test

The maintainer requested changes: the PR raised `FDT_WAIT_UP_MAX_RETRIES` 3 → 20 and updated
`userspace/tests/fdt_retry_test.c`, but left `libfprint/libfprint/drivers/gxfpmoc/tests/fdt_retry_test.c`
stale — with `BUILD_TESTING=ON` the vendored `gxfp_fdt_retry_policy` claim fails, because
`gxfp_fdt_flow_wait_up_retry_due()` returns 1, not `-ETIMEDOUT`, for `wait_up_retries = 3`.

Reproduced at the reviewed commit `7bd05e5` (vendored CMake project, `BUILD_TESTING=ON`): assertion
`== -ETIMEDOUT` fails, exit 134. Fixed in `dece944`: the vendored test uses the budget `20`, and both
copies additionally assert that `3` is **still retryable** — that assertion fails if the constant is
lowered back, so it guards the budget itself, while `20` only pins the new expiry point. `ctest` passes
in both trees (`userspace/` and `libfprint/libfprint/drivers/gxfpmoc/`, target `gxfp_fdt_retry_policy`).

Runtime code is untouched (tests only), so nothing had to be rebuilt or reinstalled.
`patches/fdt-wait-up.patch` and the `bootstrap-notes` evidence snapshot were re-synced with the PR head:
the patch now carries four files and reproduces `dece944` byte-for-byte when applied to the pinned
upstream `786e210`.
