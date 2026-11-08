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
# The blocks are an Include at the top of ~/.ssh/config, ahead of every block
# another module or the user adds there, since ssh takes the first value it
# finds for each option. They are `Match final host`: ssh compares the host
# without regard to case, as DNS does (a `Host` line would let GitHub.COM
# past), and after it has read the whole config, so an alias whose HostName
# is a git host is pinned too (a first-pass match would see only the
# alias's name). What still gets past, since ssh matches the name it ends up
# with: the name with a trailing dot, an address, a name that is not listed
# (GitHub's ssh.github.com is one: list it), and -o IdentityAgent= or
# GIT_SSH_COMMAND on the command line, which win over every block. The
# fallback when the security key is not at hand is exactly that, on
# purpose and by hand:
#   GIT_SSH_COMMAND="ssh -o IdentityAgent=$SSH_AUTH_SOCK -o IdentitiesOnly=no" git push
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
  sshConfig = pkgs.writeText "ravnix-git-hosts.conf" (
    lib.concatMapStrings (host: ''
      Match final host ${host}
        ${lib.concatMapStrings (file: "IdentityFile \"${file}\"\n  ") keys.${host}}
    '') hosts
    + ''
      Match final host ${lib.concatStringsSep "," hosts}
        IdentityAgent none
        IdentitiesOnly yes
        ForwardAgent no
        PreferredAuthentications publickey
        ControlMaster auto
        ControlPath /run/user/%i/ssh-git-%C
        ControlPersist 10m
    ''
  );
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
