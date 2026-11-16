# root's shell history on huginn, in the same shared timeline as the user's
# (the Fedora laptop did it with a script, atuin-root). Everything here is
# configuration, and nothing is state:
#
#   - root's atuin config, linked to /root/.config/atuin/config.toml: sync
#     with the atuin service the user places with ravnix.services.atuin, as
#     the user's own atuin does, and no sync where there is none. It sits at
#     the standard path so that a bare `sudo atuin ...` reads it, too;
#   - the init of root's bash: bash-preexec, then atuin's, with the up arrow
#     left to bash (--disable-up-arrow) and Ctrl-R atuin's, as the user's
#     shell has it (modules/common/bash.nix). It is read from /etc/bashrc and
#     runs for a shell of uid 0 only, so `sudo -i`, `su -` and a root console
#     get it, and the user's shell, which has its own, does not get it twice;
#   - atuin on the PATH, which the init and `sudo atuin ...` need, and
#     atuin-root-login (packages/atuin-root-login).
#
# What is not here is the login to the account. It is state, and it needs the
# account's password and its recovery key from Bitwarden, which root cannot
# read (rbw is the user's, and its vault is locked for everyone else). It is
# one command, once per install, run as the user with the vault unlocked:
#
#   atuin-root-login ITEM
#
# docs/install-from-another-distro.md has the step. Until it is done, root's
# history is recorded and stays on the laptop.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  service = config.ravnix.services.atuin or null;
  sync = service != null && service.enable;
  toml = pkgs.formats.toml { };

  configFile = toml.generate "atuin-root-config.toml" (
    {
      auto_sync = sync;
      # The binary comes from Nix, so a version bump is the flake's job.
      update_check = false;
    }
    // lib.optionalAttrs sync { sync_address = service.url; }
  );

  # atuin's bash integration, written at build time as the user's is
  # (modules/common/bash.nix): it depends on the program and not on the
  # configuration.
  integration = pkgs.runCommand "atuin-root-integration.bash" { } ''
    export HOME="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/config" XDG_DATA_HOME="$TMPDIR/data"
    ${lib.getExe pkgs.atuin} init bash --disable-up-arrow > "$out"
  '';

  # bash-preexec comes first: atuin registers on its hooks.
  init = pkgs.writeText "atuin-root-init.bash" ''
    source ${pkgs.bash-preexec}/share/bash/bash-preexec.sh
    source ${integration}
  '';

  private = {
    mode = "0700";
    user = "root";
    group = "root";
  };
in
{
  environment.systemPackages = [
    pkgs.atuin
    # With the service's URL written in; with none, the helper refuses, since
    # atuin would log in to its public server.
    (pkgs.ravnix.atuin-root-login.override { syncAddress = if sync then service.url else null; })
  ];

  # The directories are root's alone; the config is a link, replaced at every
  # boot, so a change of the flake reaches it.
  systemd.tmpfiles.settings."10-ravnix-atuin-root" = {
    "/root/.config".d = private;
    "/root/.config/atuin".d = private;
    "/root/.config/atuin/config.toml"."L+".argument = "${configFile}";
  };

  # mkAfter: bash-preexec hooks PROMPT_COMMAND and the DEBUG trap, so it comes
  # after everything else that /etc/bashrc sets up.
  programs.bash.interactiveShellInit = lib.mkAfter ''
    if [ "$EUID" -eq 0 ]; then
      source ${init}
    fi
  '';
}
