# 07. Switching keyboard layouts with Ctrl+1 / Ctrl+2

## Problem

Two layouts: the first English (`us`), the second Russian (`ru`).
Required: **Ctrl+1 → English**, **Ctrl+2 → Russian** (deterministically, not "next/previous").

## Why the obvious approaches did not work

| Approach | Result |
|---|---|
| `gsettings set org.gnome.desktop.input-sources current 0/1` | **does not work**: in the GNOME 50 schema the key is marked `DEPRECATED: This key is deprecated and ignored` |
| The stock `switch-input-source` / `-backward` hotkeys | these are "next/previous"; with two layouts both combinations merely toggle instead of selecting |
| D-Bus `org.gnome.Shell.Eval` | disabled: the call returns `(false, '')` |
| A package with an extension from the repository | none (in ubuntu 24 gnome-shell extensions, not one of them about input sources) |
| `ibus engine xkb:ru::rus` | not applicable: ibus does not manage GNOME's xkb layouts here (`ibus engine` is always `xkb:us::eng`; the xkb sources are driven by the shell) |

Also tested: the Scroll Lock LED (`grp_led:scroll`) — this laptop has no physical LED,
and without a focused window `wev` (a Wayland client) receives no keyboard events, so the active
group cannot be observed "from the outside". Conclusion — the mechanism has to live inside the shell.

## Solution: a small GNOME Shell extension

A small extension installed in the home directory under
`~/.local/share/gnome-shell/extensions/layout-switch@fstronin/`
(`metadata.json`, `extension.js`, `schemas/*.gschema.xml` + `gschemas.compiled`).
The extension source is not shipped in this repository; the description below is self-contained.

What it does:
- grabs the shell's internal layout manager: `resource:///org/gnome/shell/ui/status/keyboard.js`
  → `getInputSourceManager()` (the API has `activateInputSource(source, true)`);
- registers two global shortcuts via `Main.wm.addKeybinding`:
  `switch-to-us` = `<Control>1`, `switch-to-ru` = `<Control>2` (schema
  `org.gnome.shell.extensions.layout-switch`);
- on a keypress calls `activateInputSource(inputSources[N], true)` — that is, it **activates
  a specific source** rather than switching "forward/backward";
- logs everything (`[layout-switch] …`), including the list of sources found and the result of the
  activation — these lines show what worked and what did not;
- if the module import fails, it tries to obtain the manager from the panel indicator
  (`Main.panel.statusArea.keyboard`) and logs the errors without breaking the shell.

Enabled by adding it to `org.gnome.shell enabled-extensions` (next to ubuntu-dock and the like).

## Activation and verification

```sh
# extensions are only loaded when the shell starts, and on Wayland the shell does not restart:
# a re-login/reboot is required. Then check that it loaded (the helper script we used for this
# is not shipped in this repository):
gnome-extensions list --enabled | grep -x layout-switch@fstronin   # is it enabled?
gnome-extensions info layout-switch@fstronin
journalctl --user -b -g layout-switch        # live lines when pressing Ctrl+1/Ctrl+2
gsettings get org.gnome.desktop.input-sources mru-sources
```

Expected journal lines (this GNOME Shell extension logs in Russian — its strings are quoted verbatim):

```
[layout-switch] enabled: менеджер=найден, источники=["us","ru"]
[layout-switch] activate(0) → us
[layout-switch] activate(1) → ru
```

The state is also visible via `mru-sources` (the shell updates it on every switch; the first
entry is the current layout) and via the indicator in the top panel.

## Important to know

- **Ctrl+1/Ctrl+2 are intercepted globally** — applications will no longer see them (tabs in
  Firefox, panels in VS Code, etc.). If that gets in the way, change the combinations (below) or remove the extension.
- To change the combinations (after the extension is loaded):

  ```sh
  EXT=~/.local/share/gnome-shell/extensions/layout-switch@fstronin/schemas
  gsettings --schemadir $EXT set org.gnome.shell.extensions.layout-switch switch-to-us "['<Super>1']"
  gsettings --schemadir $EXT set org.gnome.shell.extensions.layout-switch switch-to-ru "['<Super>2']"
  ```

  (the same values live in the extension schema — `schemas/…gschema.xml`, where the defaults can
  also be changed and `glib-compile-schemas` re-run).
- To disable/remove:

  ```sh
  gnome-extensions disable layout-switch@fstronin     # or drop the UUID from org.gnome.shell enabled-extensions
  rm -rf ~/.local/share/gnome-shell/extensions/layout-switch@fstronin
  ```

## If it does not work (fallback options)

1. The journal lines will point to the cause: `менеджер=НЕ найден` — the import path is wrong;
   `нет источника с таким индексом` — the order in `sources` changed.
2. `ydotool` (synthesizing key presses via uinput): on Ctrl+1/Ctrl+2 check `mru-sources` and
   "nudge" with the stock `Super+Space` switching until the desired layout is reached. Requires the
   root daemon `ydotoold` — heavier and "dirtier".
3. At the XKB level: a custom option in `/usr/share/X11/xkb/{symbols,rules/evdev}` with `SetGroup(group=N)`
   bound to Ctrl+1/Ctrl+2. Native and shell-free, but it edits the system xkb files (which get
   overwritten by a `xkb-data` update) and requires a session restart.
