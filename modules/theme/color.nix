# Color arithmetic for the modules that turn the roles into another tool's
# file. A tool that takes a color in a form the roles do not come in (a
# 0-255 triple, an escape) or that needs a wash of a state hue over the
# canvas (a diff line) calls these, so no module writes a hex color and the
# user's accent still reaches every file.
#
#   lib = import ../theme/color.nix { inherit lib; };
#   lib.rgb "#cba6f7"                      "rgb(203,166,247)"
#   lib.channels "#cba6f7"                 [ 203 166 247 ]
#   lib.mix { over = base; tint = green; percent = 20; }
#                                          "#rrggbb": 20 % of green over base
{ lib }:
rec {
  # "#rrggbb" as [ r g b ] in 0 to 255.
  channels =
    hex: map (i: lib.fromHexString (builtins.substring i 2 hex)) [
      1
      3
      5
    ];

  # [ r g b ] as "#rrggbb".
  fromChannels =
    cs:
    "#"
    + lib.concatMapStrings (
      c:
      let
        h = lib.toLower (lib.toHexString c);
      in
      if builtins.stringLength h == 1 then "0${h}" else h
    ) cs;

  rgb = hex: "rgb(${lib.concatMapStringsSep "," toString (channels hex)})";

  # percent of `tint` over `over`, channel by channel, rounded to the nearest.
  mix =
    {
      over,
      tint,
      percent,
    }:
    fromChannels (
      lib.zipListsWith (o: w: (o * (100 - percent) + w * percent + 50) / 100) (channels over) (
        channels tint
      )
    );
}
