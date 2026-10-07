# 06. Automatic screen brightness (ALS)

## Symptom

Brightness changed by itself depending on the ambient light, and did so badly: sharp jumps / dropping to the minimum.

## How it works

```
ALS acpi-als (ACPI0008, /sys/bus/iio/devices/iio:device0)
   → iio-sensor-proxy (systemd service, D-Bus net.hadess.SensorProxy, property LightLevel)
   → gnome-settings-daemon (gsd-power), the ambient-enabled setting
   → mutter helper (polkit org.gnome.mutter.backlight-helper.policy)
   → /sys/class/backlight/intel_backlight/brightness   (root:root 0644)
```

Checking the "raw" data:

```sh
gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled    # was true
cat /sys/bus/iio/devices/iio:device0/in_illuminance_input                # ALS value
gdbus call --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy \
    --method net.hadess.SensorProxy.ClaimLight
gdbus call --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy \
    --method org.freedesktop.DBus.Properties.Get net.hadess.SensorProxy LightLevel
```

The sensor in this machine reports very low values: **11 lx** at dusk, **0 lx** in complete darkness.
Because of that gsd-power drove the brightness down to the minimum (219 → **87 out of 800** was observed,
i.e. ~11 %), and twitched it at the slightest change in light. Hence the "badness".

## What was done

```sh
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled false
gsettings get org.gnome.settings-daemon.plugins.power ambient-enabled      # → false
```

This is the same as clearing the **Settings → Power → Automatic Screen Brightness** checkbox.
The setting is per-user (dconf) and survives a reboot.

Brightness was returned to its previous level through logind (without root):

```sh
gdbus call --system --dest org.freedesktop.login1 --object-path /org/freedesktop/login1/session/auto \
    --method org.freedesktop.login1.Session.SetBrightness backlight intel_backlight 219
```

## Verification

```sh
while :; do printf '%s  brightness=%s  illuminance=%s lx\n' "$(date +%H:%M:%S)" \
    "$(cat /sys/class/backlight/intel_backlight/brightness)" \
    "$(cat /sys/bus/iio/devices/iio:device0/in_illuminance_input)"; sleep 1; done
```

Cover/uncover the ambient light sensor (the strip next to the camera) or turn the lights on/off:
**the brightness must stay unchanged**, while `illuminance` changes. Observed right after the edit:
sensor 11 lx, brightness steady at 219 (20 s without change).

## Roll back / system-wide

```sh
gsettings set org.gnome.settings-daemon.plugins.power ambient-enabled true    # restore the previous state
```

To disable it for **all** users (including new ones) — a dconf profile as root:

```sh
sudo tee /etc/dconf/db/local.d/00-no-ambient-brightness >/dev/null <<'EOF'
[org/gnome/settings-daemon/plugins/power]
ambient-enabled=false
EOF
sudo dconf update
```

## Related (not changed)

- `idle-dim = true`, `idle-brightness = 30` — GNOME **dims the screen after idle**
  (through `org.gnome.desktop.session idle-delay`). This is a different mechanism, but it feels similar;
  if it gets in the way: `gsettings set org.gnome.settings-daemon.plugins.power idle-dim false`.
- `iio-sensor-proxy` is left enabled (it serves only this sensor; there are no other consumers).
- Only root can write to brightness in sysfs directly (0644), applications go through the
  mutter/logind helper — which is why no "spontaneous" brightness changes from the firmware were observed.
