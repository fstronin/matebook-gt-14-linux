#!/bin/sh
# build-packages.sh — downloads the upstreams at PINNED commits, applies our patches,
# builds and packages two local .deb files in dist/.
#
#   ./scripts/build-packages.sh              # everything (fetch + patches + build + package)
#   ./scripts/build-packages.sh --no-fetch   # no download (use build/upstream)
#
# Installs nothing into the system — it only builds. To install: scripts/install.sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/build"
DIST="$ROOT/dist"
UP="$BUILD/upstream"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

GXFP_COMMIT=786e210e0e31828c00dd3beae1fbc008960d5555
CAM_COMMIT=5febb7200c3b2b8414839b1645e0bb8210cf1999
GXFP_VER=0.1.0+localpatch1
CAM_VER=0.3.1+localpatch1

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "utility $1 not found ($2)"; }

for t in curl tar patch dpkg-deb cmake meson ninja make; do
	need "$t" "build dependencies — see README"
done

mkdir -p "$BUILD" "$DIST" "$UP"

# ---------- 1. upstreams at pinned commits ----------
fetch() { # fetch <url> <dest-dir> <prefix>
	[ -d "$2" ] && return 0
	echo "== downloading $1"
	curl -fsSL -o "$UP/tmp.tar.gz" "$1" || die "download failed: $1"
	tar xzf "$UP/tmp.tar.gz" -C "$UP"
	mv "$UP/$3"* "$2"
	rm -f "$UP/tmp.tar.gz"
}

if [ "${1:-}" != "--no-fetch" ]; then
	fetch "https://codeload.github.com/Metrohan/gxfp5130-linux/tar.gz/$GXFP_COMMIT" "$UP/gxfp" "gxfp5130-linux-"
	fetch "https://codeload.github.com/AlexDaichendt/gc2607-camera-linux/tar.gz/$CAM_COMMIT" "$UP/cam" "gc2607-camera-linux-"
fi
[ -d "$UP/gxfp/userspace" ] || die "no $UP/gxfp — run without --no-fetch"
[ -d "$UP/cam" ] || die "no $UP/cam — run without --no-fetch"

# ---------- 2. patches ----------
echo "== gxfp: tree + fdt-wait-up patch (FW GF_GCC_EC_20069)"
rm -rf "$BUILD/gxfp"
cp -a "$UP/gxfp" "$BUILD/gxfp"
if grep -q 'FDT_WAIT_UP_MAX_RETRIES 20' "$BUILD/gxfp/userspace/src/flow/fdt.c" 2>/dev/null; then
	echo "   patch already in upstream — not applying"
else
	patch -p1 -N -d "$BUILD/gxfp" < "$ROOT/patches/fdt-wait-up.patch" \
		|| die "fdt-wait-up.patch did not apply (did upstream change fdt.c?)"
	echo "   applied"
fi

echo "== ipu-bridge-gc2607: HID GCTI2607"
rm -rf "$BUILD/ipu"
cp -a "$UP/cam/ipu-bridge-gc2607" "$BUILD/ipu"
ipu_c=$(ls "$BUILD/ipu"/*.c 2>/dev/null | head -1) || die "no .c in ipu-bridge-gc2607"
if grep -q 'GCTI2607' "$ipu_c"; then
	echo "   HID present in upstream"
elif patch -p1 -d "$BUILD/ipu" -N < "$ROOT/patches/ipu-bridge-GCTI2607.patch" >/dev/null 2>&1; then
	echo "   HID added by our patch"
else
	die "upstream has no GCTI2607 and the patch did not apply — check $ROOT/patches/ipu-bridge-GCTI2607.patch"
fi

echo "== gc2607: sensor V4L2 driver"
rm -rf "$BUILD/gc2607"
cp -a "$UP/cam/gc2607-kernel" "$BUILD/gc2607"

# ---------- 3. build gxfp (userspace + vendored libfprint) ----------
echo "== build gxfp: userspace and libfprint"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
	JOBS="$JOBS" "$BUILD/gxfp/scripts/build.sh" || die "gxfp build failed"
	meson setup "$BUILD/gxfp/build/libfprint" "$BUILD/gxfp/libfprint" --wipe --prefix=/usr/local \
		--libdir=lib/x86_64-linux-gnu -Ddrivers=gxfp -Ddoc=false -Dintrospection=false \
		-Dgtk-examples=false -Dudev_rules=disabled -Dudev_hwdb=disabled >/dev/null
	meson compile -C "$BUILD/gxfp/build/libfprint" -j "$JOBS" >/dev/null
fi
[ -f "$BUILD/gxfp/build/libfprint/libfprint/libfprint-2.so.2.0.0" ] || die "libfprint not built"
for t in gxfp_capture gxfp_psk_tool gxfp_recovery; do
	[ -x "$BUILD/gxfp/build/userspace/$t" ] || die "utility $t not built"
done

# ---------- 4. package the .deb files ----------
# 4a. gxfp5130-stack
echo "== packaging gxfp5130-stack"
S="$BUILD/deb-gxfp"; rm -rf "$S"
mkdir -p "$S/DEBIAN" "$S/usr/local/lib/x86_64-linux-gnu" "$S/usr/local/bin" \
	"$S/etc/udev/rules.d" "$S/etc/systemd/system/fprintd.service.d" "$S/usr/src" "$S/usr/share/doc/gxfp5130-stack"
cp -a "$BUILD/gxfp/build/libfprint/libfprint/libfprint-2.so.2.0.0" "$S/usr/local/lib/x86_64-linux-gnu/"
ln -s libfprint-2.so.2.0.0 "$S/usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2"
ln -s libfprint-2.so.2 "$S/usr/local/lib/x86_64-linux-gnu/libfprint-2.so"
install -m0755 "$BUILD/gxfp/build/userspace/gxfp_capture" "$S/usr/local/bin/"
install -m0755 "$BUILD/gxfp/build/userspace/gxfp_psk_tool" "$S/usr/local/bin/"
install -m0755 "$BUILD/gxfp/build/userspace/gxfp_recovery" "$S/usr/local/bin/"
install -m0755 "$ROOT/packages/gxfp5130/gxfp-healthcheck" "$S/usr/local/bin/"
install -m0644 "$ROOT/packages/gxfp5130/60-gxfp.rules" "$S/etc/udev/rules.d/60-gxfp.rules"
install -m0644 "$ROOT/packages/gxfp5130/fprintd-gxfp.conf" "$S/etc/systemd/system/fprintd.service.d/gxfp.conf"
cp -a "$BUILD/gxfp/kernel" "$S/usr/src/gxfp-0.1.0"
[ -f "$S/usr/src/gxfp-0.1.0/dkms.conf" ] || die "no dkms.conf in kernel/"
cp -a "$ROOT/patches/fdt-wait-up.patch" "$S/usr/share/doc/gxfp5130-stack/"
md5sum "$S/usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0" \
	"$S/usr/local/bin/gxfp_capture" "$S/usr/local/bin/gxfp_psk_tool" "$S/usr/local/bin/gxfp_recovery" \
	> "$S/usr/share/doc/gxfp5130-stack/expected-md5.txt"
# the manifest must hold the paths as installed (/usr/local/...), not the staging-tree paths
sed -i "s|$S||" "$S/usr/share/doc/gxfp5130-stack/expected-md5.txt"
cp -a "$ROOT/packages/gxfp5130/README.md" "$S/usr/share/doc/gxfp5130-stack/README.md"
date -R > "$S/usr/share/doc/gxfp5130-stack/changelog"; gzip -9n "$S/usr/share/doc/gxfp5130-stack/changelog"
DEPS="dkms, udev, fprintd (>= 1.94.5), $(for b in "$S/usr/local/bin/gxfp_capture" "$S/usr/local/bin/gxfp_psk_tool" "$S/usr/local/bin/gxfp_recovery" "$S/usr/local/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0"; do ldd "$b" 2>/dev/null | awk '{print $3}' | grep '^/'; done | sort -u | while read -r l; do p=$(dpkg -S "$l" 2>/dev/null | head -1 | cut -d: -f1); [ -z "$p" ] && p=$(dpkg -S "$(readlink -f "$l")" 2>/dev/null | head -1 | cut -d: -f1); [ -n "$p" ] && echo "$p"; done | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
SIZE=$(du -sk --exclude=DEBIAN "$S" | awk '{print $1}')
cat > "$S/DEBIAN/control" <<EOF
Package: gxfp5130-stack
Version: $GXFP_VER
Architecture: amd64
Maintainer: local build <root@localhost>
Installed-Size: $SIZE
Section: misc
Priority: optional
Depends: $DEPS
Breaks: libfprint-2-2 (>> 1:1.95.1+tod1-0ubuntu2), fprintd (>> 1.94.5-4)
Recommends: libpam-fprintd
Description: Goodix GXFP5130 fingerprint stack (patched for FW GF_GCC_EC_20069)
 DKMS kernel transport, patched libfprint fork with the gxfpmoc driver and the
 fdt-wait-up fix for firmware GF_GCC_EC_20069, plus capture/provisioning tools
 and a healthcheck. Local build for Huawei MateBook GT 14 (ENZH-XX).
 .
 The package shadows the system libfprint via /usr/local and declares Breaks on
 newer libfprint-2-2/fprintd: upgrades of those packages will be held back until
 the stack is rebuilt (see README).
EOF
printf '/etc/udev/rules.d/60-gxfp.rules\n/etc/systemd/system/fprintd.service.d/gxfp.conf\n' > "$S/DEBIAN/conffiles"
cat > "$S/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in configure)
	if command -v dkms >/dev/null 2>&1; then
		dkms add -m gxfp -v 0.1.0 >/dev/null 2>&1 || true
		if dkms build -m gxfp -v 0.1.0 -k "$(uname -r)" >/dev/null 2>&1; then
			dkms install -m gxfp -v 0.1.0 -k "$(uname -r)" >/dev/null 2>&1 || true
			echo "gxfp: module built and installed for $(uname -r)"
		else
			echo "gxfp: DKMS failed to build the module (no headers/MOK for $(uname -r)?)" >&2
		fi
	fi
	command -v ldconfig >/dev/null 2>&1 && ldconfig || true
	command -v depmod   >/dev/null 2>&1 && depmod -a || true
	if command -v udevadm >/dev/null 2>&1; then
		udevadm control --reload-rules 2>/dev/null || true
		udevadm trigger --subsystem-match=misc 2>/dev/null || true
	fi
	if command -v systemctl >/dev/null 2>&1; then
		systemctl daemon-reload 2>/dev/null || true
		systemctl try-restart fprintd.service 2>/dev/null || true
	fi
	modprobe gxfp 2>/dev/null || true
	;; esac
exit 0
EOF
cat > "$S/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
case "$1" in remove|purge) command -v dkms >/dev/null 2>&1 && dkms remove -m gxfp -v 0.1.0 --all >/dev/null 2>&1 || true; modprobe -r gxfp 2>/dev/null || true ;; esac
exit 0
EOF
cat > "$S/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
command -v ldconfig >/dev/null 2>&1 && ldconfig || true
command -v systemctl >/dev/null 2>&1 && systemctl try-restart fprintd.service 2>/dev/null || true
exit 0
EOF
chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$S/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$S" "$DIST/gxfp5130-stack_${GXFP_VER}_amd64.deb" >/dev/null
echo "   -> $DIST/gxfp5130-stack_${GXFP_VER}_amd64.deb"

# 4b. gc2607-camera-stack
echo "== packaging gc2607-camera-stack"
S="$BUILD/deb-cam"; rm -rf "$S"
mkdir -p "$S/DEBIAN" "$S/usr/src" "$S/usr/share/libcamera/ipa/simple" "$S/usr/lib/systemd/user" \
	"$S/usr/local/bin" "$S/usr/share/doc/gc2607-camera-stack/tools"
cp -a "$BUILD/gc2607" "$S/usr/src/gc2607-0.3.1"
cp -a "$BUILD/ipu" "$S/usr/src/ipu-bridge-gc2607-0.1.0"
[ -f "$S/usr/src/gc2607-0.3.1/dkms.conf" ] || die "no dkms.conf in gc2607-kernel"
[ -f "$S/usr/src/ipu-bridge-gc2607-0.1.0/dkms.conf" ] || die "no dkms.conf in ipu-bridge-gc2607"
install -m0644 "$ROOT/patches/gc2607.yaml" "$S/usr/share/libcamera/ipa/simple/gc2607.yaml"
install -m0644 "$ROOT/packages/gc2607/gc2607-vcam.service" "$S/usr/lib/systemd/user/gc2607-vcam.service"
install -m0755 "$ROOT/packages/gc2607/cam-healthcheck" "$S/usr/local/bin/cam-healthcheck"
cat > "$S/usr/lib/systemd/user/cam-healthcheck.service" <<'EOF'
[Unit]
Description=GC2607 camera stack healthcheck (DKMS + tuning + virtual camera)
Documentation=file:///usr/share/doc/gc2607-camera-stack/README.md

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cam-healthcheck
EOF
cat > "$S/usr/lib/systemd/user/cam-healthcheck.timer" <<'EOF'
[Unit]
Description=Weekly GC2607 camera stack healthcheck
Documentation=file:///usr/share/doc/gc2607-camera-stack/README.md

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
Unit=cam-healthcheck.service

[Install]
WantedBy=timers.target
EOF
cp -a "$ROOT/packages/gc2607/README.md" "$S/usr/share/doc/gc2607-camera-stack/README.md"
cp -a "$ROOT/patches/gc2607.yaml" "$S/usr/share/doc/gc2607-camera-stack/gc2607.yaml"
cp -a "$ROOT/patches/ipu-bridge-GCTI2607.patch" "$S/usr/share/doc/gc2607-camera-stack/"
cp -a "$ROOT/patches/derive-ccm.py" "$S/usr/share/doc/gc2607-camera-stack/tools/derive-ccm.py"
md5sum "$S/usr/share/libcamera/ipa/simple/gc2607.yaml" | sed "s|$S||" \
	> "$S/usr/share/doc/gc2607-camera-stack/expected-md5.txt"
date -R > "$S/usr/share/doc/gc2607-camera-stack/changelog"; gzip -9n "$S/usr/share/doc/gc2607-camera-stack/changelog"
IPA=$(dpkg -S /usr/share/libcamera/ipa/simple/uncalibrated.yaml 2>/dev/null | head -1 | cut -d: -f1)
SIZE=$(du -sk --exclude=DEBIAN "$S" | awk '{print $1}')
cat > "$S/DEBIAN/control" <<EOF
Package: gc2607-camera-stack
Version: $CAM_VER
Architecture: amd64
Maintainer: local build <root@localhost>
Installed-Size: $SIZE
Section: misc
Priority: optional
Depends: dkms, kmod, ${IPA:-libcamera-ipa}
Recommends: v4l2-relayd
Description: GalaxyCore GC2607 camera stack (DKMS modules + libcamera tuning + virtual camera)
 Sensor driver (gc2607), ipu-bridge with the GCTI2607 ACPI HID, libcamera
 simple-IPA tuning with a Ccm matrix, and the user unit for the /dev/video60
 virtual camera. Local build for Huawei MateBook GT 14 (ENZH-XX).
 .
 The virtual camera additionally needs the ABI-pinned package
 linux-main-modules-v4l2loopback-<kernel> (postinst will warn).
EOF
cat > "$S/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
case "$1" in configure)
	if command -v dkms >/dev/null 2>&1; then
		for pv in "gc2607 0.3.1" "ipu-bridge-gc2607 0.1.0"; do
			set -- $pv
			dkms add -m "$1" -v "$2" >/dev/null 2>&1 || true
			if dkms build -m "$1" -v "$2" -k "$(uname -r)" >/dev/null 2>&1; then
				dkms install -m "$1" -v "$2" -k "$(uname -r)" >/dev/null 2>&1 || true
				echo "camera: $1/$2 built and installed for $(uname -r)"
			else
				echo "camera: DKMS failed to build $1/$2 (no headers/MOK for $(uname -r)?)" >&2
			fi
		done
	fi
	command -v depmod >/dev/null 2>&1 && depmod -a || true
	command -v systemctl >/dev/null 2>&1 && systemctl --global enable gc2607-vcam.service 2>/dev/null || true
	command -v systemctl >/dev/null 2>&1 && systemctl --global enable cam-healthcheck.timer 2>/dev/null || true
	if ! modinfo -F filename v4l2loopback >/dev/null 2>&1; then
		echo "camera: WARNING — no v4l2loopback module for $(uname -r)." >&2
		echo "        Install it: sudo apt install linux-main-modules-v4l2loopback-$(uname -r)" >&2
	fi
	;; esac
exit 0
EOF
cat > "$S/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
case "$1" in remove|purge)
	command -v dkms >/dev/null 2>&1 && dkms remove -m gc2607 -v 0.3.1 --all >/dev/null 2>&1 || true
	command -v dkms >/dev/null 2>&1 && dkms remove -m ipu-bridge-gc2607 -v 0.1.0 --all >/dev/null 2>&1 || true
	;; esac
exit 0
EOF
cat > "$S/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
command -v depmod >/dev/null 2>&1 && depmod -a || true
exit 0
EOF
chmod 755 "$S/DEBIAN/postinst" "$S/DEBIAN/prerm" "$S/DEBIAN/postrm"
dpkg-deb --root-owner-group --build "$S" "$DIST/gc2607-camera-stack_${CAM_VER}_amd64.deb" >/dev/null
echo "   -> $DIST/gc2607-camera-stack_${CAM_VER}_amd64.deb"

echo
echo "== done. Packages in $DIST:"
ls -l "$DIST"/*.deb | sed 's/^/   /'
echo "To install: sudo ./scripts/install.sh"
