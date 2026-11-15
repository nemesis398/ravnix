# ravnix-laptop-gate

The forced command of the server's key on the laptop. muninn reaches huginn
with a key of its own (`ravnix-laptop`, `modules/glue/laptop-access.nix`),
and huginn's `authorized_keys` line gives that key
`command="…/ravnix-laptop-gate",restrict,from="…"`. sshd then runs the gate
instead of what the server asked for, and leaves the server's request in
`SSH_ORIGINAL_COMMAND`. The gate answers a fixed list of read-only calls and
refuses everything else. A shell, `sudo`, `pkexec`, `run0` and
`nixos-rebuild` are never reachable over the link, so a hostile session on
the server cannot get to the security key's tap, whatever the tap popup or
the polkit rule would make of it.

## The calls

Each call is its name alone, byte for byte, with no argument. No call
needs an argument.

| Call | Answers | How |
| --- | --- | --- |
| `ping` | `huginn is up` | itself |
| `facts` | the `machine-facts` block | runs `machine-facts` by its store path, with `MACHINE_FACTS_NO_SUDO=1` |
| `battery` | status, charge (%), `power_now` (uW), `energy_now`, `energy_full`, `energy_full_design` (uWh), `cycle_count` of each battery | reads `/sys/class/power_supply` itself |
| `charge-mode` | the active mode of `charge_types` (the one in brackets) | reads it itself. It never runs `charge-mode`, whose other modes write. |
| `power` | the NVIDIA GPU's `power/runtime_status` and `power_state`, and `energy_uj` of each RAPL zone | reads sysfs itself, never the GPU's configuration space, which would wake it |

The sysfs answers are one line per reading, `WHAT FIELD VALUE`. VALUE is
the reading, with its unit, or the reason there is none: `absent`, `needs
root` (the file is root's alone; the gate never asks for more rights) or
`unreadable` (empty, not a number where one belongs, longer than 64 bytes,
or holding a control character). A battery means one of the laptop's own:
type `Battery`, but not scope `Device`, which is a mouse's or a headset's
battery, and whose name carries the device's Bluetooth address. With
nothing to report, the answer says so: `no battery`, `no battery with
charge_types`, `dGPU none`, `RAPL none`.

`facts` runs `machine-facts` with an environment of its own and nothing
from the session:

- `PATH=/run/current-system/sw/bin`, without `/run/wrappers/bin`, where the
  setuid `sudo` and `pkexec` are. The copies of both on this PATH do
  nothing without their setuid bit.
- `HOME`, `USER` and `LOGNAME`.
- `MACHINE_FACTS_NO_SUDO=1`, which keeps the boot row from trying `sudo -n`
  (`packages/machine-facts/README.md`).

The PATH is not what keeps `facts` from root. `run0` and `systemd-run`
need no setuid bit and are on it, and with
`security.run0.sudo-shim.enable` the `sudo` there is `run0` itself. What
holds:

- `machine-facts`' own, fixed content calls none of them, and
  `MACHINE_FACTS_NO_SUDO` covers its one `sudo -n`;
- `sudo` and `pkexec` need the setuid wrappers;
- polkit's rule (`modules/desktop/u2f.nix`) refuses a subject outside a
  local session, which an ssh session is.

An edit of `machine-facts` that runs any of them is an edit of the gate.
The gate starts `machine-facts` through `execve`, with no shell of its
own in between. The server gets only the plain print mode, never
`--write`, `--check` or `--diff`.

## Before the gate runs

sshd does not start the gate itself. It runs `command=` as `$SHELL -c
'<gate>'`, and the account's shell is bash. Two things reach that bash
before the gate does:

- **The environment.** A non-interactive bash runs the file `$BASH_ENV`
  names, command substitutions included, and the dynamic loader reads
  `LD_PRELOAD`. A client could set either if sshd let it, through
  `AcceptEnv`, or through `PermitUserEnvironment` with `~/.ssh/environment`
  or a key's `environment=`. So `modules/glue/laptop-access.nix` refuses a
  laptop whose sshd lets a client set any variable, or that has a
  `ForceCommand`, a `Match` or an `Include` in `services.openssh.settings`
  or `extraConfig`, which could change either. nixpkgs' defaults set none
  of them, and the VM test reads `sshd -T` for it.
- **The shell's startup files.** bash on NixOS is built with
  `SSH_SOURCE_BASHRC`. Started by sshd, it reads `/etc/bashrc` and
  `~/.bashrc` before the gate, on every call, a refused one included.
  What they run comes from the laptop's own configuration
  (home-manager's session variables, `modules/common/bash.nix`), not from
  the server, which sends nothing but `SSH_ORIGINAL_COMMAND`. Still,
  whatever they run, runs as the user on every call over the link.

## The refusal

Every other command exits **77** (sysexits' EX_NOPERM). The gate writes
`ravnix-laptop-gate: refused: REASON. huginn answers only: ping, facts,
battery, charge-mode, power` to stderr, which sshd hands to the server.
It sends **exactly one line** to the journal through journald's syslog
socket (`/dev/log`, authpriv.warning, `journalctl -t ravnix-laptop-gate`).
That line does not go to stderr, because the laptop's journal never sees
stderr. The line reads

    refused "sudo -n true" from 192.0.2.20: not an allowed call

The address is the first field of `SSH_CONNECTION`, and only when it looks
like an address. The gate checks in this order:

1. **Empty.** The server asked for a shell, or for nothing.
2. **Too long.** The bound is **64 bytes**. The longest call,
   `charge-mode`, has 11, so nothing allowed is near the bound, and a
   refused command of up to 64 bytes, each byte escaped to at most four,
   still fits one line. A longer one is logged by its size alone (`a
   command of 120000 bytes`), never with its text.
3. **A control character.** Any byte below 0x20 (NUL, newline, tab,
   escape) or DEL.
4. **A shell metacharacter.** Any of ``|&;<>()$`\"'*?[]#~!{}``.
   `ravnix-laptop` quotes a space in a word with a backslash, so
   `ravnix-laptop 'a b'` arrives as `a\ b` and is refused here.
5. **Arguments.** A call followed by anything, `ping extra` or `facts
   --write`.
6. **Not an allowed call.** Everything else: `sh -c id`, `sudo -n true`,
   `nixos-rebuild switch`, `PING`. A subsystem such as `sftp` is refused as
   well. sshd runs the forced command for it, with the program the
   subsystem is configured with in `SSH_ORIGINAL_COMMAND`. On NixOS that is
   sftp-server's store path, longer than the bound. sshd gives the client
   no stderr for a subsystem, so only the exit status and the journal line
   show the refusal.

The log quotes a refused command and escapes it: a backslash and a quote
take a backslash, and every byte outside printable ASCII becomes `\xHH`.
So no line can carry a second line, a terminal escape or raw UTF-8.

Forwarding is not the gate's job. The key keeps `restrict` whole, so sshd
refuses every port and socket forward, every agent forward, X11 and a
terminal, before the gate runs. No call needs one.

## Its own arguments

`--root DIR` reads sysfs and `/dev/log` under DIR, and `--command TEXT`
replaces `SSH_ORIGINAL_COMMAND`. Both exist for the tests and the bench.
On the laptop the arguments come from the key's `command=`, which names
none of them. The server cannot add one: everything it sends is
`SSH_ORIGINAL_COMMAND`.

Exit status: 0 answered; 77 refused; 70 `machine-facts` could not be
started (the message names the program and the errno); 64 bad usage.

## Tests

`ravnix-laptop-gate-tests` (`tests/`, 28 tests):

- Every call is let through, and nothing else is: shells, sudo, pkexec,
  run0, a rebuild, subsystem names, other cases and near misses, UTF-8,
  and a call with arguments.
- Each metacharacter is refused alone, after a call and before one, as
  are the usual injections.
- Control characters (NUL, newline, CR, tab, ESC, DEL) are refused.
- An empty command is refused.
- The bound is tested at 64 and 65 bytes; length wins over content; 128 KiB
  is tested too.
- The exact log lines, and that no line is longer than 400 bytes or holds
  a byte outside printable ASCII, also for 120 kB of newlines and escapes.
- The client address, and what is no address.
- `facts` gets the exact environment: no `/run/wrappers`, no `SSH_*`
  variable, no empty `HOME`.
- A refusal sends exactly one datagram to a real `/dev/log` socket in the
  fixture; an answer sends none.
- A refusal still holds with no journal, and with a `/dev/log` that is a
  plain file. With a journal whose queue is full, it returns at once.
- A program that is not there is not started (ENOENT, exit 70).
- The gate's own arguments are parsed as described above.
- Eight threads answer the same at once.
- The sysfs readings, against a fixture laptop: two batteries, AC, USB and
  a device's battery; malformed, oversized, empty, negative and root-only
  readings; `charge_types` with every bracket shape; a dGPU beside an AMD
  iGPU and its audio function; RAPL zones, one of them root's alone.

`ravnix-laptop-gate-bench` answers `battery` from `bench/root`, a laptop's
supplies.

The two-VM test `glue-laptop-access` (`tests/glue/laptop-access.nix`) runs
the gate as sshd's forced command. It covers:

- each call end to end from `ravnix-laptop`;
- `sh -c id`, `sudo -n true` and the rest, each refused with its line in
  huginn's journal, and no `sudo` in that journal;
- the shell metacharacters and a 50 kB word;
- an empty command and an sftp subsystem;
- a port forward, a socket forward and a `-W` to huginn, all refused.

## Findings not fixed

- **RAPL is root's on NixOS.** Since the Platypus fix (CVE-2020-8694) the
  kernel makes `energy_uj` mode 0400, so on huginn `power` says `needs
  root` for each zone and never escalates. The Fedora laptop had the files
  world-readable (seen 2026-11-15), so the readings differ between the two
  systems. A udev rule that opens them to the user would make them
  readable. That is a choice for the hardware module, not for the gate.
- **The gate trusts `machine-facts`.** That script runs `sway -C`, `swaymsg
  -t get_outputs`, `nmcli`, `resolvectl` and more as the user, with fixed
  arguments and nothing from the server. A bug in one of them can still be
  reached from the server through `facts`.
- **What `facts` prints goes to the server.** That is the Wi-Fi profile
  name, the DNS servers, the first eight characters of the machine id, the
  disks and the boot entries that need no root.
- **The gate does not rate-limit.** A server that calls `facts` in a loop
  costs the laptop CPU, and floods the journal when it is refused in a
  loop. sshd's `MaxStartups` and journald's rate limit are the only
  brakes.
- **Without `/dev/log` there is no log line.** When journald is not
  running, or stalls with the socket's queue full, the refusal stands but
  nothing records it: the gate sends without waiting, so that a refusal
  never hangs the server's session.
- **An allowed call is not logged by the gate.** sshd's `Accepted
  publickey` line for the session is the record.
