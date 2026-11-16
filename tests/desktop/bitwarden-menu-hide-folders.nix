# Which items bwm's main menu lists with `hide_folders` in config.ini
# (packages/bitwarden-menu). bwm 0.6.0 filters on `i["folder"]` (bwm/bwm.py,
# dmenu_run), but an item from `bw list items` carries `folderId` and no
# `folder`: any `hide_folders` raised KeyError in the child that runs the
# menu, right after unlock, and bwm sends that child's stderr to /dev/null, so
# the login was the last thing to show. The package patches the filter to read
# the folder's name from `folderId`, as bwm does everywhere else.
#
# The check imports bwm.bwm of the package, with the interpreter and the site
# directories of its own `bwm` (read from the head of bin/.bwm-wrapped), and
# runs the real dmenu_run on fake items: one in a hidden folder, one in a shown
# one, one without a folder, one in a second hidden folder and one whose folder
# is gone, with the menu replaced by a recorder that chooses nothing. It
# requires that dmenu_run does not raise, and that exactly the items of the
# hidden folders are missing from the main menu and from "View/Type Individual
# entries", for no `hide_folders`, one folder, several, a name that is no
# folder, and "No Folder".
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostPkgs = inputs.nixpkgs.legacyPackages.${system};
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = (import ../flake/helpers/host-modules.nix { inherit lib; }) ++ [
      self.nixosModules.desktop
    ];
  };
in
pkgs.runCommand "desktop-bitwarden-menu-hide-folders"
  {
    nativeBuildInputs = [ hostPkgs.coreutils ];
    package = host.pkgs.ravnix.bitwarden-menu;
    probe = ./helpers/bwm-hide-folders.py;
  }
  ''
    export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR/run XDG_CACHE_HOME=$TMPDIR/cache XDG_CONFIG_HOME=$TMPDIR/config
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
    chmod 700 "$XDG_RUNTIME_DIR"

    # The interpreter and the site directories of bwm itself: the first three
    # lines of its entry script are the shebang and the path set-up.
    entry="$package/bin/.bwm-wrapped"
    python=$(sed -n '1s/^#! *//p' "$entry")
    { sed -n '3p' "$entry" | sed 's/^import sys;import site;import functools;sys.argv\[0\] = [^;]*;/import sys;import site;import functools;/'; cat "$probe"; } > "$TMPDIR/probe.py"
    if "$python" -I "$TMPDIR/probe.py" "$TMPDIR" > "$TMPDIR/probe.out" 2>&1; then
      cat "$TMPDIR/probe.out"
      touch $out
    else
      cat "$TMPDIR/probe.out"
      echo "FAIL: bwm's hide_folders"
      exit 1
    fi
  ''
