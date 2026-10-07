# 04. Secure Boot, module signing and the MOK key

## Why this is needed

On this machine `Secure Boot = enabled` and the kernel runs in `lockdown=[integrity]`. Therefore any
external (DKMS) module must be signed with a key the firmware trusts, otherwise `modprobe` returns
**`Key was rejected by service`** (which is exactly what we saw before the key was enrolled).
The stock `linux-main-modules-*` are signed by Canonical — they can be installed with no fuss; ours
(`gxfp`, `gc2607`, `ipu-bridge-gc2607`, `hwlogo`) are not.

## What was done

```sh
# 1. key pair (Ubuntu convention — this exact path; DKMS takes it from the config)
sudo install -d -m 0700 /var/lib/shim-signed/mok
sudo openssl req -new -x509 -newkey rsa:2048 \
     -keyout /var/lib/shim-signed/mok/MOK.priv -outform DER -out /var/lib/shim-signed/mok/MOK.der \
     -nodes -days 36500 -subj "/CN=$(hostname) Secure Boot Module Signature key"
sudo chmod 600 /var/lib/shim-signed/mok/MOK.priv

# 2. DKMS must know what to sign with (the dkms deb package reads /etc/dkms/framework.conf)
grep -n mok /etc/dkms/framework.conf
#   mok_signing_key="/var/lib/shim-signed/mok/MOK.priv"
#   mok_certificate="/var/lib/shim-signed/mok/MOK.der"

# 3. enroll the key into NVRAM WITHOUT interaction (a plain `mokutil --import` asks for the password on the tty)
mokutil --generate-hash=YOUR_PASSWORD > /tmp/hash.txt       # prints a crypt hash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der --hash-file /tmp/hash.txt
mokutil --list-new      # root only! (the efivar MokNew has mode 0600)

# 4. reboot → blue "Perform MOK management" screen:
#    Enroll MOK → Continue → Yes → the same password → Reboot
```

The one-time enrollment password actually used: `<redacted — kept only in the author's local notes>`
(it is not needed now — the key is enrolled; it will only be required if it has to be enrolled again).

After that DKMS signs the modules it builds by itself (in `dkms install` logs you can see
`Sign command: /usr/bin/kmodsign`, `Signing key: …MOK.priv`).

## Verification

```sh
mokutil --sb-state                                    # SecureBoot enabled
mokutil --test-key /var/lib/shim-signed/mok/MOK.der   # after enrollment: "is already enrolled"
modinfo gxfp | grep -E '^signer|^sig_id|^vermagic'    # signer=fstronin-ENZH-XX …
dkms status                                           # our packages installed (gxfp, gc2607, ipu-bridge-gc2607, hwlogo)
```

The expected signature on all our DKMS modules (`gxfp`, `gc2607`, `ipu-bridge-gc2607`, `hwlogo`):
`sig_id: PKCS#7`, `signer: fstronin-ENZH-XX Secure Boot Module Signature key`,
`vermagic: 7.0.0-38-generic SMP preempt mod_unload modversions` (the current kernel; on the still
installed `-30` it will be `7.0.0-30-generic`).

## What happens on a kernel update

- Our DKMS packages (`gxfp`, `gc2607`, `ipu-bridge-gc2607`, `hwlogo`) are built with `AUTOINSTALL=yes` →
  when a new kernel is installed DKMS rebuilds and **re-signs** them with the same key; nothing to do.
- **Not all external modules go through DKMS**: `v4l2loopback` is installed as the signed Canonical
  package `linux-main-modules-v4l2loopback-<abi>` and is **pinned to the kernel ABI** — after a kernel
  upgrade it must be installed by hand (`apt install linux-main-modules-v4l2loopback-$(uname -r)`),
  otherwise there will be no virtual camera `/dev/video60`. Details and verification — `03-camera-gc2607.md`.
- Conditions that must be preserved: the files `/var/lib/shim-signed/mok/MOK.{priv,der}` and the
  enrolled certificate in NVRAM. If the key is lost (`rm`, a reinstall that wipes `/var`), the modules
  stop loading — fixed by generating a new key and enrolling it again (see above).
- The sources for a rebuild live in `/usr/src/{gxfp-0.1.0,gc2607-0.3.1,ipu-bridge-gc2607-0.1.0}`
  (root) and in `/var/lib/dkms/*`. In our development tree a helper script (not shipped in this
  repository) deliberately moved `gc2607` from a symlink into `/var/tmp/hw` to a real folder
  `/usr/src`: systemd-tmpfiles prunes `/var/tmp` by age (30 days), and depending on it would break
  the rebuild.

## If you would rather not deal with MOK

You can disable Secure Boot in the UEFI — then unsigned DKMS modules load without a key.
Keeping the MOK key in NVRAM while doing so is safe (it only grants the right to sign those modules
that DKMS builds on this machine).
