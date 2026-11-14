# ravnix-keyring-unlock

Unlocks the login keyring of the gnome-keyring daemon that is already
running, with the password from a systemd credential, when the keyring is
locked. It runs once per graphical session, as the user service
`ravnix-keyring-unlock` (`modules/desktop/keyring.nix`), for
`ravnix.desktop.keyring.autoUnlock`. Its one-time setup is a command of
the same tool, `ravnix-keyring-unlock setup` (below).

The reason is the YubiKey tap at the greeter: it gives PAM no password, so
pam_gnome_keyring starts the daemon with the login keyring locked, and Helium,
which keeps its cookie key ("Chromium Safe Storage") there, asks for the
keyring's password at every start. The keyring stays encrypted. A keyring
without a password was the other way, and is not one: gnome-keyring 50
stores such a keyring as plain text that it cannot read back when a secret
has a line break, and then loses every item.

```sh
ravnix-keyring-unlock [--credential FILE] [--bus ADDRESS]
ravnix-keyring-unlock setup [--item NAME] [--bus ADDRESS]
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
it are overwritten with zeros when they are no longer needed. Before it reads
the credential, the tool makes itself undumpable (`PR_SET_DUMPABLE` 0): a
crash writes no core dump with the password in it, and no other process of
the user can ptrace it or read its `/proc/PID/mem`. The unit also sets
`LimitCORE=0`. It exits 1 if the kernel refuses.

## The setup

`ravnix-keyring-unlock setup`, run once in a terminal of the graphical
session, gives the login keyring a password of its own and stores it for the
unlock. Nothing is copied or pasted:

1. It checks the credential's path,
   `~/.config/credstore.encrypted/ravnix-keyring-login`: a symbolic link
   at the file or its directory, a directory where the file should be, a
   file where the directory should be, or a directory of another user stops
   it before anything runs.
2. It reads the new password from the Bitwarden item that
   `ravnix.desktop.keyring.autoUnlock.rbwItem` names (the module's wrapper
   puts it in `RAVNIX_KEYRING_RBW_ITEM`; `--item NAME` wins), with
   `rbw get -- NAME`, on rbw's standard output. First it asks `rbw unlocked`:
   on a locked vault, `rbw get` would make the agent ask for the master
   password, so the setup stops instead and says to run `rbw unlock` (or
   `ai-unlock`). The password is rbw's line without its newline. It must not
   be empty, hold a NUL byte, be longer than 8192 bytes, or end in a line
   break, which the unlock would take off the credential. The item is made
   beforehand with Bitwarden's generator, in bwm or the web vault: `rbw add`
   gets HTTP 422 from Vaultwarden.
   Then it refuses the password when it is your login password, which the
   keyring must not get: any program that runs as you could decrypt the
   credential and learn the password sudo asks for. Without this, an item
   that holds the login password would pass step 3 (PAM gave the keyring
   that password) and be stored without a question. The check is pam_unix's
   own helper, NixOS's setuid wrapper `/run/wrappers/bin/unix_chkpwd`, as
   pam_unix runs it for a caller who checks their own password (Linux-PAM
   1.7, `modules/pam_unix/unix_chkpwd.c`): the arguments are your user name
   (from `/etc/passwd`) and `nonull`, the standard input a pipe with the
   password and a NUL, and it exits 0 for the login password and 7 for any
   other. The setup also stops when it cannot check: no helper that is
   setuid and root's (a copy without the bit cannot read the shadow file
   and answers 7 to everything), no user name, or another status.
3. It connects to the session bus and asks the daemon whether the keyring
   already has that password, with gnome-keyring's
   `ChangeWithMasterPassword` from the password to itself. That call checks
   the old password in both states of the collection and changes nothing
   when it is wrong. `UnlockWithMasterPassword` is no such check: on an
   unlocked collection gnome-keyring 50 answers every password with success
   (the tests' stand-in does the same, and the check
   `desktop-keyring-autounlock` shows it on the real daemon).
4. When the keyring does not have it, it asks once for the current
   password, with `systemd-ask-password -n` on the terminal (masked; it gives
   up after 300 s), and changes it with `ChangeWithMasterPassword`, in a
   `plain` session. A wrong password is `org.gnome.keyring.Error.Denied`,
   which changes nothing; the setup says so and stops. So does a typed
   password that is the item's own. With no login keyring at all it stops:
   it never makes one. When the change gets no answer (a timeout, a bus or
   daemon that went away), the setup cannot know whether it happened and
   says so; the next run finds out in step 3. When the prompt fails and the
   standard input is not a terminal, the line says to run the setup in one.
   A blank current password is refused: a keyring without a password is the
   plain-text format that gnome-keyring 50 cannot read back once a secret
   holds a line break (the option's description says why ravnix does not use
   it). Such a keyring needs a password first, through the prompt
   gnome-keyring shows when an application asks for a secret, or by moving
   `~/.local/share/keyrings/login.keyring` aside and logging in once with
   your password, which makes a new one with the login password (the items
   of the old file do not come along); then run the setup.
5. It encrypts the password with
   `systemd-creds --user encrypt --name=ravnix-keyring-login - -`, the
   password on standard input and the credential on standard output, and
   writes the file itself: the directory is made or made 0700, the file is
   written as a temporary file beside it (0600, `O_EXCL`, `O_NOFOLLOW`),
   synced, and renamed over the old one, so the unlock finds the old file or
   the new one and never a part.
6. It decrypts the file again (`systemd-creds --user decrypt`), checks that
   it holds the item's password and that the keyring takes it (the change to
   itself again), and unlocks the keyring with it when it is locked. Only
   then does it report success.

The keyring comes first and the credential second, and step 3 makes a run
that died between them repairable: the keyring has the item's password
then, so the next run asks for nothing and only writes the credential again.
A failure after step 4 says so. Every refusal before step 4 changes nothing,
and its line ends with "nothing changed".

The passwords travel through pipes only: never in an argument or the
environment of a program, never in a line. Every buffer that held one is
overwritten with zeros, the `ChangeWithMasterPassword` message included.
The setup makes itself undumpable as the unlock does, and sets its core
limit to 0, which `LimitCORE=0` does for the service; rbw,
systemd-ask-password and systemd-creds inherit the limit. It runs the three
programs from `PATH`, from absolute directories only.

| Exit | Line |
| --- | --- |
| 0 | the keyring's password is now the item's, and the credential holds it |
| 0 | the keyring had the item's password already; the credential holds it again |
| 1 | the reason, and whether anything changed |
| 2 | bad usage |

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

The setup's tests (`tests/setup_test.odin`) run it against the same
stand-in bus, which also answers `ChangeWithMasterPassword` as gnome-keyring
50 does (it checks the old password whether the collection is locked or not,
while an unlock of an unlocked collection takes any), and against stand-ins
for rbw, systemd-ask-password, systemd-creds and unix_chkpwd
(`tests/testdata/fake`), which record their arguments, their environment and
their input. They cover an item that holds the login password (with the
keyring at the login password and with a password of its own), a login
password that cannot be checked, a change that got no answer, a prompt
without a terminal, a locked and an unlocked keyring, a run after one that died between the
keyring and the credential, a wrong and the same current password, nobody
typing, a locked vault, no rbw, an item that is empty, only a newline, holds
a NUL, ends in a line break, is one byte too long or 200 KiB, the longest
password there is, a symbolic link at the file or the directory, a
directory or a file in the wrong place, systemd-creds failing to encrypt
or decrypt or decrypting to something else, no login keyring, another error
of the daemon, a bus that hangs up, a directory that is not private, four
writers of the credential at once, and the lookup on `PATH`. Every one
checks that no password reached an argument, an environment, a line or the
file in the clear.

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
- Every setup with an item that is not the login password writes one
  failed password check to the journal, from unix_chkpwd: "password check
  failed for user (NAME)", and an audit record where Linux-PAM has audit
  support. The helper neither waits after it nor counts it; pam_faillock
  counts only failures of a PAM stack, and the VM test shows the login
  password still checks right after one.
- unix_chkpwd reads at most 512 bytes and a NUL (`PAM_MAX_RESP_SIZE`), so
  an item longer than 512 bytes counts as not the login password. No login
  password can be longer, since PAM takes no longer answer.
- `RAVNIX_KEYRING_UNIX_CHKPWD` names another unix_chkpwd, which the setup
  then takes without the setuid check. It is there for the check that runs
  the setup in the build sandbox, which has no setuid wrapper. Whoever can
  set it runs as you and could write the credential by hand anyway.
- The setup writes the credential to `~/.config/credstore.encrypted/`,
  whatever `XDG_CONFIG_HOME` the terminal has. The user manager looks in its
  own `$XDG_CONFIG_HOME/credstore.encrypted/`, which is `~/.config` unless
  something gives the user manager another one.
- A setup killed between the temporary file and the rename leaves
  `.ravnix-keyring-login.PID.TID.tmp` in the directory, which holds only
  the encrypted credential. The unlock does not read it, and nothing
  removes it.
- systemd-ask-password masks what is typed. When the input comes faster
  than the prompt, as from a pipe into `script`, the terminal can still echo
  it before systemd-ask-password turns echo off; the VM test types it that
  way and does not look at the terminal's output for that reason.
- The plain session is not closed: gnome-keyring drops a client's sessions
  when its connection closes, which is the next thing the tool does.
