# bitwarden-menu

bitwarden-menu 0.6.0 (`bwm`, nixpkgs has it) with `bw` on its PATH, a
`wl-copy` that keeps copied passwords out of the clipboard history, and a
launcher entry ("Bitwarden Menu"). `modules/desktop/bitwarden-menu.nix`
installs it and writes its `config.ini`; the header of the package says why
each of the four exists.

`tests/desktop/bitwarden-menu-wrapper.nix` runs the wrapper with a stand-in for
`bwm` (to see the PATH it builds), starts the real `bwm -V`, and drives a
headless Sway with the session's `wl-paste --watch cliphist store` watchers: a
plain copy is recorded (the control), a copy through the wrapper is not, and
bwm's clear leaves the history as it was.

## Findings that are not fixed

- Nothing here ran against a server: the check makes no network login. The
  first login on huginn is the test of the server address, the mail address and
  the two-factor type.
- Only a copy through this `wl-copy` is kept out of the history. cliphist 0.7.0
  does not read the `x-kde-passwordManagerHint` type itself: it acts on the
  `CLIPBOARD_STATE=sensitive` that `wl-paste --watch` (wl-clipboard 2.3) sets
  for it. A copy from the browser extension or the desktop app is recorded
  unless that app sets the state through `wl-copy --sensitive` or an equivalent.
- bwm's README says a copy is cleared "after 1 paste on Wayland". The 0.6.0
  code does not use `--paste-once`; it clears after 30 seconds. `--paste-once`
  would not help here either, because the history watcher is a paste.
- bwm hides what is typed only for dmenu, rofi, bemenu and wofi. Under fuzzel
  the prompts `Password` and `Verify password` (typing a password into an item
  by hand) show it; the master password and the 2FA code go through the
  pinentry and are hidden.
- Whether bwm shows, types or edits SSH-key items is not stated by its README
  and not tried.
- The pinentry window (pinentry-qt) opens on Wayland, as the check shows, but
  was not seen on screen.
