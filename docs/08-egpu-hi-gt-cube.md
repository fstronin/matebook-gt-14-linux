# 08. External GPU (eGPU): WIKO Hi GT Cube + Radeon RX 7600M XT

Result: the eGPU works on the **far** Type-C connector of the laptop (Thunderbolt 4), an external
monitor is driven by the external card, and games launch with offload. No drivers had to be
installed and no system settings changed (all experiments with kernel parameters were rolled back).

## Hardware and ports

| | |
|---|---|
| Dock | WIKO Hi GT Cube (Thunderbolt device `0-3`, "Hi GT Cube"), inside is an Intel JHL7440 bridge (Titan Ridge TB3), link 40 Gb/s = 2×20 |
| Card | AMD Radeon RX 7600M XT (Navi 33, `1002:7480`) + HDMI audio (`1002:ab30`) |
| Power | 140 W adapter — **into the Cube itself**; the Cube delivers up to 100 W to the laptop and powers the card |
| Dock outputs | DP 1.4a (in DRM `card0-DP-4`) and HDMI 2.1 (`card0-HDMI-A-2`) |

**The important thing about the ports.** There are two Type-C connectors on the left, and they are different:

* the one nearer the 3.5 mm jack is a plain USB-C (`\_SB.PC00.XHCI.RHUB.HS01`): it works as USB,
  but does not provide Thunderbolt (the eGPU will not come up there — the dock reports only a Billboard `0451:ace1`);
* the **far one is Thunderbolt 4** (`TXHC`, NHI `00:0d.3`, TB group `TDM1`/`TRP3` with `_STA=0xf`).
  The eGPU works **only** in it.

## Connection procedure (verified)

1. The 140 W adapter — **into the Cube**, turn it on.
2. The cable (the bundled one, USB4/TB) — into the **far** Type-C of the laptop.
3. If the link does not come up (`boltctl list` empty, `usb4_port3/link=none`) — **cold cycle**:
   unplug the adapter from the Cube for a minute, power it again, wait, then power the laptop off and on.
   A stuck dock does not come back to life from hot re-plugs or from Linux reboots.
4. Authorization is not required: in `boltctl` the device is `authorized` and `stored` (policy `iommu`),
   after that it connects by itself.

## Verification (expected output)

```sh
boltctl list                      # → WIKO Hi GT Cube, authorized, stored, 40 Gb/s
lspci -nn | grep -E '1002:|JHL7440'  # → 06:00.0 VGA [1002:7480], 06:00.1 audio, JHL7440 bridges
ls /sys/class/drm/ | grep card    # → card0 = amdgpu (AMD), card1 = i915 (Intel)
journalctl -k -b | grep amdgpu    # → Initialized amdgpu 3.64.0 for 0000:06:00.0
vulkaninfo --summary              # → AMD Radeon RX 7600M XT (RADV NAVI33) along with Intel Arc
```

## Running games and applications on the external card

The variables are exactly those that GNOME ("Launch Using Discrete Graphics Card";
`switcheroo-control` reports the same ones):

```
DRI_PRIME=pci-0000_06_00_0 VK_LOADER_DRIVERS_SELECT='*radeon*'
```

* Steam (snap) → game properties → launch options:
  `DRI_PRIME=pci-0000_06_00_0 VK_LOADER_DRIVERS_SELECT=*radeon* %command%`;
* any application: prefix its launch command with the two variables, e.g.
  `DRI_PRIME=pci-0000_06_00_0 VK_LOADER_DRIVERS_SELECT='*radeon*' <command>` (we used a small
  `egpu-run` wrapper in `~/.local/bin/` for this — not shipped in this repository);
* or right-click the application in GNOME → "Launch Using Discrete Graphics Card".

Verification: `DRI_PRIME=… vkcube` → `Selected GPU 0: AMD Radeon RX 7600M XT (RADV NAVI33)`;
`DRI_PRIME=… glxinfo -B` → `OpenGL renderer: AMD Radeon RX 7600M XT (radeonsi, navi33, ACO)`.

## Pitfalls (verified)

* **A monitor on the external card** comes up only if the session starts with the eGPU already
  connected: mutter enumerates GPUs at startup, whereas a "hot" dock is added as a render device but
  its outputs are not taken into the monitor model (`Mutter.DisplayConfig` shows only `eDP-1`).
  The cure is a reboot/re-login with the dock connected (after that `DP-4` is visible and the picture
  appears). Forcing `uevent`/`trigger` on the connector does not help.
* **BAR:** on hot-plug the kernel does not assign the large BAR
  (`amdgpu … BAR 0 [mem size 0x200000000]: failed to assign`), and the card works with a 256 MB window.
  For a TB3 tunnel this is normal (the BIOS reserves a limited window), but it is better to boot the
  laptop with the dock already connected.
* **Did NOT help** (and were rolled back, the system is stock): `pcie_port_pm=off`, keeping TB PCI in D0
  (`d3cold_allowed=0` + `power/control=on`), `options thunderbolt host_reset=0`, loading
  `typec`/`ucsi_acpi`/`intel_pmc_mux` (`/sys/class/typec` is empty — the firmware reports UCSI as off,
  `UCMS=0`), `thunderbolt.force_power` (that parameter no longer exists in this kernel). The cause of
  the failures was the stuck dock, not the kernel.
* Drivers are not needed: `amdgpu` is in the kernel (`7.0.0-38-generic`), the firmware is in
  `linux-firmware-amd-graphics`, Mesa/RADV is already installed; Secure Boot does not interfere
  (the module is in-kernel, not DKMS).
* If the external monitor is not needed, the eGPU can be left connected permanently, but on every
  disconnect/reconnect the **monitor** will come back only after a session restart.

## Rollback

No system settings were changed: unplugging the cable is enough. Optionally also
`boltctl forget <uuid>` (forget the trusted device) and remove the wrapper, if you created one.
