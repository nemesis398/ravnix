# modules/desktop

huginn's desktop: Sway, Waybar, fuzzel, dunst, swaylock, kanshi and the greetd
login screen. Every `NAME.nix` here is a NixOS module that
`nixosModules.desktop` imports; the directories `sway/` and `waybar/` hold the
data of two of them (the config templates, the helper scripts, the xkb files)
and are no modules. What belongs to the user goes through
`home-manager.sharedModules`. The seams for other modules are written at the
top of `sway.nix` and `waybar.nix`; the options are in `modules/options/desktop.nix`.

`scripts/check.sh` and `nix flake check` run `tests/desktop/sway.nix`
(`nix build .#checks.x86_64-linux.desktop-sway.STAGE` builds one stage:
`evalChecks`, `static`, `styleCheck`, `scriptTests`, `widths`, `udevRules`,
`seamCheck`, `unsupportedGpu`, `badFragmentFails`, `vm`).

`sway-radial.nix` runs the radial menu behind the four-finger pinch
(`packages/sway-radial`) as a user service of the Sway session. Its program is
checked by `tests/desktop/sway-radial.nix` (the pytest suite, in the sandbox),
its files and unit by `tests/desktop/sway-radial-module.nix`, and the VM stage
of `desktop-sway` opens the ring and looks at the pixels. The module lists its
one style exception in its header: the round ring.

## Test seams in the scripts

A script puts its runtime inputs first on its `PATH`, so a stub on the `PATH`
never wins. The scripts therefore read these variables, whose defaults are the
real thing, and the tests set them:

| Variable | Script | Replaces |
| --- | --- | --- |
| `PSDIR` | `waybar-battery`, `-peripherals`, `-powerdraw` | `/sys/class/power_supply` |
| `RAPL` | `waybar-powerdraw` | `/sys/class/powercap/intel-rapl:0` |
| `SYSFS` | `waybar-gpu`, `-gputemp`, `-powerdraw` | `/sys`, for the DRM, hwmon and PCI driver reads |
| `MAGIC_CMD` | `waybar-peripherals` | `magic-trackpad-battery` |
| `PACTL`, `NOTIFY_SEND` | `sway-volume` | `pactl`, `notify-send` |
| `BUSCTL` | `sway-wait-sni` | `busctl` |
| `WAYBAR_MATCH`, `SWAYLOCK_MATCH` | `waybar-launch`, `waybar-clock`, `keep-awake` | the command-line patterns (`^waybar( \|$)`, `^swaylock( \|$)`) that find Waybar and swaylock |

The last row is why the script tests cannot hit the developer's own bar or lock
screen when the sandbox is off: the test sets patterns that match only the
stand-ins it starts, and keeps two decoys named `waybar` and `swaylock` alive
to prove it.

## Findings that are not fixed

* `waybar-gpu` and `waybar-gputemp` show `0%` and `0°C` on a machine without
  amdgpu instead of hiding. Carried over from the Fedora scripts. A host with
  only an NVIDIA or Intel GPU should drop the two modules from its bar.
* `sway-ask` and `sway-calc` have no functional test. They are built with
  flake8, `sway --validate` runs over the config that calls them and the VM
  starts the session, but nothing drives a popup. They were ported unchanged
  except for their tokens.
* The Waybar `min-width` floors are measured with GTK's own layout and
  Waybar's widget naming (`tests/desktop/helpers/measure-widths.py`), not with
  the Waybar binary on a screen. A screenshot-based check of the bar is the
  next step.
* The tuigreet theme is verified by the dominant color of a screenshot and the
  presence of the accent, not key by key.
* systemd user units do not see home-manager's session variables. Processes
  that Sway starts do (the Sway wrapper reads
  `/etc/profiles/per-user/$USER/etc/profile.d/hm-session-vars.sh`). The units
  get only what `systemd.user.sessionVariables` sets, such as `GTK_IM_MODULE`
  in `sway.nix` and rbw's SSH agent socket in `modules/common/rbw.nix`; a unit
  that needs `QT_QPA_PLATFORMTHEME` would have to be given it there.

## Review findings left as they are, with the reason

* **Input devices of the author in the generic config** (`sway/config`: the
  Dygma Defy, the Apple Magic Trackpad, the MX Master 3S bindcodes, the y/z
  swap of the `de` laptop keyboard; `sway/bin/sway-settings`: the 16AHP9's
  Synaptics touchpad ids). They match by device identifier, so they do nothing
  without the device, and they carry no personal value. Moving them is not a
  line but a split of the whole input section into hardware modules or an
  option, with the keyboard layout that the bindcodes depend on. That is a task
  of its own (the hardware directory), not this one.
* **`ravnix.desktop.ask.url` and Task 3.3's Open WebUI address** describe one
  service and are two options. `sway-ask` finds the Open WebUI window by
  `chrome-<host>__`, so the popup's window key works only when the two hosts
  match. The two are joined where 3.3 lands.
* **`power-profiles-daemon` is turned on with `mkDefault`.** If Task 3.4 picks
  another power daemon, it overrides that line.
* **`CLAUDE_CODE_DISABLE_ARTIFACT`** was set in this module's
  `systemd.user.sessionVariables` and is gone. It belongs to the Claude Code
  module, and main already sets it there (`modules/common/claude-code.nix`, in
  both `home.sessionVariables` and `systemd.user.sessionVariables`), so the
  shell and the user manager have it; this module needs nothing.

## Review findings fixed in a way worth knowing

* **dunst's separator is 1 px**, not the compiled default of 2: `docs/style.md`
  allows 1 px frames and 2 px markers and no other width, and a separator is a
  line. The rest of the geometry is dunst 1.13.2's compiled defaults.
* **`custom/peripherals` is an exception to the fixed width** (see the header
  of `waybar.nix`): it shows only while a device battery is low, and reserving
  its cell all day would waste 80 px.
