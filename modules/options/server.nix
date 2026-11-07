# The server shape, muninn: how the laptop's main terminal reaches it, and
# the repository Claude Code's Remote Control works from.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.server = {
    sshTarget = mkOption {
      type = ravnix.sshTarget;
      example = "alice@muninn.example.org";
      description = ''
        How huginn reaches muninn over ssh: `[user@]host` (host an address or
        an ssh alias) or `ssh://[user@]host[:port]`. The main terminal key
        opens herdr there.
      '';
    };

    remoteControlDir = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/src/project";
      description = ''
        The git repository that Claude Code's Remote Control works from on
        muninn: each session you start from the phone gets a worktree of it.
        An absolute path in a string. Null leaves Remote Control off.
      '';
    };

    netbirdAddress = mkOption {
      type = ravnix.address;
      example = "198.51.100.20";
      description = ''
        muninn's address in your NetBird network, which reaches it from
        anywhere the laptop roams. The bare address, without the `/16` that
        `netbird status` prints after it.
      '';
    };
  };
}
