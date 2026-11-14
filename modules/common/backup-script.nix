# The script of the host's backup (./backup.nix, ./backup-system.nix), for
# both ways of reading its two secrets. Not a module: they call it as
#
#   import ./backup-script.nix { inherit lib pkgs; } { cfg; home; rbw ? null; }
#   => { package = the ravnix-backup program; problems = [ messages ]; }
#
# cfg is ravnix.backup.nas. With secrets = "rbw", rbw (its program) reads
# both items at each run. With secrets = "file", the program reads the
# root-only file that systemd hands it as the credential ravnix-backup
# ($CREDENTIALS_DIRECTORY/ravnix-backup), with two lines, `repository=` and
# `login=`; it never runs rbw, so nothing falls back to it.
#
# restic runs by the name `restic`, from PATH, so its command line starts
# with `restic ` and idle-suspend sees it (packages/energy, `pgrep -f
# '^restic '`) and does not suspend the laptop under it.
{ lib, pkgs }:
{
  cfg,
  home,
  rbw ? null,
}:
let
  # ~/.cache goes through the same builder, so a glob character in the
  # home is escaped there too, but as what is left out always: keep cannot
  # take a path back from it.
  excludes = import ./backup-excludes.nix { inherit lib; } {
    inherit home;
    inherit (cfg) paths exclude keep;
    always = [ "~/.cache" ];
  };
  expand =
    p:
    if p == "~" then
      home
    else if lib.hasPrefix "~/" p then
      home + lib.removePrefix "~" p
    else
      p;

  fromFile = cfg.secrets == "file";
  sed = lib.getExe pkgs.gnused;
  # The first line that starts with KEY=, without it.
  field = key: "${sed} -n '/^${key}=/{s///p;q}'";

  # restic splits the command on blanks; a store path has none.
  password =
    if fromFile then
      pkgs.writeShellScript "ravnix-backup-password" ''
        exec ${field "repository"} "$CREDENTIALS_DIRECTORY/ravnix-backup"
      ''
    else
      pkgs.writeShellScript "ravnix-backup-password" ''
        exec ${rbw} get -- ${lib.escapeShellArg cfg.passwordItem}
      '';

  file = lib.escapeShellArg cfg.secretsFile;
  readLogin =
    if fromFile then
      ''
        file=${file}
        cred=''${CREDENTIALS_DIRECTORY:-}/ravnix-backup
        if [ -z "''${CREDENTIALS_DIRECTORY:-}" ] || [ ! -r "$cred" ]; then
          echo "the backup's secrets file $file did not reach it (no readable credential ravnix-backup); write it once as root, as ravnix.backup.nas.secretsFile says" >&2
          exit 1
        fi
        login=$(${field "login"} "$cred")
        repository=$(${field "repository"} "$cred")
        if [ -z "$login" ] || [ -z "$repository" ]; then
          echo "the backup's secrets file $file lacks a repository= or a login= line; write it again as root, as ravnix.backup.nas.secretsFile says" >&2
          exit 1
        fi
        unset repository
        # The unit's CacheDirectory=, as systemd names it; its UID has no
        # home of its own.
        if [ -n "''${CACHE_DIRECTORY:-}" ]; then
          export RESTIC_CACHE_DIR=$CACHE_DIRECTORY
        fi
      ''
    else
      ''
        ${import ../workbench/unlocked.nix {
          inherit rbw;
          what = "the backup's login";
        }}
        item=${lib.escapeShellArg cfg.loginItem}
        login=$(${rbw} get -- "$item") || {
          echo "rbw could not read the password of the item $item" >&2
          exit 1
        }
        if [ -z "$login" ]; then
          echo "the item $item has no password: the host's login at the rest-server" >&2
          exit 1
        fi
      '';
in
{
  inherit (excludes) problems;
  package = pkgs.writeShellApplication {
    name = "ravnix-backup";
    runtimeInputs = [
      pkgs.restic
      pkgs.coreutils
    ];
    text = ''
      ${readLogin}
      export RESTIC_REPOSITORY=${lib.escapeShellArg cfg.repository}
      export RESTIC_PASSWORD_COMMAND=${password}
      RESTIC_REST_USERNAME=${lib.escapeShellArg cfg.host} RESTIC_REST_PASSWORD=$login \
        restic backup --host ${lib.escapeShellArg cfg.host} --exclude-caches \
          ${lib.escapeShellArgs (map (p: "--exclude=${p}") excludes.patterns)} \
          -- ${lib.escapeShellArgs (map expand cfg.paths)}
    '';
  };
}
