# What the Sway and Waybar modules share: filling @token@ placeholders in
# their data files, and packaging the helper scripts that sit in
# modules/desktop/sway/bin and modules/desktop/waybar/bin. It is a data file
# of the desktop module (no default.nix, so lib/import-dir.nix does not import
# it); sway.nix and waybar.nix import it.
#
#   helpers = import ./sway/lib.nix { inherit lib pkgs; };
#   helpers.fill { accent = "..."; } text      text with @accent@ replaced
#   helpers.bash { name; src; tokens; runtimeInputs; }
#   helpers.python { name; src; tokens; flakeIgnore; }
{ lib, pkgs }:
rec {
  # Replaces @name@ for every name in tokens. A token of the file that nobody
  # gives is an error that names it, so a typo in a data file fails the build
  # instead of reaching a running session as a literal "@acent@" (tokens start
  # with a lower-case letter, which is why pactl's @DEFAULT_SINK@ is left
  # alone). Only the file is read for tokens, never the filled result: a value
  # of a user may hold "@word@" (an item named key@work@x, a command) and is
  # kept as it is. The replacement is one pass, so such a value is not filled
  # a second time.
  fill =
    tokens: text:
    let
      known = map (n: "@${n}@") (lib.attrNames tokens);
      wanted = lib.unique (
        lib.concatMap (m: if lib.isList m then m else [ ]) (builtins.split "(@[a-z][A-Za-z0-9.]*@)" text)
      );
      left = lib.filter (t: !(lib.elem t known)) wanted;
    in
    if left != [ ] then
      throw "modules/desktop: ${lib.concatStringsSep ", " left} is no token of this file (known: ${lib.concatStringsSep ", " (lib.attrNames tokens)})"
    else
      lib.replaceStrings known (lib.attrValues tokens) text;

  # The text of a script without its shebang: the builders add their own.
  body =
    interpreter: file:
    let
      text = builtins.readFile file;
      shebang = "#!/usr/bin/env ${interpreter}\n";
    in
    if lib.hasPrefix shebang text then
      lib.removePrefix shebang text
    else
      throw "${toString file} does not start with ${lib.removeSuffix "\n" shebang}";

  # A Bash script as a package with its original command name. shellcheck runs
  # at build time (writeShellApplication). The scripts set their own options
  # (`set -uo pipefail`, never -e: a bar module that fails must not stop), so
  # none is added. Tools the script calls are runtimeInputs; the tools of the
  # session (swaymsg when the session's sway is meant) and of other modules
  # (lock-screen, energy, wtype) come from the PATH of the session.
  bash =
    {
      name,
      src,
      tokens ? { },
      runtimeInputs ? [ ],
      excludeShellChecks ? [ ],
    }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs excludeShellChecks;
      bashOptions = [ ];
      text = fill tokens (body "bash" src);
    };

  # A Python script, unchanged but for its tokens, as a package with its
  # original command name. flake8 runs at build time; flakeIgnore lists the
  # rules the original code does not meet, each with its reason where it is
  # used. Python scripts call the tools of the session by their names
  # (swaymsg, fuzzel, wl-copy) and so rely on the PATH of the session.
  python =
    {
      name,
      src,
      tokens ? { },
      flakeIgnore ? [ ],
    }:
    pkgs.writers.writePython3Bin name { inherit flakeIgnore; } (fill tokens (body "python3" src));
}
