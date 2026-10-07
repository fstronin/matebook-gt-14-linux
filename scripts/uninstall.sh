#!/bin/sh
# uninstall.sh — removes the local stack packages (and, optionally, the v4l2loopback module).
#   sudo ./scripts/uninstall.sh            # remove packages, keep the configs in /etc
#   sudo ./scripts/uninstall.sh --purge    # remove together with the configs (-p)
set -eu
[ "$(id -u)" = 0 ] || { echo "root required: sudo $0" >&2; exit 1; }

PURGE=""
[ "${1:-}" = "--purge" ] && PURGE="-p"

echo "== removing packages"
if command -v apt-get >/dev/null 2>&1; then
	apt-get remove -y $PURGE gxfp5130-stack gc2607-camera-stack
else
	dpkg -r $([ -n "$PURGE" ] && echo --purge) gxfp5130-stack gc2607-camera-stack
fi
dpkg -l gxfp5130-stack gc2607-camera-stack 2>/dev/null | grep -E '^[a-z]{2}' || true

cat <<'EOT'

== Removed. What remains (all optional)

 * v4l2loopback module (only needed by the virtual camera):
     sudo apt purge 'linux-main-modules-v4l2loopback-*'
 * sensor PSK and enrolled fingerprints (not part of the packages):
     sudo rm -rf /var/lib/fprintd/gxfp           # sensor PSK
     fprintd-delete "$USER"                      # fingerprint templates
 * healthcheck units:
     systemctl --global disable gxfp-healthcheck.timer cam-healthcheck.timer
 * after removing ipu-bridge-gc2607, depmod will restore the stock ipu_bridge
   (the camera is "driverless" again — expected; a reboot is required)
EOT
