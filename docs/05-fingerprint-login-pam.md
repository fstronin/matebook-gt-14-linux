# 05. Fingerprint login and sudo (PAM)

## What is enabled

The stock Debian/Ubuntu mechanism — a `pam-auth-update` profile:

```sh
sudo pam-auth-update --enable fprintd
```

The profile `/usr/share/pam-configs/fprintd` ("Fingerprint authentication", `Default: no`) added
to `/etc/pam.d/common-auth` (line 17, the start of the Primary block) a line that currently reads:

```
auth	[success=3 default=ignore]	pam_fprintd.so max-tries=5 timeout=10 # debug
```

(save a backup of the original first, e.g. `sudo cp /etc/pam.d/common-auth /root/common-auth.bak`;
the `success=N` jumps are recalculated by pam-auth-update automatically, `pam_deny` is not skipped:
after a successful fingerprint, control goes to `pam_permit`).

Note on `success=end`: the profile (`/usr/share/pam-configs/fprintd`) and the record in `/var/lib/pam/auth`
hold exactly `end` — that is a pam-auth-update pseudo-value, turned into a number at generation time
(`end` → `3`). Live libpam does not understand that value: a line with `success=end` produces
`PAM pam_parse: expecting jump number` in the journal.

`common-auth` is included in the `sudo`, `su`, `login` and `gdm-password` stacks, so the fingerprint works
both in graphical password prompts and on the lock screen. There is no separate `/etc/pam.d/polkit-1`
file on this system: polkit asks for the `polkit-1` service, PAM does not find the file and falls back to
`/etc/pam.d/other`, which also `@include common-auth` — the journal shows
`polkit-agent-helper-1` bringing up `net.reactivated.Fprint`. For the GDM login screen there is a separate
service `/etc/pam.d/gdm-fingerprint` (+ `org.gnome.login-screen
enable-fingerprint-authentication = true`), so fingerprint login is offered on the login screen.

## Number of tries: 5 instead of 1 (2026-10-07)

The Ubuntu profile sets `max-tries=1`: after **one** unrecognized fingerprint `pam_fprintd`
returns `PAM_MAXTRIES`, the `default=ignore` control lets it through — and the password prompt appears
immediately. Fixed:

```sh
sudo sed -i 's/max-tries=1/max-tries=5/' /etc/pam.d/common-auth /usr/share/pam-configs/fprintd
```

Why this way rather than re-running `pam-auth-update`:

- `/etc/pam.d/common-auth` is what is actually read during authentication; the edit takes effect
  immediately (PAM parses the file on every request), no re-login or restart is needed.
- On subsequent updates `pam-auth-update` **preserves** local option edits: it compares
  the live file against the record in `/var/lib/pam/` and carries the differences over as add/remove
  relative to the profile (`merge_one_line()` in `/usr/sbin/pam-auth-update`). So `max-tries=5` will not
  be reverted on its own.
- `/usr/share/pam-configs/fprintd` is edited for consistency (a `libpam-fprintd`
  package update will overwrite the file, but the live edit from `common-auth` is still carried over).

Semantics (from the `pam_fprintd` 1.94.5 source, `pam/pam_fprintd.c`):

- `max-tries=N` — a `while (max_tries > 0)` loop; the counter is decremented **only** on
  `verify-no-match` ("not recognized"). Tries exhausted → `PAM_MAXTRIES` → `default=ignore` →
  then `pam_unix` → password prompt.
- `timeout=N` — the window for **each** attempt. If no finger is presented at all, the window expires →
  `PAM_AUTHINFO_UNAVAIL` and the module exits **without** retries: five tries means five "not recognized"
  results, not five timeouts.
- Worst case: 5 misses × 10 s ≈ 50 s before the password prompt. The window and the number of tries are edited with the same
  `sed` (`timeout=` — the module default is 30 s, a negative value means no limit; `max-tries=`
  negative means no limit either, but then the module never hands control back to the password).
- The line in `/etc/pam.d/gdm-fingerprint` is a bare `pam_fprintd.so`, i.e. it uses the module defaults
  (3 tries, 30 s). If 5 tries are wanted on the login screen too, add `max-tries=5` there as well.
- The `# debug` in Ubuntu's line is **inert**: libpam ends the line at `#`, so the `debug` token never
  reaches the module (verified: with `# debug` the journal contains no `pam_fprintd` lines at all, with a
  plain `debug` token it does). To see the option parsing, put `debug` **first** in the list
  (the parser runs left to right, and `max_tries specified as:` is printed only once debug is already on) —
  then the journal shows:

```
pam_fprintd(sudo:auth): debug on
pam_fprintd(sudo:auth): max_tries specified as: 5
pam_fprintd(sudo:auth): timeout specified as: 10 secs
```

## How it was verified (actual output)

(1) Behaviour before the edit — one fingerprint and the fallback:

```
$ sudo -k; sudo -v
[sudo] Place your right index finger on the fingerprint reader   ← asked for a fingerprint
[sudo] Verification timed out                                    ← 10 s without a finger
[sudo: authenticate] Password:                                   ← fallback to password
sudo: Authentication failed, try again.                          ← wrong password rejected as expected
```

(2) That `max-tries=5` reaches the module (2026-10-07, without a physical finger): a copy of the `sudo`
stack with an added `debug` token, started via `pam_start_confdir()` — the journal shows
`pam_fprintd(sudo:auth): max_tries specified as: 5`, there are no PAM parse errors, the device
(`Device/0`) opens, `VerifyStart` is sent. The "5 rounds of Place your finger…" themselves require real
finger misses and are checked manually: `sudo -k && sudo true` (after the fifth "not recognized" a
`Password:` prompt should appear).

```
$ fprintd-list $USER
Fingerprints for user fstronin on Goodix GXFP5130 eSPI Fingerprint Sensor (press):
 - #0: right-index-finger
```

## Pitfalls

- Disable everything: `sudo pam-auth-update --disable fprintd` (restores the previous `common-auth`;
  make your own backup first, e.g. `sudo cp /etc/pam.d/common-auth /root/common-auth.bak`). Back to one try instead of five:
  `sudo sed -i 's/max-tries=5/max-tries=1/' /etc/pam.d/common-auth`.
- `pam-auth-update` writes through debconf; if apt/debconf is running concurrently, it fails with
  "config.dat is locked by another process" — just retry.
- `systemctl is-active fprintd` shows `inactive` if the daemon is not running — it is started
  over D-Bus on first use (`fprintd-list`, login, `sudo`).
- If no fingerprint is offered on the login screen: check
  `gsettings get org.gnome.login-screen enable-fingerprint-authentication` (should be `true`),
  that a finger is enrolled (`fprintd-list`), and that `fprintd` is active.
