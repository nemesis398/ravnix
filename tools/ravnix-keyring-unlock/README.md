# ravnix-keyring-unlock

Unlocks the login keyring of the gnome-keyring daemon that is already
running, with the password from a systemd credential, when the keyring is
locked. It runs once per graphical session, as the user service
`ravnix-keyring-unlock` (`modules/desktop/keyring.nix`), for
`ravnix.desktop.keyring.autoUnlock`, whose description has the one-time
setup.

The reason is the YubiKey tap at the greeter: it gives PAM no password, so
pam_gnome_keyring starts the daemon with the login keyring locked, and Helium,
which keeps its cookie key ("Chromium Safe Storage") there, asks for the
keyring's password at every start. The keyring stays encrypted. A keyring
without a password was the other way, and is not one: gnome-keyring 50
stores such a keyring as plain text that it cannot read back when a secret
has a line break, and then loses every item.

```sh
ravnix-keyring-unlock [--credential FILE] [--bus ADDRESS]
```

- `--credential FILE`: the password. The default is
  `$CREDENTIALS_DIRECTORY/ravnix-keyring-login`, where systemd puts the
  decrypted credential of `LoadCredentialEncrypted=ravnix-keyring-login`
  while the service runs. The password is the file's bytes without one
  trailing newline (`echo` adds one, `systemd-ask-password -n` does not). It
  must not be empty, hold a NUL byte, or be longer than 8192 bytes, the
  longest login password gnome-keyring takes.
- `--bus ADDRESS`: the session bus, a D-Bus address with a `unix:path=`
  entry. The default is `$DBUS_SESSION_BUS_ADDRESS`, or
  `unix:path=$XDG_RUNTIME_DIR/bus` without it. `unix:abstract=` and TCP
  are not supported; a user manager's bus is neither.

## What it does

1. It reads the credential. Without one it says so and stops, before it
   connects to anything.
2. It connects to the session bus, logs in with `EXTERNAL` (its UID), and
   asks the Secret Service for the property `Locked` of
   `/org/freedesktop/secrets/collection/login`. That call may start the
   Secret Service through D-Bus activation, and it should: after a login,
   the daemon that pam_gnome_keyring started (`--daemonize --login`) waits
   without its secrets component until a client starts
   `gnome-keyring-daemon --start`, which hands the work to it. So there is
   still one daemon, PAM's, as a check of the bus shows.
3. When the collection is not locked (a password login, which PAM
   unlocked), or there is no login keyring, it says so and stops. The
   password is not sent.
4. It opens a Secret Service session with the `plain` algorithm and calls
   `org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface.UnlockWithMasterPassword`
   on the login collection. This is gnome-keyring's own call for unlocking
   with a known password. It never prompts, it answers a wrong password with
   `org.gnome.keyring.Error.Denied`, it changes nothing then, and it never
   creates a keyring. The daemon's control socket, which pam_gnome_keyring
   uses, would create a login keyring with the given password when there is
   none, and marks a failed attempt for a later prompt, so the tool does not
   use it. No `gnome-keyring-daemon` command line talks to a running daemon:
   `--unlock` starts a second daemon.
5. It asks for `Locked` again and reports the keyring unlocked only when it
   is.

It speaks D-Bus itself (`dbus.odin`): the session bus's socket, the login
exchange, and the messages of the wire format, little- and big-endian. It
makes five calls (`Hello`, `Get`, `OpenSession`, the unlock, `Get`) and
skips every other message that arrives before a reply. There is no D-Bus
library in Odin's core, and `busctl` or `gdbus` cannot do it from a shell:
a Secret Service session belongs to the connection that opened it, and each
of their calls is a connection of its own. The password would also be on
their command line.

Every read and write waits 10 s at the most, all of it together. The
password, the credential's buffer and every buffer that held a message with
it are overwritten with zeros when they are no longer needed.

## Output and exit status

One line on standard error. When standard error is the journal (it is the
stream that `JOURNAL_STREAM` names), the line starts with the journal's
priority prefix, `<6>` to `<3>`.

| Exit | Line | Priority |
| --- | --- | --- |
| 0 | `unlocked the login keyring` | info |
| 0 | the login keyring is already unlocked (a password login) | info |
| 0 | no credential `ravnix-keyring-login` (where it looked) | notice |
| 0 | there is no login keyring yet | notice |
| 0 | the credential's password does not unlock the login keyring: redo the setup | warning |
| 1 | cannot unlock the login keyring: the reason | error |
| 2 | bad usage | |

A wrong password exits 0 because it leaves everything as the login left it,
which is what the service promises; the warning says what to do. A failure
(no bus, a bus that does not answer, a Secret Service that is not
gnome-keyring, a broken credential, a keyring that stays locked after the
daemon took the password) fails the unit, so `systemctl --user --failed`
shows it.

## Tests

`tests/` (the check `ravnix-keyring-unlock-tests`) runs against a stand-in
bus in a thread of the test, which speaks the wire format with the tool's
own encoder and decoder and answers as each test says: locked, unlocked,
no keyring, no Secret Service, a refused login, a wrong password, another
error, a keyring that stays locked, signals and replies to other calls in
between, big-endian replies, a bus that does not answer or hangs up, a
reply of the wrong type, a message that announces 64 MiB. It checks what
reached the daemon (the password without its newline, the `plain` session,
the collection, the session path, the destination, auto start allowed) and
that no line ever holds the password. The codec has its own tests: the
bytes of a `Hello` as the specification lays them out, round trips in both
byte orders, two messages in one buffer, and every malformed header and
truncation it must refuse.

Because the stand-in uses the tool's codec, a mistake that both make alike
would pass there. The check `desktop-keyring-autounlock` therefore also
runs the tool against the real `dbus-daemon` and `gnome-keyring-daemon` 50
in the build sandbox, started as pam_gnome_keyring starts it after a tap and
after a password, and in a VM with greetd, the systemd credential and the
login layout.

The bench (`ravnix-keyring-unlock-bench`) counts the run of every login
without a credential: the tool finds no file, says so and exits, without a
bus. A run that unlocks needs a bus and a daemon, which the bench has not.

## Findings

- Nothing checks that the owner of `org.freedesktop.secrets` is
  gnome-keyring before the password goes to it. On a session bus only
  processes of the same user can own a name, and such a process can also
  decrypt the credential itself (`systemd-creds --user decrypt`), so the
  check would not protect anything. That is also why the option's
  description advises a keyring password that is not the login password.
- Without a credential, the journal of the service holds two lines: the
  tool's, and before it systemd's own `Couldn't read inherited credential
  'ravnix-keyring-login', skipping`, which the service manager writes before
  it starts the tool. A `ConditionPathExists=` on the credstore file would
  replace both with systemd's "skipped" line and lose the tool's pointer to
  the setup, so the unit has none.
- When systemd cannot decrypt the credential (the TPM2 was cleared, the
  machine ID or the host key changed), the unit fails before the tool runs,
  with systemd's message, and the keyring stays locked; the setup command
  makes a new credential.
- The plain session is not closed: gnome-keyring drops a client's sessions
  when its connection closes, which is the next thing the tool does.
