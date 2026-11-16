# copilot-key-super

The IdeaPad Pro 5 16AHP9's Copilot key as a plain second Super. Ported from
the Python daemon of the earlier Fedora setup (`copilot-key-super.py`, on
python-evdev), whose cases its tests carry over.

```sh
copilot-key-super [--root DIR]   # the daemon
copilot-key-super --filter       # input_event records, stdin to stdout
```

`modules/hardware/ideapad-pro-5-16ahp9/keys.nix` runs the daemon as a
service.

## What the key sends

Measured on the laptop with evdev, on Fedora:

```
press    KEY_LEFTMETA (0xdb) -> KEY_LEFTSHIFT (0x2a) -> KEY_F23 (0x6e)
release  KEY_F23 -> KEY_LEFTSHIFT -> KEY_LEFTMETA
```

That is Microsoft's Copilot chord, Super+Shift+F23, about 1 ms between keys.
The keys stay down as long as the key is held: a 2333 ms hold gave a 2333 ms
F23. The Shift is scancode 0x2a, the real left Shift's, so a hwdb remap
cannot touch it without killing the real Shift, and libxkbcommon, which Sway
uses, has no action that clears a modifier. Super is already in the chord;
the whole job is to cancel the Shift, and that takes a grab.

## What it does

- **Finds the keyboard by name**: the lowest `/sys/class/input/eventN`
  whose `device/name` is exactly `AT Translated Set 2 keyboard` (one trailing
  newline dropped, nothing else), never by event number. It reads at most
  512 bytes of a name. It then opens `/dev/input/eventN` and checks with
  `EVIOCGNAME` that the node is still that keyboard.
- **Makes the virtual keyboard** on `/dev/uinput` before it grabs: the keys,
  scancodes (`EV_MSC`) and LEDs the keyboard has, plus left Shift and left
  Meta, named `copilot-key-super` with vendor 1, product 1 and version 1,
  which Sway's config finds as `1:1:copilot-key-super`.
- **Waits up to 1 s for every key to be up**, then grabs the keyboard
  (`EVIOCGRAB`). A key held across the grab would never be released for
  whoever saw its press.
- **Translates** (`translate.odin`), one event in and at most one out:
  - F23 is never forwarded; nothing but the Copilot key sends it.
  - The macro: an F23 press while the left Meta is down, with a left Shift
    press (value 1) that came after the last Meta press and less than 50 ms
    before the F23. The Shift is then released on the virtual device, and
    the keyboard's own release of it and its repeats are swallowed. Sway sees
    Super alone. The Shift is down on the virtual device for the 1 ms until
    F23, which nobody can observe.
  - A Shift the user already held arrives as a repeat (atkbd reports a press
    of a key that is down as 2), so it opens no window: Shift, then Copilot,
    is Super+Shift.
  - A new Shift press (value 1) ends a cancel, and it and its release go
    through.
  - Everything else passes as it is.
- **Keeps the keyboard's frames**: events go out between the same
  `SYN_REPORT`s they came in. A frame the filter emptied (F23 alone) gets no
  report.
- **Resyncs after lost events**: after a `SYN_DROPPED` it drops everything up
  to the next report, reads the keyboard's keys (`EVIOCGKEY`) and writes the
  presses and releases that bring the virtual device to them. A cancelled
  Shift stays released while F23 is still down.
- **Stops on the first failure**, with one line on standard error and exit
  status 1: no keyboard, a node that is not one, no `/dev/uinput`, a failed
  ioctl, a keyboard that goes away (`ENODEV`), a failed read or write. The
  grab and the virtual device end with the process, and the kernel gives the
  raw keyboard back with the key at its stock behaviour. The only blocking
  call is the keyboard's read, so it cannot hang while it holds the grab.
  SIGTERM keeps its default action; systemd counts that as a clean stop.
- **`--filter`** runs the same translation from standard input to standard
  output, with no device; a `SYN_DROPPED` there resyncs to no key held. The
  bench uses it.

## Changes from the Python

- **The window is measured on the events' own times**, from the kernel, on
  the monotonic clock (`EVIOCSCLOCKID`). The Python used `time.monotonic()`
  when it read each event, so a daemon held up between the Shift and the F23
  could miss the window. A clock that seems to go backwards (the realtime
  clock, if `EVIOCSCLOCKID` fails) opens no window.
- **The Shift must come after the Meta press.** Shift, then Copilot within
  50 ms (a fast Super+Shift chord) cancelled the user's own Shift in the
  Python; here it stays.
- **Frames are kept.** The Python dropped every `SYN` and wrote each event as
  a frame of its own, so a scancode and its key arrived in two frames.
- **`SYN_DROPPED` is handled.** The Python ignored it and forwarded what came
  after, so a release lost in an overflow left the key stuck down in Sway,
  repeating.
- **It waits for the keys to be up before it grabs.** The Python grabbed at
  once.
- **The virtual keyboard is on the keyboard's own bus** (i8042 on the
  laptop) instead of python-evdev's default, USB. libinput takes a PS/2
  keyboard for an internal one (its `10-generic-keyboard.quirks`), and pairs
  only an internal keyboard with the touchpad's disable-while-typing and the
  lid switch. On USB the virtual keyboard is an external one, so by
  libinput's rules typing on it does not hold off the touchpad; that was read
  from libinput, not measured on Fedora. Sway's identifier has no bus, so it
  still matches.
- **It runs as a dynamic user** in the `input` and `uinput` groups, not as
  root (`keys.nix`), so the check for root is gone; a missing permission is a
  failed open with its errno.
- Same as the Python, on purpose: no `EV_REP` on the virtual device (the
  Python's `EV_REP` capability had no codes, so python-evdev never set it),
  so the kernel does not repeat keys there on its own and the keyboard's
  repeats are forwarded; the phys is `copilot-key-super`; SIGTERM ends it.

## Tests and bench

`tests/` has the Python's cases and the ones it missed, as event sequences
through `translate`: the macro, with scancodes, held with repeats, twice,
with a real Shift (left or right) or Super held before it, a Shift pressed
just before it, the window's edges, a clock that goes back, releases without
a press, odd values and codes, frame bounds, `SYN_DROPPED` and its resync,
and a burst of a million frames. The device side runs on a fake sysfs (near
names, odd entries, `event10` against `event9`, a huge name, no sysfs) and
the ioctl numbers and struct sizes are checked against the values a C
program built on the flake's kernel headers printed. The loop runs on real
files and pipes, and on a fake reader for `ENODEV`, `EIO`, `EINTR`, a byte
at a time and a torn last event. `tests/hardware/copilot-key-vm.nix` runs
the daemon in a VM, under huginn's unit, against QEMU's PS/2 keyboard.

The bench translates `bench/typing.events` with `--filter`: 4096 events of
typing with scancodes, Shift and Copilot presses, held with repeats. It is
the output of `make_stream` in `tests/pump_test.odin`; to write it again:

```sh
COPILOT_KEY_SUPER_WRITE_BENCH=$PWD/tools/copilot-key-super/bench/typing.events \
  nix shell --inputs-from . nixpkgs#odin --command odin test tools/copilot-key-super/tests \
  -define:ODIN_TEST_RANDOM_SEED=1 \
  -define:ODIN_TEST_NAMES=copilot_key_super_tests.the_bench_stream_holds_the_macro \
  -out:"${TMPDIR:-/tmp}/copilot-key-super-tests"
```

## Findings not fixed

- **A real Shift held across a Copilot press is let go on its release.**
  The macro's own Shift release reaches the kernel as a release of the left
  Shift while the user still holds it, as it does without the filter. The
  filter cannot tell the two apart without knowing how the keyboard's
  controller reports a Shift pressed during its own macro, which is not
  measured.
- **Copilot first, then Shift, may lose the Shift.** While the macro holds
  0x2a, a real left Shift press is a repeat for atkbd, and a repeat is
  swallowed while the Shift is cancelled. Whether the controller sends one at
  all is not measured; the installer's note that "Shift still works
  normally" holds for Shift first, then Copilot. Measure with evtest on the
  raw keyboard (filter stopped) before changing this.
- **A real left Super held across a Copilot press is let go** on the macro's
  Meta release, as without the filter.
- **The LEDs do not reach the keyboard.** The virtual device takes LED
  events and nothing reads them back to the grabbed keyboard, as in the
  Python. On the laptop Caps Lock is Escape, so only a Num Lock LED could
  miss them.
- **The first start can come before the keyboard.** In the VM the unit
  started before atkbd had probed and failed once with "no input device
  named"; the restart 2 s later grabbed it. On the laptop it costs one of
  the 5 starts in 60 s at most. A udev rule that starts the unit when the
  keyboard appears would close this.
- **Nothing checks that `bench/typing.events` is still `make_stream`'s
  output**: the tests cannot read `bench/`, which `lib/odin.nix` leaves out
  of their source.
- **Only the laptop can show** the real macro's timing and repeats against
  the 50 ms window, and that disable-while-typing now pairs with the virtual
  keyboard (`libinput quirks list` on it says
  `AttrKeyboardIntegration=internal` in the VM).
