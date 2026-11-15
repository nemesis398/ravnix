# The questions every generated theme file has to answer, shared by the
# theme checks of the TUIs. Being in a subdirectory of an area, this file is no
# check itself (lib/discover-checks.nix).
#
#   colors = import ./helpers/colors.nix { inherit pkgs lib; };
#   colors.check "theme-btop" { inherit palette; mauve = text; teal = text; }
#
# A file is rendered twice, once with the Mauve accent and once with Teal, and
# `check` fails unless
#   - every #rrggbb in it is a color of the palette (nothing is hand-set),
#   - the Mauve file uses Mauve, so the accent reaches it,
#   - the Teal file is the Mauve file with Mauve replaced by Teal and nothing
#     else changed: the accent slots follow the option and no other slot does,
#   - the Teal file has no Mauve left over,
#   - the same two hold for a third render with Sky (optional), which no slot
#     of any module is fixed to, so a slot fixed to Teal that Teal's own swap
#     cannot tell from the accent shows up.
# So a file may use Mauve only as the accent. `allowed` lists further colors
# a file may hold (a wash of a state hue over the canvas, which the module
# computes), and `extra` is a list of further failure messages from the
# caller's own assertions.
{ pkgs, lib }:
rec {
  hexes = text: lib.concatLists (lib.filter builtins.isList (builtins.split "(#[0-9a-fA-F]{6})" text));

  failures =
    {
      palette,
      mauve,
      teal,
      sky ? null,
      allowed ? [ ],
      extra ? [ ],
    }:
    let
      known = lib.attrValues palette ++ allowed;
      stray = lib.filter (h: !(lib.elem (lib.toLower h) known)) (hexes mauve ++ hexes teal ++ lib.optionals (sky != null) (hexes sky));
      expectedTeal = builtins.replaceStrings [ palette.mauve ] [ palette.teal ] mauve;
      expectedSky = builtins.replaceStrings [ palette.mauve ] [ palette.sky ] mauve;
    in
    lib.optional (stray != [ ]) "colors that are not the palette's: ${toString (lib.unique stray)}"
    ++ lib.optional (!lib.hasInfix palette.mauve mauve) "the accent (Mauve) is nowhere in the file"
    ++ lib.optional (
      teal != expectedTeal
    ) "the Teal file is not the Mauve file with the accent swapped: something else follows the accent, or a slot does not"
    ++ lib.optional (lib.hasInfix palette.mauve teal) "Mauve is left in the Teal file"
    # A third accent that no slot is fixed to. Teal alone cannot tell a slot
    # that is hard-coded Teal from an accent slot (a Teal render of both is the
    # same), and Sky can: a slot fixed to Teal stays Teal here, an accent slot
    # becomes Sky.
    ++ lib.optional (
      sky != null && sky != expectedSky
    ) "the Sky file is not the Mauve file with the accent swapped: a slot is fixed to a color that Teal hides"
    ++ lib.optional (sky != null && lib.hasInfix palette.mauve sky) "Mauve is left in the Sky file"
    ++ extra;

  check =
    name: args:
    let
      found = failures args;
    in
    pkgs.runCommand name { } (
      if found == [ ] then
        ''
          touch $out
        ''
      else
        ''
          printf '%s\n' ${lib.escapeShellArgs found} >&2
          exit 1
        ''
    );

  # Does this text hold the line (as a whole line)?
  hasLine = text: line: lib.elem line (lib.splitString "\n" text);
}
