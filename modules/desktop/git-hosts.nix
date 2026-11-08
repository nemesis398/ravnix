# The git hosts on the laptop take the security key over ssh, and never an
# agent (ravnix.laptop.gitKeys). SSH_AUTH_SOCK is rbw's agent (modules/
# common/rbw.nix), and the vault holds touch-free fallback keys for the same
# hosts: ssh tries every key an agent holds before a key that is only a
# file, so with the agent in reach a push would log in with one of those and
# the security key would never be asked. For these hosts ssh asks no agent
# (IdentityAgent none) and offers only the handles listed for each host
# (IdentitiesOnly), so a connection takes a touch. As on Fedora, one touch
# then holds for ten minutes (ControlMaster auto, ControlPersist 10m, the
# socket in /run/user/<uid>), and `ssh -O check <host>` says whether it
# still holds. Everything else keeps rbw's agent; commit signing goes
# through SSH_AUTH_SOCK and is not touched.
#
# Over ssh only. An HTTPS remote of github.com authenticates with gh's
# token, through the credential helper programs.gh installs (modules/common/
# git.nix), once `gh auth login` has run: such a push needs no key at all.
# Keep the remotes on ssh where a push should take the touch.
#
# The blocks are an Include at the top of ~/.ssh/config, and each comes
# twice. ssh takes the first value it finds for each option, and once a
# `Match final` is in the config it reads it in two passes: the first with
# the name as given, the second after the whole file, with the HostName it
# ended up with, and the second fills only what the first left unset. As
# `Match host <h>` the pin matches in the first pass, ahead of every block
# another module or the user adds, so a later `Host *` or `Host github.com`
# that sets IdentityAgent, IdentitiesOnly or ControlMaster loses to it. As
# `Match final host <h>` it matches in the second, so an alias whose
# HostName is a git host is pinned too. Both compare the host without
# regard to case, as DNS does (a `Host` line would let GitHub.COM past).
#
# What still gets past:
# - an alias of a git host, for every option that a block matching the
#   alias's own name sets: the pin reaches an alias only in the second
#   pass, so a later `Host *` with IdentityAgent hands it to that agent;
# - an IdentityFile another block adds, which ssh offers next to the
#   handles;
# - the name with a trailing dot, an address, and a name that is not
#   listed (GitHub's ssh.github.com is one: list it);
# - -o IdentityAgent= or GIT_SSH_COMMAND on the command line, which win
#   over every block.
#
# The fallback when the security key is not at hand is the last of these,
# on purpose and by hand, and without a control socket: the master is
# shared by host, port and user (%C), so one that the agent opened on the
# pinned ControlPath would carry every plain push for ten minutes, with no
# touch:
#   GIT_SSH_COMMAND="ssh -o IdentityAgent=$SSH_AUTH_SOCK -o IdentitiesOnly=no -o ControlPath=none" git push
# A fallback alias (HostName github.com and an IdentityAgent of its own)
# needs `ControlPath none` for the same reason, and `IdentitiesOnly no` as the
# command line has it: the pin's `identitiesonly yes` reaches the alias too,
# and with it ssh offers only the security key's handles, so the alias still
# asks for the touch. That fails closed, but it is no fallback
# (tests/laptop/git-hosts.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  keys = config.ravnix.laptop.gitKeys;
  hosts = lib.attrNames keys;
  bad = lib.filter (h: builtins.match "[a-z0-9]([a-z0-9.-]*[a-z0-9])?" h == null) hosts;
  # The pin under one Match keyword, `Match host` or `Match final host`.
  pin =
    match:
    lib.concatMapStrings (host: ''
      ${match} ${host}
        ${lib.concatMapStrings (file: "IdentityFile \"${file}\"\n  ") keys.${host}}
    '') hosts
    + ''
      ${match} ${lib.concatStringsSep "," hosts}
        IdentityAgent none
        IdentitiesOnly yes
        ForwardAgent no
        PreferredAuthentications publickey
        ControlMaster auto
        ControlPath /run/user/%i/ssh-git-%C
        ControlPersist 10m
    '';
  sshConfig = pkgs.writeText "ravnix-git-hosts.conf" (pin "Match host" + pin "Match final host");
in
{
  assertions = [
    {
      assertion = bad == [ ];
      message = "ravnix.laptop.gitKeys names ${toString bad}, which is not a host name in lowercase (letters, digits, dots and dashes): ssh's Match host would read a comma, a space or a pattern in it.";
    }
  ];

  home-manager.users.${config.ravnix.user.username} = lib.mkIf (keys != { }) {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = lib.mkDefault false;
      includes = [ "${sshConfig}" ];
    };
  };
}
