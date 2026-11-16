# ravnix-nas-credential

The root helper behind the NAS mounts of `modules/desktop/nas.nix`: it reads
an SMB account's password from the login's vault, with rbw run as the login
through `setpriv`, and writes the root-only credentials file that mount.cifs
reads. The script's header says how. `tests/bin/ravnix-nas-credential.nix`
runs its shell test, `tests/desktop/nas-vm.nix` runs it as root against a
real Samba server, and `tests/desktop/nas-rbw-vm.nix` runs it with the real
rbw against a real rbw-agent.

## Why Bash

AGENTS.md's rule 4 has new tools written in Odin. This one is Bash by the
maintainer's explicit exception, made on 2026-11-16 ("Keep Bash, it's
glue"). It runs as root, as do the Odin tools that drop to the user with
setpriv (`tools/ravnix-tap-ask`, `tools/claude-roll`). The exception holds
because:

- it is small: one read from rbw, four checks of what came back, and one
  write and rename;
- every branch is covered by the shell test, which also traces every
  program it starts for the secret, and the real path by the VM test with
  the real rbw;
- it is root only until the drop: as root it runs `id`, `setpriv`, `head`
  and the write of the file, and `timeout` and rbw run as the login, so the
  unit needs no capability but CAP_SETUID and CAP_SETGID.

## Limits

- Each rbw call has 15 seconds (`rbwTimeout` in `default.nix`), kept by a
  `timeout` that runs as the login after the drop, and the
  module's unit gives the run twice that and 15 seconds more, so a slow
  vault ends in the fallback to the kept file and not in a kill.
- Of rbw's answer it reads 1100 bytes at most, past the 512 that mount.cifs
  takes, and rbw is stopped there.

What it does not cover:

- A password that ends in a newline loses it: rbw prints the password with a
  newline after it, and the shell's command substitution takes off every
  newline at the end, so the two cannot be told apart. A newline anywhere
  else is refused, since a credentials file holds one line per value.
- rbw's own error message is not passed on: it never holds the password, but
  the script says in its own words what failed (locked, no such item), and
  `rbw get` by hand shows the rest.
- It trusts the login's rbw agent. Any process of the login can answer in its
  place and hand the mounts another password. That reaches only the mounts,
  whose files the login owns anyway; the file is written with printf and
  checked to be one line, so the answer cannot add a line to it.
- A run killed with SIGKILL leaves its temporary file, root's and mode 600,
  in the root-only directory; the next run removes it once it is five
  minutes old.
- No `domain=` line: the accounts are of a standalone NAS.
