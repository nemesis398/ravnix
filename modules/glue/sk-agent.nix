# The security key for git, used from the server: git and ssh on muninn sign
# in to the git hosts with the key handles of a dedicated agent on huginn,
# whose socket the main connection forwards. Every signature still takes a
# touch on the security key at the laptop, so the server can use the key
# only while someone is there to touch it. The values are ravnix.skAgent
# (modules/options/sk-agent.nix); which end a host is comes from
# ravnix.shape, and a host does nothing for an end it is not.
#
# The laptop end. sk-agent, a user unit from the start of the user's session,
# runs ssh-agent on $XDG_RUNTIME_DIR/sk-agent.sock (mode 600), a socket of its
# own: not SSH_AUTH_SOCK, which on both hosts is rbw's agent
# (modules/common/rbw.nix) and keeps the keys that need no touch (commit
# signing, the servers), and not any other. It refuses to load a PKCS#11 or
# FIDO library that a client names (-P none): the socket is reachable from the
# server, and the security key needs only ssh's own FIDO support.
# sk-agent-keys, bound to it, loads the handles of ravnix.skAgent.keys into it
# each time it starts, and only those: it empties the agent first, and loads a
# handle only if the public half of the file is the listed one. A handle that
# is missing, unreadable, has a passphrase (nobody is there to type it) or is
# another key is left out, and the unit fails naming it, while the agent keeps
# the others. A socket left behind by an agent that was killed is removed
# before the next one starts, since ssh-agent will not bind over it.
#
# The forward is not made here. The main connection (modules/glue/
# terminal.nix, Task 5.2) forwards ravnix.skAgent.socket as it forwards
# ravnix.link.socket, with absolute paths, as ssh needs them:
#
#   RemoteForward /run/user/<uid on muninn>/sk-agent.sock
#                 /run/user/<uid on huginn>/sk-agent.sock
#
# sshd never removes a forwarded socket when the connection ends, so the
# server's sshd replaces one that is in the way (StreamLocalBindUnlink),
# and the next connection can forward it again.
#
# The server end. For the hosts of ravnix.skAgent.hosts, the user's
# ~/.ssh/config begins with an Include of the configuration below, ahead of
# every block another module or the user adds there, since ssh takes the
# first value it finds for each option. Both of its blocks are `Match host`
# with the same list, which ssh compares without regard to case, as DNS
# does: a `Host` line would let GitHub.com past the second block while the
# first one caught it.
#
#   - IdentityAgent is the forwarded socket, at /run/user/%i (the path the
#     forward writes, also where XDG_RUNTIME_DIR is unset), so neither
#     SSH_AUTH_SOCK (rbw's agent) nor any other agent is asked;
#     IdentitiesOnly and an IdentityFile for each listed public half make
#     ssh offer those keys and no other the agent holds, and none of the
#     server's default key files (~/.ssh/id_*); only publickey
#     authentication is tried, so nothing asks for a password.
#   - A Match exec runs sk-agent-check before ssh connects, and only for
#     those hosts. While the laptop's agent is not there, it says why, naming
#     the laptop, and the Match sends ssh to a ProxyCommand that exits at
#     once, with ssh's own messages off: ssh fails within a few seconds,
#     before any connection, and git with it. A wrapper around ssh would
#     miss every caller that does not go through it (git with GIT_SSH unset
#     runs ssh from the PATH, and so do other tools); ssh_config is what
#     they all read. A test of the socket file alone (`test -S`) would pass
#     a socket that a dropped connection left behind, so the check asks the
#     agent for its keys, with a timeout of 3 s for a laptop that sleeps
#     behind a forward that is still up. It refuses, each with its own
#     message: no socket; a socket nobody answers on; no answer in time (a
#     laptop asleep or offline, or an agent busy with another signature:
#     ssh-agent answers one request at a time, and a security key's
#     signature holds it until the touch); an agent with no key, or a
#     locked one; a forward with no agent behind it (sk-agent not running);
#     an agent with none of the listed keys.
#
# What still gets past both blocks, since ssh matches the name it was given
# and no other:
#   - the name with a trailing dot (github.com.), an address of the host,
#     and an ssh alias whose HostName is a listed host (`Host gh` with
#     `HostName github.com`): list such a name or address in
#     ravnix.skAgent.hosts too, or do not write one;
#   - an IdentityFile from any later block that matches these hosts (a
#     `Host *` of the user's own): ssh adds every IdentityFile it finds, and
#     IdentitiesOnly lets it offer each one. No ravnix module sets one.
#   - what the command line overrides: -F, which leaves out ~/.ssh/config and
#     its Include; -o IdentityAgent= only together with -o IdentitiesOnly=no,
#     and with -o ProxyCommand=none while the laptop is away (alone it fails
#     closed: the second block's IdentitiesOnly yes and its security-key
#     IdentityFiles still apply, and the first block refuses first while the
#     laptop is away); GIT_SSH_COMMAND, which carries either of those.
#
# Except for the IdentityFile, each of these reaches the agent of
# SSH_AUTH_SOCK (or the one -o IdentityAgent= names), which on the server is
# rbw's: modules/common/rbw.nix puts it into the session variables, which
# ~/.bashrc reads in every bash shell of the user (modules/common/bash.nix),
# and into the user manager. That agent serves every SSH key item of the
# vault without a touch, so if the vault holds a key the git host accepts,
# such a command logs in without one while the vault is unlocked.
# modules/workbench/ssh-agent.nix says so for the server, and so does
# "The vault and the keys" in modules/workbench/README.md.
#
# Left as it is: the rest of ssh's configuration, and every other host. What
# a signature needs, a touch, is asked for by the key's light alone: the
# agent on the laptop has no terminal to print ssh's "Confirm user presence"
# line on, so git on the server waits quietly until the key is touched.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.skAgent;
  shape = config.ravnix.shape;
  openssh = config.programs.ssh.package;

  laptop = shape == "laptop" && cfg.keys != [ ];
  server = shape == "server" && cfg.hosts != [ ];

  # A public key as ssh-add -L and ssh-keygen -y print it, without the
  # comment: its type and its base64.
  bare = key: lib.concatStringsSep " " (lib.take 2 (lib.splitString " " key));
  listed = map (k: bare k.publicKey) cfg.keys;
  isSecurityKey = k: lib.hasPrefix "sk-" k.publicKey;

  load = pkgs.writeShellApplication {
    name = "sk-agent-load";
    runtimeInputs = [
      openssh
      pkgs.coreutils
    ];
    text = ''
      sock=$1
      export SSH_AUTH_SOCK=$sock
      # Nobody is there to type a passphrase: a handle that wants one fails.
      export SSH_ASKPASS_REQUIRE=never
      handles=(${lib.escapeShellArgs (map (k: k.handle) cfg.keys)})
      publics=(${lib.escapeShellArgs listed})

      say() { printf 'sk-agent-keys: %s\n' "$*" >&2; }

      # The agent's process is up; its socket may not be there yet. ssh-add
      # -l exits 2 while nothing answers, 1 for an empty agent.
      rc=2
      for _ in $(seq 100); do
        rc=0
        ssh-add -l >/dev/null 2>&1 || rc=$?
        [ "$rc" = 2 ] || break
        sleep 0.05
      done
      if [ "$rc" = 2 ]; then
        say "nothing answers at $sock"
        exit 1
      fi

      # The list and nothing else, also when this runs on an agent that has
      # been running: a key added by hand goes.
      if ! ssh-add -D >/dev/null 2>&1; then
        say "the agent at $sock does not let its keys go; it may be locked (ssh-add -X unlocks it)"
        exit 1
      fi

      failed=0
      for i in "''${!handles[@]}"; do
        handle=''${handles[i]}
        if [ ! -f "$handle" ] || [ ! -r "$handle" ]; then
          say "$handle is missing or unreadable, so its key is not loaded"
          failed=1
          continue
        fi
        if ! got=$(ssh-keygen -y -f "$handle" </dev/null 2>&1); then
          say "$handle cannot be read as a key without a passphrase (''${got//$'\n'/ }), so it is not loaded"
          failed=1
          continue
        fi
        got=$(printf '%s\n' "$got" | tail -n 1 | cut -d ' ' -f 1,2)
        if [ "$got" != "''${publics[i]}" ]; then
          say "$handle is not the key ravnix.skAgent.keys lists for it (its public half is $got), so it is not loaded"
          failed=1
          continue
        fi
        if ! ssh-add -q "$handle" </dev/null; then
          say "ssh-add did not load $handle"
          failed=1
        fi
      done
      exit "$failed"
    '';
  };

  check = pkgs.writeShellApplication {
    name = "sk-agent-check";
    runtimeInputs = [
      openssh
      pkgs.coreutils
    ];
    text = ''
      sock=$1
      host=$2
      listed=(${lib.escapeShellArgs listed})

      refuse() {
        printf 'sk-agent: ssh to %s needs the security key at the laptop, huginn, and %s\n' "$host" "$1" >&2
        exit 1
      }

      [ -e "$sock" ] ||
        refuse "huginn is not connected: there is no agent at $sock. Open the main terminal on huginn, then try again."

      # The keys go to standard output, ssh-add's complaints to standard
      # error; both are read, since exit 1 is both "no identities" and a
      # forward with no agent behind it ("error fetching identities").
      rc=0
      held=$(SSH_AUTH_SOCK=$sock timeout -k 1 3 ssh-add -L 2>&1) || rc=$?
      case $rc in
      0) ;;
      1)
        case $held in
        *"no identities"*) refuse "huginn's agent holds no key, or is locked. On huginn, systemctl --user status sk-agent-keys says why." ;;
        *) refuse "the forward is up, and no agent answers behind it: sk-agent is not running on huginn. On huginn, systemctl --user status sk-agent says why." ;;
        esac
        ;;
      124 | 137) refuse "huginn does not answer at $sock within 3 s: it is asleep or offline, or its agent is waiting for a touch for another signature." ;;
      *) refuse "huginn is not connected: nothing answers at $sock, the connection that forwarded it is gone. Open the main terminal on huginn, then try again." ;;
      esac

      while read -r type key _; do
        for want in "''${listed[@]}"; do
          [ "$type $key" != "$want" ] || exit 0
        done
      done <<<"$held"
      refuse "huginn's agent holds none of the keys of ravnix.skAgent.keys. On huginn, systemctl --user restart sk-agent loads them again."
    '';
  };

  socketOnServer = "/run/user/%i/${cfg.socket}";
  identityFiles = lib.imap0 (
    i: k: pkgs.writeText "sk-agent-key-${toString i}.pub" "${k.publicKey}\n"
  ) cfg.keys;
  sshConfig = pkgs.writeText "sk-agent-ssh-config" (
    lib.concatLines (
      [
        "# ravnix: the git hosts sign in with the security key at the laptop,"
        "# through its forwarded agent (modules/glue/sk-agent.nix)."
        ''Match host ${lib.concatStringsSep "," cfg.hosts} !exec "${lib.getExe check} ${socketOnServer} %h"''
        "  ProxyCommand ${pkgs.coreutils}/bin/false"
        "  LogLevel QUIET"
        "Match host ${lib.concatStringsSep "," cfg.hosts}"
        "  IdentityAgent ${socketOnServer}"
        "  IdentitiesOnly yes"
      ]
      ++ map (file: "  IdentityFile ${file}") identityFiles
      ++ [
        "  PreferredAuthentications publickey"
        "  PasswordAuthentication no"
        "  KbdInteractiveAuthentication no"
      ]
    )
  );
in
{
  config = lib.mkMerge [
    {
      warnings = lib.optionals (laptop || server) (
        lib.concatLists (
          lib.imap0 (
            i: k:
            lib.optional (!isSecurityKey k) "ravnix.skAgent.keys[${toString i}].publicKey is an ${lib.head (lib.splitString " " k.publicKey)} key, not a security key's: the server can sign in with it through the laptop's agent without a touch."
          ) cfg.keys
        )
      );
    }

    (lib.mkIf laptop {
      home-manager.sharedModules = [
        {
          systemd.user.services.sk-agent = {
            Unit = {
              Description = "ssh-agent for the security key's handles alone (ravnix.skAgent)";
              Wants = [ "sk-agent-keys.service" ];
            };
            Service = {
              Type = "simple";
              # One that was killed leaves its socket, and ssh-agent will not
              # bind over it.
              ExecStartPre = "${pkgs.coreutils}/bin/rm -f %t/${cfg.socket}";
              ExecStart = "${openssh}/bin/ssh-agent -D -P none -a %t/${cfg.socket}";
              Restart = "always";
              RestartSec = 1;
            };
            Install.WantedBy = [ "default.target" ];
          };
          systemd.user.services.sk-agent-keys = {
            Unit = {
              Description = "Load the security key's handles into sk-agent";
              # Stopped with the agent, restarted with it, and started
              # again with each new agent, which holds nothing.
              BindsTo = [ "sk-agent.service" ];
              PartOf = [ "sk-agent.service" ];
              After = [ "sk-agent.service" ];
              # Each new agent needs its keys, however often it starts: a
              # loader restarted by hand a few times, or an agent started
              # again after reset-failed, would otherwise hit the loader's
              # start limit. The agent's own limit bounds how often it runs.
              StartLimitIntervalSec = 0;
            };
            Service = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${lib.getExe load} %t/${cfg.socket}";
            };
          };
        }
      ];
    })

    (lib.mkIf server {
      assertions = [
        {
          assertion = cfg.keys != [ ];
          message = "ravnix.skAgent.hosts lists git hosts, and ravnix.skAgent.keys is empty: ssh on the server offers those hosts the keys listed there and no other, so with none it cannot sign in to them. List the security key's handles, or leave ravnix.skAgent.hosts empty.";
        }
      ];

      services.openssh.settings.StreamLocalBindUnlink = true;

      home-manager.sharedModules = [
        {
          programs.ssh = {
            enable = true;
            # Its defaults are ssh's own, but for a warning on every build
            # that they will go.
            enableDefaultConfig = lib.mkDefault false;
            includes = [ "${sshConfig}" ];
          };
        }
      ];
    })
  ];
}
