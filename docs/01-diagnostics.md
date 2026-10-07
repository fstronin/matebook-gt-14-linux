# 01. Initial diagnostics: what did not work and how it shows up in the system

State before the installs: Ubuntu 26.04.1, kernel `7.0.0-30-generic`, Secure Boot enabled,
`systemctl --failed` empty, no err-level errors in the journal for the hardware — that is,
"everything was detected, but two devices are non-functional".

## Camera — the sensor is there, the driver is missing

```sh
lspci -nnk | grep -A2 00:05.0            # Intel Meteor Lake IPU [8086:7d19], driver: intel-ipu6
ls /sys/bus/acpi/devices | grep -i gcti  # GCTI2607:00  (path \_SB_.PC00.LNK0, status 15 = present)
ls /sys/bus/i2c/devices | grep -i GCTI   # i2c-GCTI2607:00, modalias acpi:GCTI2607:GCTI2607:
                                         # driver NOT bound (there is no module with the alias GCTI2607)
```

Indirect confirmation that the camera is physically soldered in: `int3472-discrete` created the
camera's private LED `GCTI2607_00::privacy_led` (parent `INT3472:01`, `\_SB.PC00.DSC0`).

What the subsystem showed:

```sh
media-ctl -p            # only Intel IPU6 ISYS Capture 0..47 + 6× Intel IPU6 CSI2, no sensor
ls /sys/class/video4linux/   # only "Intel IPU6 ISYS Capture N"
gst-device-monitor-1.0 Video/Source   # the "ipu6 (V4L2)" node with no sensor, there will be no frame
```

Checked separately: the IVSC MEI clients (`5db76cf6…`, `92335fcf…`, alias on `ivsc_ace`/`ivsc_csi`)
are **absent** from `/sys/bus/mei/devices`, while the ACPI sensor nodes of other SKUs
(`OVTI01AS:00/01`, `OVTI13B1:00`) have `status = 0` (not installed) — that is, the camera is exactly
behind this ACPI entry `GCTI2607` (GalaxyCore GC2607), and it needs a driver + an entry in ipu-bridge.

## Fingerprint reader — the device is there, the driver is missing

```sh
ls /sys/bus/acpi/devices | grep -i GXFP   # GXFP5130:00 (path \_SB_.SPBA, status 15)
grep -i GXFP5130 /lib/modules/$(uname -r)/modules.alias   # empty → no driver in the kernel
fprintd-list $USER                       # "No devices available"
lsusb                                    # no USB fingerprint reader (the sensor sits on eSPI via the EC)
```

Hardware-wise this is a Goodix GXFP5130; it does not go over USB/PCIe but through the EC
eSPI mailbox (the kernel driver creates `/dev/gxfp`).

## Other observations (not related to the task, but recorded)

- `i915`: `WARNING … intel_bios.c:2792 print_ddi_port` + "Port A asks to use VBT vswing/preemph
  tables" — a known noisy WARN from the Huawei VBT; the display works (eDP 2880×1920, backlight).
- Thermal zones `SEN9` / `SENO` / `SENP` (module `int3403_thermal`, devices `INTC10A1:*`, `\_SB_.SEN*`)
  return garbage: 6013.85 °C / 0.05 °C / 1.35 °C, static. No cooling device is bound to them,
  there is no throttling — just garbage in the monitors.
- ACPI BIOS errors from the firmware: `No handler for Region [ECW1]` → `\_SB.PC00.LPCB.HWEC.BAT0._STA`
  fails; `Could not resolve symbol [\_SB.PC00.LPCB.HEC.DPTF.FCHG]` → `\_SB.IETM.CHRG.PPSS` fails.
  The battery still works.
- `iwlwifi: Unhandled alg: 0x707` (×10) — known harmless noise; `nvme0: using unchecked data buffer`;
  `i8042: PS/2 AUX port disabled`; `skl_hda_dsp_generic: no PCM in topology for HDMI converter`.
- Touchscreen I2C: `i2c_designware.1: spurious STOP / lost arbitration`, `i2c_hid_acpi i2c-FTSC1000:00:
  failed to get a report from device: -5` (×8), `hid-multitouch: failed to fetch feature 5/12` —
  the panel comes up as a multitouch, but some HID feature reports are not readable.
- `dmesg` is closed to the user by default (`kernel.dmesg_restrict=1`) — all diagnostics go through
  `journalctl -k`, `/sys`, `lspci -nnk`, `lsusb -t`, `media-ctl`, `wpctl`, `cam -l`.

## Diagnostic commands (repeatable)

```sh
uname -a; grep PRETTY /etc/os-release; systemd-detect-virt; mokutil --sb-state
lspci -nnk; lsusb -t; ls /sys/bus/acpi/devices; for d in /sys/bus/pci/devices/*; do [ -e $d/driver ] || echo "no driver: $d"; done
journalctl -k -b --no-pager | grep -iE "error|warn|fail|firmware|ipu|gxfp|gc2607"
for d in /sys/bus/i2c/devices/*; do echo "$(basename $d) $(cat $d/name 2>/dev/null) $(basename $(readlink -f $d/driver 2>/dev/null))"; done
lsmod | grep -iE "ivsc|ipu|gxfp"; ls /sys/bus/mei/devices
```
