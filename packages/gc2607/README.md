# gc2607-camera-stack (local package)

The **GalaxyCore GC2607** camera stack (Huawei MateBook GT 14, ENZH-XX) on Ubuntu 26.04:
sensor driver (DKMS), patched `ipu-bridge` with ACPI HID `GCTI2607`, a libcamera simple-IPA
tuning file with the `Ccm` matrix, and a user unit for the virtual camera `/dev/video60`.

## What is inside and where it installs

| Path | What it is |
|---|---|
| `/usr/src/gc2607-0.3.1/` | sources of the DKMS module `gc2607` (V4L2 sensor driver) |
| `/usr/src/ipu-bridge-gc2607-0.1.0/` | sources of the DKMS module `ipu-bridge-gc2607` — replaces the stock `ipu_bridge`, adding the HID `GCTI2607` (without it the camera does not appear in the media graph) |
| `/usr/share/libcamera/ipa/simple/gc2607.yaml` | simple-IPA tuning file with the `Ccm` matrix (in the distribution's `uncalibrated.yaml` the `Ccm` algorithm is commented out — without it the picture is greenish and washed out) |
| `/usr/lib/systemd/user/gc2607-vcam.service` | user unit of the virtual camera (`v4l2-relayd`: `libcamerasrc` → v4l2loopback `/dev/video60`); `-o` must contain `queue … leaky=upstream` and `v4l2sink … sync=false` |
| `/usr/lib/systemd/user/cam-healthcheck.{service,timer}` | weekly stack check |
| `/usr/local/bin/cam-healthcheck` | check: DKMS modules, tuning file, virtual camera |
| `/usr/share/doc/gc2607-camera-stack/` | this README, a copy of `gc2607.yaml`, expected md5 sums, the `ipu-bridge-GCTI2607.patch` patch, `tools/derive-ccm.py` |

## Provenance

* sensor module: `github.com/AlexDaichendt/gc2607-camera-linux`, commit
  `5febb7200c3b2b8414839b1645e0bb8210cf1999` (directory `gc2607-kernel/`);
* `ipu-bridge`: the same repository (`ipu-bridge-gc2607/`), contains the HID `GCTI2607`.
  The diff against `torvalds/linux` tag `v7.0` sits alongside as `ipu-bridge-GCTI2607.patch` —
  it also shows extra changes (their base is newer than v7.0); for an upstream mail exactly the line
  `IPU_SENSOR_CONFIG("GCTI2607", 1, 336000000)` is useful;
* `gc2607.yaml` (the `Ccm` matrix) and `derive-ccm.py` are ours: the matrix was derived self-consistently
  from grey-world without a chart (method — `docs/03-camera-gc2607.md`).

## Dependencies and pitfalls

* `Depends: dkms, kmod, libcamera-ipa` (the owner of simple-IPA); the libcamera version is **not pinned**:
  if the tuning file format changes, libcamera falls back to `uncalibrated` (colours wash out) —
  the weekly `cam-healthcheck` catches this, not `Breaks`;
* the virtual camera requires `v4l2-relayd` (`Recommends`) and the **ABI-dependent** package
  `linux-main-modules-v4l2loopback-$(uname -r)`: after a kernel update it must be installed again,
  otherwise `/dev/video60` does not appear (postinst warns with the exact command);
* `ipu-bridge-gc2607` puts the module into `updates/dkms`, so `depmod` prefers it over the
  in-kernel `ipu_bridge`; when the package is removed the stock one comes back (the camera is again
  "without a driver");
* the `cam` filter will not deliver 50 fps: `gc2607` does not expose selection rectangles, libcamera
  takes the default values (see the limitations in `docs/03-camera-gc2607.md`).

## Update and rebuild

    sh scripts/build-packages.sh                  # .deb from the upstream pins + our Ccm
    sudo dpkg -i dist/gc2607-camera-stack_*_amd64.deb   # postinst rebuilds both modules

The DKMS sources stay in `/usr/src` permanently; after a kernel update the modules are rebuilt
automatically (`AUTOINSTALL=yes`), but the `v4l2loopback` module must be installed by hand (see above).

## Check after installation

    cam-healthcheck                     # -> cam: OK
    cam -l                              # -> Internal front camera (\_SB_.PC00.LNK0)
    LIBCAMERA_LOG_LEVELS=IPAProxy:DEBUG cam -l 2>&1 | grep 'Using tuning file'   # -> .../gc2607.yaml
    systemctl --user is-active gc2607-vcam.service

## Removal

    sudo apt remove gc2607-camera-stack   # both DKMS modules, tuning file, user units
    sudo apt purge  gc2607-camera-stack   # plus the package configs
