# The link between the hosts (modules/glue/link.nix, tools/ravnix-link): the
# socket it uses, and the vault: its repository on the server, where
# vault-commit commits, and its copy on the laptop. Which end of the link a
# host is comes from its shape (ravnix.shape, modules/options/shape.nix).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.link = {
    socket = mkOption {
      type = types.str;
      default = "ravnix-link.sock";
      readOnly = true;
      description = ''
        The link's socket, as a name in `$XDG_RUNTIME_DIR`, the same on both
        hosts: on the laptop the daemon listens on
        `$XDG_RUNTIME_DIR/ravnix-link.sock` (mode 600), and the main
        connection forwards it to the server, where it is
        `$XDG_RUNTIME_DIR/ravnix-link.sock` of the same user. The connection
        that forwards it (an ssh `RemoteForward` of the server's path to the
        laptop's) reads this value; the server's sshd replaces a socket that a
        dropped connection left behind (`StreamLocalBindUnlink`).
      '';
    };

    vault = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/notes";
      description = ''
        The Obsidian vault, an absolute path in a string. On the server it
        is the vault's git repository: `ravnix-link vault-commit` and
        `vault-commit` commit there, after the Obsidian operations queued
        before it have run on the laptop. On the laptop it is the copy the
        file sync keeps, without `.git`: `vault-commit` there reads the
        files it names and sends the commit to the server, which waits
        until its copy has them. One private flake for both hosts gives one
        path, so the sync must put the vault at the same place on both.
        Null: vault-commit is refused.
      '';
    };
  };
}
