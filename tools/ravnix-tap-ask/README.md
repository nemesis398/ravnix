# ravnix-tap-ask

Asks on the laptop's own screen before sudo waits for a tap on the security
key. With `ravnix.security.u2f.enable`, a tap stands in for the password
(`modules/desktop/u2f.nix`). sudo also runs without a terminal: a program of
the user's, or a command that the server sends over the laptop-access link,
which runs any command as the user. There pam_u2f's "Please touch the FIDO
authenticator." goes to the caller and nobody at the laptop sees it, and the
key's blink looks like that of a git push. This tool puts a popup between the
two, so that a touch always answers a question the laptop's screen has
asked.

```sh
ravnix-tap-ask [--dry-run] [--root DIR] [--parent PID] [--user NAME] [--tty TTY]
```

pam_exec runs it as root, right before pam_u2f in sudo's auth stack and in no
other:

```
auth [success=ignore default=1] pam_exec.so quiet quiet_log seteuid .../bin/ravnix-tap-ask
auth sufficient                 pam_u2f.so appid=pam://ravnix cue origin=pam://ravnix
auth sufficient                 pam_unix.so likeauth try_first_pass
```

Exit 0 lets pam_u2f run. Any other exit jumps over that one line, and the
rest of the stack runs as before: a terminal sudo asks for the password, and
one without a terminal fails because it has no way to ask. A jump sets no
result of the stack (Linux-PAM's `pam_dispatch.c`), so a failure of the tool,
even a crash, can only skip the tap and never grant anything.

## What it decides

| Exit | When |
| --- | --- |
| 0 | the popup's Allow was chosen, a second or more after it opened |
| 1 | `PAM_TYPE` is not `auth`; the user is not in `/etc/passwd`; there is no `~/.config/Yubico/u2f_keys` (or it is empty); no FIDO key is plugged in; a `swaylock` of the user runs; the user has no Wayland socket; Deny, Esc or a click elsewhere; no answer in 30 seconds; an Allow sooner than a second; the popup did not start or printed what fuzzel never prints |
| 2 | bad usage |

In the order it checks:

1. **The user**, `PAM_USER`, from `/etc/passwd`: its uid, gid and home.
2. **A mapping**, `~/.config/Yubico/u2f_keys`, a regular file that is not
   empty. pam_u2f reads only that file under sudo, since sudo is setuid and
   pam_u2f ignores `XDG_CONFIG_HOME` there. Without it pam_u2f fails anyway,
   and a popup would ask for nothing.
3. **A key**: a `/sys/class/hidraw/*/device/report_descriptor` that declares
   FIDO's usage page 0xF1D0, as libfido2 recognizes a key. Without one there
   is nothing to touch.
4. **Where the sudo came from**, for the popup. An ssh login comes first: an
   ancestor of sudo that runs `sshd` or `sshd-session` (by its `exe` link,
   which a process cannot rename, or its `comm` where the link cannot be
   read), or `SSH_CONNECTION` in sudo's environment, whose first field is
   the client. huginn's sshd takes one key, the server's laptop-access key,
   so an ssh login is that link. It comes first because a terminal can be
   made inside such a login (`script`). Then `PAM_TTY`, a terminal on the
   laptop. Otherwise a program without a terminal, named by the `comm` of
   sudo's parent.
5. **The command**: sudo's own `/proc/PID/cmdline`, its arguments joined by
   spaces. A control character becomes `?`, so an argument cannot start a
   line of its own and fake one of the popup's. Invalid UTF-8 becomes U+FFFD,
   and the command is cut at 200 bytes, at a character, with `…`.
6. **The lock screen**: a process named `swaylock` (or `.swaylock-wrapp`,
   NixOS's wrapper, cut to 15 bytes) with the user's real uid. The lock
   screen covers the popup, so nobody could answer it.
7. **The session**: a socket `wayland-N` in `/run/user/UID`, the lowest N when
   there are several. A file of that name that is not a socket, which a
   crashed compositor can leave, is no session.

The popup is fuzzel in dmenu mode, run as the user, never as root on the
user's display:

```
setpriv --reuid=UID --regid=GID --clear-groups --no-new-privs -- \
  fuzzel --dmenu --index --only-match --no-sort --layer=overlay \
         --lines=2 --minimal-lines --namespace=ravnix-tap-ask \
         --placeholder='Allow or Deny' --mesg=MESSAGE
```

Its input is `Deny` and `Allow`, in that order. Deny is the entry that is
selected, so an Enter by habit denies, and `--only-match` takes nothing
typed. Its environment is the session and nothing else: `WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR`, `HOME`, `USER`, `LOGNAME`, a `PATH` and `LANG`. Nothing of
sudo's environment or of PAM's reaches it. The message:

```
sudo wants a tap on the security key

command  sudo systemctl restart nix-daemon
user     alice
from     a terminal on this laptop, /dev/pts/3

Allow, then touch the key. Deny, Esc or 30 s: no tap.
```

The `from` line is `ssh from ADDRESS (the server's laptop-access link)`,
`a terminal on this laptop, TTY`, or `a program without a terminal, NAME`.
An Allow sooner than a second after the popup opened counts as typed through
by accident, for example while the user was typing in the window that the
popup took the keyboard from, and denies. fuzzel's index output is all it
reads: exactly `1` is Allow, `0` or an exit 1 with nothing is Deny, and
anything else fails. After 30 seconds the popup is killed.

`--dry-run` decides without the popup, prints the reason it would skip or
the popup's command line, and exits 0, so you can see why no popup came:
`sudo ravnix-tap-ask --dry-run --user $USER --tty $(tty)`. `--root` reads
`/proc`, `/sys`, `/run` and `/etc/passwd` under another directory, for the
tests and the bench. `--parent`, `--user` and `--tty` stand in for sudo's
pid, `PAM_USER` and `PAM_TTY`. None of the flags is in the PAM line, and a
user who runs the program has no privilege to gain from them.

## Why fuzzel, and why Odin

fuzzel and not zenity. fuzzel is already the menu behind every popup of the
desktop, and the theme module styles it from the roles: Base, a 1 px accent
frame, square corners, opaque colors, fixed width (`modules/theme/default.nix`,
`docs/style.md`). Its config is the user's own, which it reads because it
runs as the user. It is a layer-shell surface on the overlay layer, so Sway
does not tile it, and it holds the keyboard until it is answered. zenity is
GTK: a toplevel window that Sway would tile or float by a rule, styled by the
GTK theme and not by ravnix's roles, and it pulls GTK into a PAM path.

Odin and not Bash (AGENTS.md, rule 4). This is no wrapper. It decides who
may reach a security key, reading `/proc`, `/sys` and `/etc/passwd`, and each
step has edge cases that the tests hunt for: the pid in a comm with
parentheses, a loop in the process tree, a stale socket, a command line with
escapes. It runs as root inside sudo's PAM stack, where a shell's word
splitting and `IFS` are a liability, and it must fail closed on every error.

## Tests

`ravnix-tap-ask-tests` builds a system under a temporary root for each test
(`/etc/passwd`, the mapping, `/sys/class/hidraw` with a FIDO and a keyboard
descriptor, processes in `/proc` with their `exe` links, a real Unix socket
for Wayland). The popup is `tests/testdata/fake-fuzzel` behind
`tests/testdata/fake-setpriv`. They record their arguments, environment and
input, and answer as the test says. The tests cover:

- **No popup, and so no tap**, in each case where none fits: not auth; an
  unknown user, an empty one, or one with a `:`; a missing, empty, or
  directory mapping; only a keyboard, or no hidraw; a locked screen (the
  user's swaylock by either name, while another user's does not count); no
  session (a stale file, the lock file alone, `wayland-x`, `wayland-01`, no
  runtime directory).
- **Every answer but Allow skips the tap**: Deny, Esc, an Allow that is too
  soon, output fuzzel never prints, too much output, a crash, a popup that
  does not start, and no answer, which is killed after the timeout.
- **The origin**: a terminal; ssh with a terminal made inside it; ssh by its
  program while it calls itself `sshd: alice@notty`; ssh by
  `SSH_CONNECTION`, with the client; a program without a terminal; a loop in
  the process tree; a sudo whose parent is gone.
- **The popup itself**: the command shown safely; the message; setpriv's
  drop to the user's uid and gid; fuzzel's flags; its input; its environment
  without PAM's or the test runner's.
- **The link from the server**: a sudo from sshd-session without a terminal
  reaches Allow only through the popup, and the popup says where it came
  from.

The check `desktop-u2f` reads the evaluated PAM files: sudo alone has the
line, right before pam_u2f, with these flags. `desktop-u2f-vm` runs sudo
with the line on a machine: the password still opens it, a wrong one does
not, and without a terminal it fails as before.

The bench, `ravnix-tap-ask-bench`, decides `--dry-run` on `bench/root`. That
system has a mapping, a key, a session's worth of processes and no Wayland
socket, so the run reads every file a real one reads and stops before the
popup.

## Findings not fixed

- **The popup is consent, not a wall.** A program that runs as the user on
  the laptop can answer the popup itself, and so can a command over the
  laptop-access link, which runs any command as the user. It can type into
  the popup, since Sway lets any client type through its virtual-keyboard
  protocol, as wtype does. It can start sudo through Sway's IPC
  (`swaymsg exec`) or the user's systemd, so that it looks like a program
  without a terminal on the laptop. It can even make a terminal with
  `script`. What it cannot do is touch the key. Against a mistaken touch the
  popup holds: it names what the touch is for, and it is on the screen before
  the key blinks. Against a link that is already hostile it does not hold.
  What would close that is a forced command for the laptop-access key, so
  that the link runs only the commands it is for
  (`modules/glue/laptop-access.nix`).
- **Any FIDO key brings the popup**, not only the one the mapping names:
  telling them apart takes an assertion against the key, which is pam_u2f's
  work. After Allow, a key that is not enrolled fails at once, and the
  password asks.
- **An open fuzzel blocks the popup.** fuzzel runs once per display (its lock
  file in `XDG_RUNTIME_DIR`), so a sudo while the launcher or another menu is
  open gets no popup and no tap, and sudo asks for the password.
- **Nothing logs the decision.** The PAM line is `quiet_log`, so that a sudo
  without a key leaves no "failed: exit code 1" in the journal, and the tool
  itself writes no log line.
- **With two sessions, the lowest socket wins.** The tool asks on the lowest
  `wayland-N` of the user. One Sway per user is what ravnix runs.
