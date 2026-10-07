#!/bin/sh
# install.sh — installs the stack for the HUAWEI MateBook GT 14 (ENZH-XX):
# builds the local .deb files from the upstream pins and installs them with dpkg.
#
#   sudo ./scripts/install.sh --dry-run     # checks only (builds/installs nothing)
#   sudo ./scripts/install.sh               # fetch + patches + build + dpkg -i + healthcheck
#   sudo ./scripts/install.sh --skip-build  # use the ready .deb files from dist/
#   sudo ./scripts/install.sh --force       # allow installation on a different DMI model
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DRY=0; FORCE=0; SKIP=0
for a in "$@"; do
	case "$a" in
		--dry-run)    DRY=1 ;;
		--force)      FORCE=1 ;;
		--skip-build) SKIP=1 ;;
		*) echo "unknown option: $a (see the script header)" >&2; exit 2 ;;
	esac
done

say() { printf '%s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "root required: sudo $0"

# ---------- 1. is this the right laptop ----------
vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "?")
model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
say "== machine: $vendor $model (kernel $(uname -r))"
case "$model" in
	ENZH-XX*) say "   model matches (ENZH-XX)" ;;
	*)
		say "   WARNING: this repository targets ENZH-XX (MateBook GT 14; ports, CCM and ACPI nodes differ on other models)."
		[ "$FORCE" = 1 ] || die "for another model run with --force and read docs/"
	esac

# ---------- 2. what is missing ----------
missing=""
for t in dkms meson ninja cmake make gcc patch curl dpkg-deb gzip ldd dpkg-query; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	say "== missing utilities:$missing"
	say "   Ubuntu: sudo apt install build-essential dkms meson ninja-build cmake patch curl"
	[ "$DRY" = 1 ] || die "install the dependencies and retry"
fi
for p in mbedtls glib-2.0 gusb pixman-1 cairo opencv4 nss; do
	command -v pkg-config >/dev/null 2>&1 || break
	pkg-config --exists "$p" 2>/dev/null || say "   ? missing pkg-config dependency: $p (usually the *-dev package)"
done
for t in libcamera-tools v4l2-relayd libpam-fprintd; do
	dpkg-query -W -f='${Status}' "$t" 2>/dev/null | grep -q 'install ok installed' || \
		say "   ? package $t is not installed (needed for the camera/fingerprint login: sudo apt install $t)"
done

# Secure Boot + MOK
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
	if grep -qs 'mok_signing_key' /etc/dkms/framework.conf; then
		say "== Secure Boot is enabled, MOK key configured in /etc/dkms/framework.conf ✓"
	else
		die "Secure Boot is enabled, but /etc/dkms/framework.conf has no mok_signing_key — follow docs/04-secureboot-mok.md (otherwise DKMS will not build the modules)"
	fi
fi

# the ABI-pinned loopback is only needed by the virtual camera
if ! modinfo -F filename v4l2loopback >/dev/null 2>&1; then
	say "== WARNING: no v4l2loopback module for $(uname -r) — /dev/video60 will not appear."
	say "   Install it: sudo apt install linux-main-modules-v4l2loopback-$(uname -r)"
fi

if [ "$DRY" = 1 ]; then
	say "== --dry-run: checks passed, building and installing nothing"
	exit 0
fi

# ---------- 3. build the packages ----------
if [ "$SKIP" = 1 ]; then
	ls "$ROOT"/dist/*.deb >/dev/null 2>&1 || die "--skip-build, but there is no .deb in dist/"
	say "== --skip-build: using the ready packages from dist/"
else
	say "== building packages (fetch upstreams + patches + build + dpkg-deb)"
	JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)} "$ROOT/scripts/build-packages.sh"
fi

# ---------- 4. installation ----------
say "== installing packages"
dpkg -i "$ROOT"/dist/gxfp5130-stack_*_amd64.deb "$ROOT"/dist/gc2607-camera-stack_*_amd64.deb

# ---------- 5. checks ----------
say "== checks"
command -v gxfp-healthcheck >/dev/null 2>&1 && gxfp-healthcheck || say "   gxfp-healthcheck not found"
command -v cam-healthcheck  >/dev/null 2>&1 && cam-healthcheck  || say "   cam-healthcheck not found"

# enable the healthcheck units globally (they will run in the user session at next login)
if command -v systemctl >/dev/null 2>&1; then
	for u in gxfp-healthcheck.timer cam-healthcheck.timer; do
		systemctl --global enable "$u" 2>/dev/null && say "   $u enabled"
	done
fi

cat <<'EOT'

== Still to do manually (once)

 1) Fingerprint sensor PSK — it is per-device and is not included in the package:
      cd build/upstream/gxfp && sudo ./scripts/provision-psk.sh
    (if the sensor was already provisioned, e.g. from Windows — ./scripts/provision-psk.sh --replace;
     details: docs/02-fingerprint-gxfp5130.md)

 2) fingerprint enrollment (rhythm: place → ~1 s → lift → pause ~1 s):
      fprintd-enroll -f right-index-finger "$USER" && fprintd-verify

 3) fingerprint login/sudo — optional: docs/05-fingerprint-login-pam.md
 4) camera: colour is already configured (tuning file from the package); check — docs/03-camera-gc2607.md
 5) external GPU/Thunderbolt — no drivers needed, recipe in docs/08-egpu-hi-gt-cube.md
EOT
