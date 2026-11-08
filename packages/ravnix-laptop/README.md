# ravnix-laptop

`ravnix-laptop COMMAND [ARGUMENT...]` runs a command on huginn, the laptop,
from muninn, the server, over the NetBird mesh, and prints what it printed.
It is thin Bash glue over `ssh`, packaged with `writeShellApplication`, so
shellcheck ran over it at build time. `modules/glue/laptop-access.nix` builds
it with `ravnix.hosts.huginn.address`, `ravnix.user.username` and
`ravnix.laptopAccess` (`identityFile`, `hostKey`); the same module sets up the
laptop's end. Which end a host is comes from its `ravnix.shape`, which
`nixosModules.laptop` and `nixosModules.server` set; the glue refuses a host
with no shape (`modules/glue/shape.nix`), and this module does nothing for
one. Built with none of the values it says which to set and exits 78.

## What it promises

- **Each word is one word.** The words are quoted for the remote shell with
  `printf %q` and sent as a single argument behind `--`, so a space, a `;`, a
  `$(...)`, a quote or a leading dash in an argument stays an argument, and
  nothing in them can be read as an option of the local ssh.
- **The exit status is the command's.** Standard input goes to the command,
  its standard output and error come back apart.
- **A laptop that is asleep gives up in seconds.** `ConnectTimeout=3` bounds a
  laptop that does not answer, `ServerAliveInterval=2` with
  `ServerAliveCountMax=1` one that stops answering in the middle of a command
  (four seconds of silence). A laptop that goes silent in the handshake in
  between is bounded as well: in the banner exchange by `ConnectTimeout`
  (3 s), in the key exchange by ssh's packet timeout, which follows
  `ServerAliveInterval` (2 s, "Connection to ... timed out"); both are tested
  against a listener that accepts and says nothing. Each ends with
  `ravnix-laptop: huginn is offline or asleep` and exit **75** (EX_TEMPFAIL):
  try again later. So does an sshd that is not running (connection refused),
  and a connection that is reset in the middle of a command (below, under
  "A session that ends in the middle of a command").
- **A laptop that refuses is not asleep.** A refused key, a host key that is
  not the laptop's and the like exit **255** with `ravnix-laptop: ssh to
  huginn failed:` and what ssh said. Exit **64** is a wrong call, **78** a
  command that is not configured (or has no readable identity file), and
  **70** (EX_SOFTWARE) a failure on this machine before ssh could start (no
  temporary file for ssh's messages), so that it is never taken for the remote
  command's own exit 1.
- **A command that exits 255 is told from an ssh that failed.** ssh writes its
  own log to a file of its own (`-E`), an unlinked temporary file read back
  through its descriptor, so nothing is left behind however the command ends,
  and the command's own standard error is not mixed into it. A 255 with
  nothing in that file is the command's, or a session that ended, as follows.
- **A session that ends in the middle of a command is told by what is left.**
  ssh does not write the line for that to `-E`, but to its own standard
  error, so it is in the command's stderr, after what the command wrote, and
  ends with CR LF. What the wrapper adds depends on the one thing it reads,
  ssh's log (never the command's stderr, which can say anything):
  - The laptop closes the connection (the session's own sshd process ends:
    it is killed, or the laptop shuts down cleanly): ssh says `Connection to
    ADDRESS closed by remote host.`, and its log is empty. Exit **255** with
    no word of the wrapper's, as for a command that exits 255. Stopping the
    sshd service does not do this: on NixOS its unit has `KillMode=process`,
    so the running sessions go on and only new connections are refused (75,
    as above).
  - The connection is reset: ssh says `Read from remote host ADDRESS:
    Connection reset by peer`, and its goodbye fails too, which is in the log
    (`client_loop: send disconnect: Broken pipe`). Exit **75** and `huginn is
    offline or asleep`, after ssh's line.
  - The laptop falls asleep or drops off the network: nothing arrives, so ssh
    has no line of that kind; four seconds later `Timeout, server ... not
    responding` is in the log, and the exit is **75**.

  Nothing is repeated in any of the three, and the command may have run in
  part or in full, so a caller that retries on 75 must be able to run its
  command twice. A silent 255 is either the command's own or a session
  closed under it; only the line of ssh's in the stderr tells them apart, and
  the wrapper does not read that stream. The VM test has all three with the
  real ssh and sshd: sshd's process for the session ended, the laptop's
  firewall answering with a reset, and a paused laptop.
- **The key is its own.** `-F /dev/null` ignores `~/.ssh/config` and
  `/etc/ssh/ssh_config`, `IdentitiesOnly` with `IdentityAgent=none` leaves out
  every agent, so neither the YubiKey's agent nor rbw's (the one
  `SSH_AUTH_SOCK` names, which serves the vault's SSH keys) is ever asked.
  Nothing is asked of a person either (`BatchMode=yes`): the key has no
  passphrase.
- **The laptop is the one it should be.** With `hostKey` set, the key is
  written into a known_hosts file of the store as `huginn KEY` and checked
  strictly (`HostKeyAlias=huginn`, so a new address changes nothing). Without
  it the first key is remembered in
  `$XDG_STATE_HOME/ravnix-laptop/known_hosts` (`~/.local/state/...`), never in
  the user's own known_hosts, and a different one is refused from then on.

## Tests

`tests/glue/laptop-access.nix` (the check `glue-laptop-access`) has three
parts, built one at a time with `.wrappers`, `.vm` and `.failures`:

- `tests/glue/helpers/ravnix-laptop.test.bash` runs the command against a
  stand-in for ssh (`fake-ssh.sh`), which can also run the remote command
  line in a local bash, as the remote shell would. It checks the options ssh
  gets; 29 words with every kind of quote and metacharacter; a 100 kB word;
  a command line beyond what exec takes; the exit statuses, the two output
  streams and standard input; every message of ssh for an unreachable laptop
  and for a refusing one, and that the one is never taken for the other; a
  255 from the command, and a session that ends in the middle of one (the
  line is ssh's own, on stderr, not in its log); usage errors; a command built with nothing, without
  an identity file, without a state directory, with a temporary directory that
  is not there, with an ssh that does not exist; no file left in `TMPDIR`, also after a TERM; sixteen runs at once.
- the module, evaluated: see `modules/glue/laptop-access.nix`.
- two VMs with a real sshd and a real ssh, in which an interface named `wt0`
  stands in for NetBird and a second one for the laptop's LAN: the same
  words, status and streams through the real thing, a pinned host key that is
  wrong, a remembered one that changed, the key refused from another address,
  a key in the account's own `~/.ssh/authorized_keys` and the key under another
  account refused, and huginn stopped, silent in the banner exchange and in the
  key exchange, its session closed, reset and ended by a shutdown in the
  middle of a command, paused in the middle of a command, paused, and shut
  down.

## What the laptop's end refuses, and cannot

`modules/glue/laptop-access.nix` keeps the ssh port shut on every interface but
NetBird's by the firewall, and refuses at build time every declarative way
NixOS has to open it elsewhere: the global port lists and ranges; the same
lists of any other `networking.firewall.interfaces` entry, wildcard names
(`"wl+"`, `"+"`) included; those of the entry `default`, which nixpkgs applies
to every interface in place of the global lists; and `trustedInterfaces` other
than NetBird's and loopback. A host that trusts another interface (a bridge of
Podman or libvirt, say) is refused too: whatever is trusted accepts the ssh
port. sshd takes only the key the module writes (`authorizedKeysInHomedir` is
off) and only the one account (`AllowUsers`).

What no assertion can check, because it is free-form text, and which can open
the port on the LAN without a word: `networking.firewall.extraCommands`
(iptables) and `extraInputRules` (nftables), a ruleset of nftables' own
(`networking.nftables.ruleset` or `tables`), and anything that runs `iptables`
or `nft` by itself. A host that has any of them must check its
ruleset by hand: `nft list ruleset` (or `iptables -S`) shows where port 22 is
accepted.

## Findings that are not fixed

- `ConnectTimeout` does not cover resolving a name. The NetBird address is an
  address, and nothing here resolves it; if `ravnix.hosts.huginn.address` is a
  DNS name and the resolver is dead, the five seconds are not kept.
- Which failure it is, is read from ssh's English messages. A wording that
  OpenSSH changes, or a message not on the lists in the script, is reported as
  `ssh to huginn failed` with ssh's text and exit 255, never as 75; the
  failing side is the safe one, since nothing then retries by mistake.
- Four seconds of silence end a command, whether the laptop slept or the Wi-Fi
  dropped for four seconds: exit 75, and the command is not run again. Nothing
  here knows whether it had already done its work on the laptop.
- The remote shell must be bash (the command line is quoted for it, with
  `$'...'` where a word holds a control character). It is, for the account of
  both hosts.
- A command that needs the laptop's graphical session (`wl-copy`, `swaymsg`)
  gets the environment sshd gives, which has no `WAYLAND_DISPLAY` or
  `SWAYSOCK`. The forwarding of such requests is `ravnix-link`'s.
- A key type that differs from the one the laptop offers, pinned in `hostKey`
  (an ECDSA key for a laptop that has only an ed25519 one), is not a mismatch
  to ssh but "no matching host key type", and is reported as an ssh failure.
- A TERM sent to `ravnix-laptop` alone ends the script and leaves its ssh
  running until the command ends; a TERM to the process group ends both.
- The limit of 120000 bytes for the whole command line is below the 128 KiB
  that Linux takes for one argument, with room for `bash -c`; a word beyond it
  is refused, not split.
- OpenSSH 9.8 and later drop a source that fails to log in a few times
  (`PerSourcePenalties`, on by default) for some seconds to minutes. ssh then
  says "Connection closed by remote host" or "reset by peer", which is told
  from a laptop that sleeps by nothing, so a key that is not on the laptop yet,
  or a `from=` that does not match, shows first as a refusal (exit 255) and
  then, for as long as the penalty lasts, as "offline or asleep" (exit 75). It
  passes by itself; a caller that retries on 75 must not hide the 255 that
  came before. The sshd log of the laptop says which.
- NetBird's own access policy has to allow the server to reach the laptop on
  tcp/22; the VM test has a plain interface in place of NetBird.
- Trust on first use (`hostKey` null) remembers whatever answers first at the
  laptop's address. A run before the laptop is installed and enrolled, against
  another machine that has an sshd there, remembers that machine's key under
  the alias `huginn`; after a reinstall of the laptop the remembered key has to
  be removed from `$XDG_STATE_HOME/ravnix-laptop/known_hosts` by hand (ssh's
  message names the file). Setting `hostKey` avoids both; the server's build
  warns while it is null.
- `from=` needs the server's NetBird address as an IP address; the laptop's
  build refuses a name.
