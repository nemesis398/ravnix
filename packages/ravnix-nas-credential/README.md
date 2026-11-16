# ravnix-nas-credential

The root helper behind the NAS mounts of `modules/desktop/nas.nix`: it reads
an SMB account's password from the login's vault, with rbw run as the login
through `setpriv`, and writes the root-only credentials file that mount.cifs
reads. The script's header says how. `tests/bin/ravnix-nas-credential.nix`
runs its shell test, and `tests/desktop/nas-vm.nix` runs it as root against
a real Samba server.

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
