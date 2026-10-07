# 03. GalaxyCore GC2607 webcam

## What this hardware is

- Sensor **GalaxyCore GC2607**, ACPI HID `GCTI2607`, node `\_SB_.PC00.LNK0`, I2C client
  `i2c-GCTI2607:00` (address 0x37 on i2c-3 → the subdev is called `gc2607 3-0037`).
- MIPI CSI-2, 2 lanes, RAW10, Bayer **SGRBG10**, 1920×1080@30.
- Power/reset/clock and the privacy LED go through `INT3472:01` (`\_SB.PC00.DSC0`, driver `int3472-discrete`).

## Key decision: the camera works through libcamera, without the Intel HAL

In Ubuntu 26.04 libcamera **0.7** already supports IPU6: `SimplePipelineHandler` has the entry
`{ "intel-ipu6", {}, true }` (software ISP), and the system ships `ipa_soft_simple.so` and
`/usr/share/libcamera/ipa/simple/uncalibrated.yaml`. So **the kernel** was all that was needed:

- `intel-ipu6` + `intel-ipu6-isys` (built into the Ubuntu kernel),
- the V4L2 sensor driver `gc2607`,
- a patched `ipu-bridge` with the ACPI entry `GCTI2607` (absent from the stock module).

The ready-made `gc2607-camera-linux` also offers the Intel HAL + `icamerasrc` + PSYS + v4l2loopback
route — it was **not needed** (the sources were cloned to `/var/tmp/hw/{gc2607/third_party,bins,icamerasrc}`
in our development tree, and the `linux-main-modules-ipu6-*` package with the signed `intel-ipu6-psys`
is installed but unused).

## Installation procedure

```sh
# 1. sources (only two directories are needed: the driver itself and the patched bridge)
git clone --depth 1 https://github.com/AlexDaichendt/gc2607-camera-linux   # 5febb72
#    (the HAL/icamerasrc submodules are not needed)

# 2. build as a user to check kernel compatibility
make -C gc2607-kernel -j22                # → gc2607.ko
make -C ipu-bridge-gc2607 -j22            # → ipu-bridge.ko  (upstream v7.0 + 25 lines)

# 3. DKMS (root), the modules are signed with the MOK key
#    (our development tree used two small helper scripts for this — not shipped in this
#     repository; the package postinst does exactly this, so scripts/install.sh normally covers it)
#    result: dkms modules gc2607/0.3.1 and ipu-bridge-gc2607/0.1.0
#    the stock ipu-bridge.ko is archived by DKMS in the process ("Original modules exist")

# 4. reboot (after enrolling the MOK) — the modules are picked up automatically:
#    gc2607 loads via ACPI modalias (alias acpi*:GCTI2607:* gc2607),
#    ipu-bridge — as a dependency of intel_ipu6 (from updates/dkms, higher priority than stock).
```

The fifth step is color (CCM): `sudo install -m 644 patches/gc2607.yaml /usr/share/libcamera/ipa/simple/`.
Without it the picture is greenish and washed out — see the section "Color: the `gc2607.yaml` tuning file (CCM)".

The difference between our `ipu-bridge.c` and upstream v7.0 (tag `v7.0`) is exactly 25 lines:

```c
IPU_SENSOR_CONFIG("GCTI2607", 1, 336000000),      // sensor + link frequency 336 MHz
IPU_SENSOR_CONFIG("OVTI5675", 1, 450000000),      // + entries added by the repository author
DMI_EXACT_MATCH(DMI_SYS_VENDOR, "HUAWEI"), DMI_EXACT_MATCH(DMI_PRODUCT_NAME, "VGHH-XX"),
        .driver_data = "GCTI2607",
```

## Verification

```sh
journalctl -k -b | grep -iE "GCTI2607|gc2607|Connected . cameras"
#   intel-ipu6 …: Found supported sensor GCTI2607:00
#   intel-ipu6 …: Connected 1 cameras
#   gc2607 i2c-GCTI2607:00: GC2607 probed (SGRBG10 1920x1080@30fps)

media-ctl -p | grep -iE "gc2607|ipu6"        # the "gc2607 3-0037" node is present
ls /dev/v4l-subdev*                          # v4l-subdev6 = gc2607 3-0037
cam -l                                       # → Internal front camera (\_SB_.PC00.LNK0)
LIBCAMERA_LOG_LEVELS=IPAProxy:DEBUG cam -l 2>&1 | grep 'Using tuning file'   # → …/gc2607.yaml (CCM)

# capture a frame (cam writes RAW if the name is not .dng/.ppm!)
cam -c1 -C2 -F/tmp/frame.ppm                 # or a single JPEG via GStreamer:
timeout 20 gst-launch-1.0 -e -q libcamerasrc ! videoconvert ! jpegenc ! filesink location=/tmp/cam.jpg
```

Capture notes: `libcamerasrc` (GStreamer 1.28) **has no `num-buffers` property** — bound the
pipeline with `timeout`; the first frames after the stream starts can be black, so look at frames
further into the stream; the default size is negotiated as 1280×1080 even though the sensor delivers 1920×1080.

## Applications

- The camera is exposed through **xdg-desktop-portal** (`org.freedesktop.portal.Camera`,
  `IsCameraPresent=true` → `true`) — that is, GNOME and applications that work through the portal
  (Firefox, Telegram, Slack, etc.) can see it.
- Snap applications need a connected interface: `snap connections firefox | grep camera`
  (firefox/telegram-desktop/slack have `camera` connected).
- Check "with GStreamer's eyes": `gst-device-monitor-1.0 Video/Source | grep -A6 "Model = gc2607"`
  (the libcamera device), or simply capture a frame as above.

## Virtual camera for V4L2 applications (Zoom and similar)

Zoom and other non-libcamera applications enumerate `/dev/video*` (V4L2) and see only the "raw"
IPU6 nodes (a black frame), so a virtual V4L2 device is needed:

```
v4l2loopback (Canonical-signed module, package linux-main-modules-v4l2loopback-*)
  + v4l2-relayd (package from the repository)  →  /dev/video60 "GC2607 Virtual Camera"
```

⚠️ **The module package is pinned to the kernel ABI** (the package name is `…-<uname -r>`). After a
kernel update (`linux-image-generic-hwe-26.04`, e.g. 7.0.0-30 → 7.0.0-38) the module for the new
kernel does not appear on its own: `modinfo v4l2loopback` → "Module not found", `/dev/video60` is
not created, `gc2607-vcam.service` goes into an endless restart (applications enumerating
VIDIOC_ENUM_FMT devices see only the "raw" IPU6 nodes; the camera has "disappeared"). The symptom
in the system log:

```
systemd-modules-load[…]: Failed to find module 'v4l2loopback'
```

The cure (after every kernel ABI update):

```sh
sudo apt install linux-main-modules-v4l2loopback-$(uname -r)   # requires Canonical Secure Boot signing, no key needed
sudo modprobe v4l2loopback                                     # options come from /etc/modprobe.d/v4l2-relayd.conf
systemctl --user restart gc2607-vcam.service
```

Autoloading at system start is provided by the stock `/usr/lib/modules-load.d/v4l2-relayd.conf`
(from the `v4l2-relayd` package), so a manual modprobe is only needed until the next reboot.

How it is configured:

| What | Where |
|---|---|
| Loopback options (device label, `exclusive_caps`, number) | `/etc/modprobe.d/v4l2-relayd.conf` (`card_label="GC2607 Virtual Camera" video_nr=60`) |
| Producer (frame source) | `~/.config/systemd/user/gc2607-vcam.service` (copy — `packages/gc2607/gc2607-vcam.service`) |
| Config for the system variant (disabled) | `/etc/v4l2-relayd.d/gc2607.conf` |

⚠️ `/etc/v4l2-relayd.d/gc2607.conf` still holds the original (non-working) `VIDEOSRC` with a caps
filter, and the system unit template `v4l2-relayd@.service` assembles `-o` without `queue` and
without `sync=false`. If the system variant is ever enabled, bring both places in line with this
section (otherwise you get units of fps and a crash while parsing `-i`).

Producer pipeline:

```
v4l2-relayd -i "libcamerasrc ! videoconvert" \
  -o "appsrc name=appsrc caps=video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1 \
      ! queue max-size-buffers=2 max-size-time=0 max-size-bytes=0 leaky=upstream \
      ! videoconvert ! v4l2sink name=v4l2sink device=/dev/video60 sync=false"
```

**The main pitfall**: `-i` of v4l2-relayd is parsed by `gst_parse_launch` **as a single string**, and
GStreamer 1.28 in such a string **does not accept a caps filter** — it fails with
`backend_pipeline_create: no element "video"` and relayd serves only a black placeholder. So `-i`
takes only the chain of elements (`libcamerasrc ! videoconvert`); relayd itself attaches the caps to
the appsink of the input pipeline, taking them from `appsrc caps=…` in `-o` (verified with a
mini-test on `gst_parse_launch_full` with `GST_PARSE_FLAG_FATAL_ERRORS`: `libcamerasrc` → OK,
`libcamerasrc ! videoconvert` → OK, `… ! video/x-raw,…` → FAIL).

**Second pitfall (as actually observed: "in Zoom the first couple of seconds are fine, then ~1 frame
every 2 s")**: `-o` **requires a bounded "leaky" queue**. Without it `v4l2sink` blocks the whole
chain `appsrc → videoconvert → v4l2sink` (GStreamer even warns
`Pipeline construction is invalid, please add queues`), and the client gets units of fps.

**Third pitfall — `v4l2sink` defaults to `sync=true`** (basesink synchronizes output to the clock),
while relayd feeds frames through `appsrc is-live=true format=DEFAULT`: basesink judges the buffer
timestamps late and drops them, and the log shows
`basesink gstbasesink.c: A lot of buffers are being dropped` and
`There may be a timestamping problem, or this computer is too slow`. For `v4l2loopback` clock
synchronization is not needed — the pace is set by the reading client — so `-o` needs
**`v4l2sink … sync=false`**. Measurements on 2026-10-07 (kernel 7.0.0-38) showed that with
`sync=true` the queue no longer helps: all three `-o` variants gave ~3.3 fps, while with `sync=false` — 26–28.6 fps.

Measurements (the client reads `/dev/video60`, 90–300 frames, checking that adjacent frames are unique):

| output pipeline | frames/s | live frames |
|---|---|---|
| no `queue` (2026-10-06) | **1.7** | yes (19/20 unique) |
| `queue … leaky=downstream` (2026-10-06) | **26.7** | yes |
| `queue … leaky=upstream` (2026-10-06) | **26.5 → 28.9** | yes (29/29 unique) |
| no queue / `leaky=downstream` / `leaky=upstream`, sink default `sync=true` (2026-10-07) | **3.3 / 3.3 / 3.3** | — |
| `queue … leaky=upstream` + `v4l2sink … sync=false` (2026-10-07) | **26.4 → 28.6** | yes (59/60 unique) |

`leaky=upstream` was chosen because it drops old frames — the output always shows a fresh picture
(minimum latency). Check after the 2026-10-07 fixes: a `gst` client — 300 frames in 10.5 s
(28.6 fps), `v4l2-ctl --stream-count=200` — 27.97 fps, queue utilization with no basesink warnings.

An important note about the measurement methodology: v4l2loopback **repeats the last frame** when
there is no producer, and at the format rate (30 fps), so "timing" alone proves nothing — you must
compare the content of adjacent frames (md5), otherwise a "frozen" frame can be mistaken for a live stream.

The camera is **on demand**: until an application opens `/dev/video60`, relayd shows a black
placeholder and does not start the camera (the privacy LED is off); on open,
`V4L2_EVENT_PRI_CLIENT_USAGE` arrives → the real pipeline starts, and on close it goes back.

Verification:

```sh
v4l2-ctl --list-devices | grep -A1 GC2607          # /dev/video60
v4l2-ctl -d /dev/video60 --list-formats-ext       # YUYV 1280x720 @30
timeout 45 gst-launch-1.0 -q v4l2src device=/dev/video60 num-buffers=90 ! videoconvert ! jpegenc \
    ! multifilesink location=/tmp/w-%03d.jpg       # the frames must not be black
systemctl --user status gc2607-vcam.service

# check that the frames are "live" (important: the loopback repeats the last frame when there is no producer):
rm -f /dev/shm/fr/*; timeout 20 gst-launch-1.0 -q v4l2src device=/dev/video60 num-buffers=300 \
    ! multifilesink location=/dev/shm/fr/g-%03d.raw
for f in /dev/shm/fr/g-*.raw; do md5sum "$f"; done | awk '{print $1}' | uniq | wc -l   # ≈ number of frames
```

**Bottom line: confirmed in Zoom** (2026-10-06) — the picture is smooth, ~29 fps; before the queue
fix it was ~1.7 fps ("the first couple of seconds are fine, then one frame every two seconds").
The chronology is in `CHANGELOG.md`.

**2026-10-07 (after moving to kernel 7.0.0-38)**: the camera "disappeared" from applications —
there was no `v4l2loopback` module for the new ABI, `/dev/video60` was not created, and the service
was looping in restarts (see the warning above). After the package was delivered, a second defect
appeared: with `sync=true` (the default) the client got 2–5 fps even though the camera delivers
27.7 fps (`gst-launch … jpegenc ! multifilesink` — 166 frames in 6 s) and the loopback itself
delivers 30 fps (`videotestsrc ! v4l2sink`). The cure is `sync=false` in `-o`; after that, 28.6 fps
and 59/60 unique frames.

The system units `v4l2-relayd.service` / `v4l2-relayd@gc2607.service` are **disabled** (in the root
environment with the sandbox `DevicePolicy=closed` there are no guarantees about /dev/dri+dma-heap;
the user service runs in a verified environment and starts with the session).

## Color: the `gc2607.yaml` tuning file (CCM)

Symptom: the picture is "greenish and washed out". Cause — libcamera used `uncalibrated.yaml`, in
which the `Ccm` algorithm is commented out, and the AWB in the simple IPA is grey-world over
**sensor** R/G/B sums. Sensor primaries ≠ sRGB, so without a color matrix the frame drifts green and
loses saturation (`uncalibrated.yaml` says so explicitly:
"CCM … should only be enabled if tuned").

What was done: `/usr/share/libcamera/ipa/simple/gc2607.yaml` (libcamera looks up the file by the
sensor model name; the copy is `patches/gc2607.yaml`) — like `uncalibrated.yaml`, but with `Ccm`
enabled (the matrix is the same for ct 2860 and 7000):

```
ccm: [  1.4547, -0.3576, -0.0416,
       -0.1109,  1.1424, -0.0416,
       -0.1109, -0.3576,  1.6852 ]
```

The matrix was obtained without a reference target, self-consistently (`patches/derive-ccm.py`):

1. grey-world AWB must keep the frame average grey, so the residual shift in the linear means is
   exactly what the CCM must remove → `D = diag(1.042, 1, 1.150)`;
2. the washed-out look is cured by `S(a) = I + a·(I − L)` (L is the BT.709 luma matrix; the rows of
   `S` sum to 1, the hue is unchanged), with `a = 0.5` → `M = S(0.5)·D`.

Measurements (the client reads `/dev/video60`, 10 frames; the metrics are the linear per-channel
means and the pixel-wise mean `(max−min)/max`):

| | G/R | G/B | saturation |
|---|---|---|---|
| without CCM (`uncalibrated.yaml`) | 1.031 | **1.136** | 0.090 |
| with CCM | 1.009 | **1.026** | **0.118** |

Directly through `libcamerasrc` (without the YUY2 path) the shift goes away completely: G/R=1.003,
G/B=0.994, saturation 0.119 → 0.175. Clipping after the matrix is 0.01 % at the top / 0.2 % at the
bottom; the cost is `v4l2-relayd` ~10 % of one core (the CPU debayer enables the template with CCM).

To check that the file is actually used and the matrix applied:

```sh
li=$(LIBCAMERA_LOG_LEVELS=IPAProxy:DEBUG timeout 30 cam -l 2>&1 | grep -i 'Using tuning file')
echo "$li"                       # → Using tuning file /usr/share/libcamera/ipa/simple/gc2607.yaml
timeout 20 gst-launch-1.0 -q libcamerasrc ! videoconvert ! video/x-raw,format=RGB,width=1280,height=720 \
    ! multifilesink location=/tmp/ccm-%02d.raw
python3 patches/derive-ccm.py measure /tmp/ccm-99.raw   # → G/R≈1.00, G/B≈1.00
```

A useful consequence of enabling `Ccm`: the libcamera control `Saturation` (0..2, default 1.0)
appears in the IPA — saturation can be adjusted without editing the file (in the relayd path, via
`libcamerasrc extra-controls=…`).

About `BlackLevel`: the key is deliberately **not** set in the file (the GC2607 has no
`CameraSensorHelper`, so the algorithm picks the level from the histogram itself). Experiment: an
explicit `blackLevel: 8192` (32 in the 8-bit domain) over-subtracts and breaks the picture in a dark
scene (means drop to 78/90/59, saturation 0.40 vs 115/120/112 normally) — hence it is left on auto.

Limitations: one matrix for all color temperatures, derived under the grey-world assumption (there
was no reference target). If you need accurate color, shoot a ColorChecker/gray card, recompute `D`
with the same script and (optionally) reduce `a`.

## The `gc2607-camera-stack` package — the canonical way to install and remove

Since 2026-10-07 the whole camera stack is managed by a local `.deb`: both DKMS modules, the `Ccm`
tuning file and the virtual-camera user unit. System updates do not overwrite it, and `dpkg`/`apt`
handle removal and bookkeeping.

| What | Where |
|---|---|
| Package | `gc2607-camera-stack 0.3.1+localpatch1` — `dist/gc2607-camera-stack_0.3.1+localpatch1_amd64.deb` |
| Build/rebuild the package | `sh scripts/build-packages.sh` (fetches the pinned upstreams, applies `patches/ipu-bridge-GCTI2607.patch` if the HID is missing upstream, and packages both DKMS trees, the `Ccm` tuning file and the user units) |
| Install (and rebuild the modules) | `sudo ./scripts/install.sh` (or `sudo dpkg -i dist/gc2607-camera-stack_*_amd64.deb`) — postinst registers and builds both DKMS modules for the current kernel |
| Health check | `cam-healthcheck` + user timer `cam-healthcheck.timer` (weekly, enabled system-wide) |
| Package documentation | `/usr/share/doc/gc2607-camera-stack/README.md` + a copy of `gc2607.yaml`, expected md5 sums, the `ipu-bridge-GCTI2607.patch` diff, `tools/derive-ccm.py` |

Dependencies: `Depends: dkms, kmod, libcamera-ipa` (owner of the simple IPA),
`Recommends: v4l2-relayd`. The libcamera version is **not pinned**: unlike the scanner patch, a
"silent" breakage is not critical here (in the worst case the color falls back to `uncalibrated`), so
`cam-healthcheck` is enough instead of `Breaks`. The ABI-dependent
`linux-main-modules-v4l2loopback-$(uname -r)` is not among the dependencies — postinst warns with
the exact command if the module is missing for the current kernel.

File ownership is checked with `dpkg -S /usr/share/libcamera/ipa/simple/gc2607.yaml` →
`gc2607-camera-stack`. The user units live in `/usr/lib/systemd/user/` and are enabled system-wide
(`systemctl --global enable`); there is no longer a personal copy in `~/.config/systemd/user/` —
unit changes must be made in `packages/gc2607/gc2607-vcam.service` and the package reinstalled.

## What survives a reboot and updates

Verified by simulating a boot (unload the module → `systemctl restart systemd-modules-load` → start
the user service): the module comes up on its own (the `/usr/lib/modules-load.d/v4l2-relayd.conf`
entry from the `v4l2-relayd` package), `/dev/video60` appears with the right label, the service
starts **on the first attempt** (`NRestarts=0`, not a single `assertion` line in the log), and the
tuning file is picked up when the camera stream starts.

| What | Survives | Risk / what to do |
|---|---|---|
| `/usr/share/libcamera/ipa/simple/gc2607.yaml` | reboot and package updates: the file belongs to no package and lives on the root LV (not tmpfs) | a `libcamera` update may change the tuning-file schema → the IPA fails to start (`Failed to parse 'ccm'`) and the camera disappears; cure — temporarily remove the file (`pkexec rm /usr/share/libcamera/ipa/simple/gc2607.yaml`) or fix it using the copy in `patches/gc2607.yaml` |
| the user service `gc2607-vcam.service` | reboot (`enabled`, `WantedBy=default.target`); `ExecStartPre` waits for `/dev/video60` for up to 10 s — the startup race is gone | no module for the current ABI → the service fails with an explicit message "`/dev/video60` did not appear…" (instead of a restart loop) |
| the `linux-main-modules-v4l2loopback-<abi>` package | **no**, does not survive a kernel ABI change | after a kernel upgrade: `apt install linux-main-modules-v4l2loopback-$(uname -r)`; caught by `cam-healthcheck` (and by the postinst warning) |
| the DKMS modules `gxfp`, `gc2607`, `ipu-bridge-gc2607` | yes: DKMS rebuilds them for the new kernel, the MOK key is already enrolled | — |

## Limitations and what could be improved

- Color: the CCM was derived without a reference target and is one for all color temperatures
  (see the section "Color: the `gc2607.yaml` tuning file (CCM)"). In a dark room the exposure and
  gain still hit the maximum — that is a limitation of the sensor/optics, not of the CCM.
- The driver does not expose selection rectangles → libcamera logs
  "'gc2607 3-0037': The sensor kernel driver needs to be fixed" and uses the default values.
- `gc2607 … supply dovdd not found, using dummy regulator` (same for `dvdd`) — power is supplied
  without regulator control (it works, but power sequencing is not engaged).
- The orientation is correct: `api.libcamera.Rotation = 0`, a 1280×720 frame is captured the right
  way up (verified on a captured frame — not shipped in this repository) — no rotation
  quirk is needed for `ENZH-XX`.
- Fallback path if the software ISP quality is not enough: Intel `ipu6-camera-hal` + `icamerasrc`
  + `ipu6-drivers` (PSYS) + `v4l2loopback` (the module is already installed by the package) — the
  sources were cloned into our development tree (not shipped in this repository).

## Rollback

```sh
sudo apt remove gc2607-camera-stack                      # both DKMS modules + the Ccm tuning file + the user units (vcam, healthcheck)
sudo apt purge 'linux-main-modules-v4l2loopback-*'       # and its loopback module (if no longer needed)
sudo depmod -a && sudo reboot                            # the stock ipu_bridge returns; the camera is again "without a driver"
```

If the package is not installed (the stack was set up manually): `sudo rm -f /usr/share/libcamera/ipa/simple/gc2607.yaml`,
`systemctl --user disable --now gc2607-vcam.service`, `sudo dkms remove ipu-bridge-gc2607/0.1.0 --all`,
`sudo dkms remove gc2607/0.3.1 --all`, then `sudo depmod -a && sudo reboot`.
