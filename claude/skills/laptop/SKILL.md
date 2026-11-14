---
name: laptop
description: >
  REQUIRED for end-user customization of the desktop, window manager or system
  config of the ravnix laptop, huginn: NixOS with Sway, built from the ravnix
  flake and {{user.name}}'s private flake ({{laptop.model}}). Use when changing
  what Sway, Waybar, kanshi, fuzzel, dunst, swaylock, ghostty or greetd do on
  huginn, or modules/desktop/, modules/hardware/ or modules/theme/ of ravnix.
  Triggers: window rules, keybindings, monitors, outputs, launcher,
  notifications, terminal config, themes (Catppuccin), wallpaper, idle, lock
  screen, screenshots, clipboard history, GTK/Qt theming, keyboard layout,
  fonts, cursors, .desktop entries, installing a package; also NVIDIA /
  prime-run / hybrid GPU, sway fails to start, --unsupported-gpu,
  WLR_DRM_DEVICES, HiDPI / scale, docking, touchpad, battery / charge limit,
  power profiles, lid / suspend, brightness keys, Wi-Fi, Bluetooth, disks and
  partitions, boot order, systemd-boot, kernel parameters, nixos-rebuild,
  rollbacks.
---

# The laptop

The operating manual for huginn, the laptop of ravnix. Nothing on it is
configured by hand: every file under `/etc` and nearly every one under
`~/.config` is generated from two flakes and linked from the Nix store,
read-only. So a change to the machine is a change to one of them, built and
switched to.

| Source | Holds | Where |
|---|---|---|
| ravnix, public | the modules: Sway, Waybar, the theme, the hardware, the tools | `{{laptop.checkout}}` |
| the private flake | {{user.name}}'s values: names, hosts, keys, the hardware choice | `{{laptop.privateFlake}}` |
| the machine's note | the manual: decisions and their reasons, open items | `{{laptop.note}}` |
| `machine-facts` (on PATH) | disks by id, boot entries, driver versions, outputs, radios, **derived live, never remembered** | `machine-facts --write` refreshes the generated block of the note |

## Start here, every time

1. **Read the note**, `{{laptop.note}}`. It is the manual.
2. **Read the module before you change what it makes.** `AGENTS.md` and
   `docs/style.md` of the ravnix checkout bind every change there.
3. **If the task touches hardware, disks, partitions, boot, the GPU or
   anything destructive: run `machine-facts` and believe its output over any
   prose,** this file and the note included.

> **Address disks by `/dev/disk/by-id/…`, never `nvmeXn1`.** NVMe names swap
> between boots. ravnix's disk guard (`ravnix-disk-guard`) chooses the install
> disk by model and serial; nothing writes a disk the configuration does not
> name.

## Which repository a change goes to

- **Behavior and look** (a keybinding, a Waybar module, a window rule, a
  helper script, a package everyone gets): ravnix, `{{laptop.checkout}}`.
  It is public. **Nothing personal goes there**: no name, address, host,
  domain, id or secret, in a file or in a commit message. The gate
  (`scripts/check.sh --fast`) refuses a value of the deny list.
- **A personal value** (an address, a host, a monitor's serial, a key, a
  choice only this user makes): the private flake, `{{laptop.privateFlake}}`,
  through a typed `ravnix.*` option. If the option does not exist yet, it
  belongs in ravnix first, with no default that looks like a real value.
- **Never edit a generated file** under `~/.config` or `/etc`: it is a link
  into the store and the next switch replaces it. Find the module that makes
  it (`readlink -f FILE`, then `rg` the checkout for the file's name).

## The red lines

Short, because getting one wrong ends the session or the battery.

- **Never drop `--unsupported-gpu` or `WLR_DRM_DEVICES`** from the Sway
  session (`modules/desktop/sway.nix` sets both when the NVIDIA driver is
  on), and never give `WLR_DRM_DEVICES` a value with a colon. Either mistake
  is a black screen at login with nothing in the log.
- **Never point `NVreg_TemporaryFilePath` at `/var/tmp` or `/tmp`**
  (`modules/hardware/`): it stays `/var/lib/systemd/sleep`, or suspend aborts
  in a loop and flattens the battery.
- **Never `swaymsg reload` a config that `sway -C` rejects.** Judge `sway -C`
  by its **exit code**; it prints harmless EGL and Vulkan errors on stderr.
- **Never drop an item of the battery safety net**
  (`battery-emergency-poweroff.timer`, UPower's critical action `PowerOff`).
- **Never write a hex color outside `modules/theme/`.** A color comes from the
  theme's roles (`config.ravnix.theme.roles`, `palette` for the state hues).
- **Build before you switch.** A switch that fails half-way leaves the old
  generation; a broken one boots, so roll back with
  `nixos-rebuild switch --rollback` or the previous entry of systemd-boot.

## Working rules

**Changing the desktop** → edit the module in the checkout, run the module's
check (`nix build .#checks.x86_64-linux.NAME`; `tests/desktop/` has them),
then build the host against the checkout and switch to it:

```bash
cd {{laptop.checkout}}
nix build {{laptop.privateFlake}}#nixosConfigurations.huginn.config.system.build.toplevel \
  --override-input ravnix git+file:.
sudo nixos-rebuild switch --flake {{laptop.privateFlake}}#huginn --override-input ravnix git+file:.
```

`git+file:` takes the tracked files only, so `git add` a new file first, or
the build does not see it. Ask {{user.name}} before the `sudo` step.

**After a switch** → reloading Sway does not restart dunst, swayidle or the
clipboard watchers, which are user services or plain `exec`s; restart what
you changed and say so.

**Binding a key** → search the Sway config for the key first
(`rg -n 'bind(sym|code|gesture)' modules/desktop/sway/`), and say what the key
did before.

**Building a desktop helper** (a calculator, a chat, any picker) → design the
fuzzel-only version first. Propose a terminal window only when fuzzel cannot
do the job, and say what blocks it. `sway-ask` shows how far `--mesg` goes.
A new helper is a tool, and a new tool is Odin (`AGENTS.md`, rule 4).

**Anything themed** → the theme module and `docs/style.md`: Catppuccin Mocha,
the one accent, JetBrainsMono Nerd Font, square corners, no transparency, no
motion. Never a second accent.

**Installing something** → a package in nixpkgs goes into the module of its
kind (`modules/desktop/apps.nix` for a graphical application); what nixpkgs
lacks becomes `packages/NAME/`. Nothing is installed imperatively.

**Handing the user a line to paste** → give it clean and alone. Sway hands
everything after an `exec` command to `sh`, so a trailing annotation becomes
arguments and breaks it. Explain around the block, never inside it.

## Verify before you claim

- Sway config: `sway -C` and its exit status (prefix `WLR_BACKENDS=headless`
  from SSH); the module's own check runs it in the sandbox too.
- Live session from a shell without the socket:
  `export SWAYSOCK=$(ls /run/user/$(id -u)/sway-ipc.*.sock)`, then
  `swaymsg -t get_tree`; `grim` for a screenshot when the check is visual.
- A locked session's `grim` shot shows only the swaylock overlay. Check
  `pgrep swaylock` before trusting an empty desktop, never unlock remotely,
  and verify some other way.
- `gtk-launch` from an agent shell fails with `cannot open display`. Test a
  `.desktop` the way a keybinding runs it: `swaymsg exec 'gtk-launch <id>'`.
- A check that launches a window diffs the container ids in `get_tree`
  before and after, and kills only the ids it created.
- dGPU power state: read `…/power/runtime_status` **before** `nvidia-smi`:
  any `nvidia-smi` call wakes the card.

## Writing back: keeping the note true

The note is the memory. When work changes the machine, update it in the same
session, or the next one starts from a lie.

- **A fact the machine now reports differently** → `machine-facts --write`.
  Never hand-edit between the `machine-facts:begin/end` markers.
- **A decision, a reason, or a trap learned the hard way** → a bullet in the
  note's *Decisions and scar tissue*, saying what breaks if someone does the
  other thing. If it is true of every ravnix laptop, it belongs in the module's
  header or README as well.
- **An open item you finished** → tick it and move it to the completed line,
  dated.
- `machine-facts --check` says whether the note has drifted (exit non-zero
  and a diff). Live readings are excluded so it does not cry wolf.

Never restate a `machine-facts` value in the hand-written half.

## Example requests

- *"Bind Super+E to the file manager"* → search the bindings, add the
  `bindsym` to the module, run its check, build,
  switch, `swaymsg reload`.
- *"Make new windows of app X float"* → `app_id` from `get_tree`, a
  `for_window` rule in the module (`floating enable` → `resize set` →
  `move position center`), check, build, switch.
- *"Which disk can I wipe?"* → `machine-facts`, answer in `by-id` names, and
  say what is on the other disk from its actual partition types.
- *"Games run on the wrong GPU"* → `prime-run`, verify with
  `prime-run glxinfo | grep vendor`.
- *"Theme this new app"* → its colors from the theme's roles in the module
  that installs it; if it cannot follow `docs/style.md`, list it as an
  exception there, with the reason.
