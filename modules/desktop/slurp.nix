# slurp, the area selector behind the Print key, in the style's colors.
# grimshot calls plain `slurp -d`, which dims the screen white and draws a
# black frame, and slurp takes colors by flag only, so this module puts a
# slurp that carries the flags first on the PATH, and builds grimshot against
# it (grimshot names its slurp in its own PATH, so a wrapper ahead of it on the
# user's PATH would not be found).
#
#   -c  the frame: the accent, 1 px (the lineWidth frame)
#   -b  the dim over the screen: clear, nothing is tinted
#   -s  the selection: clear, so the pixels you are about to capture keep
#       their color and the accent frame alone says where you are
#   -B  the highlight of the windows to choose from: clear as well
#   -F  the font of the size box
#
# Clear is an alpha of 0 on Base, not a translucent fill: the style allows
# no transparency, and an opaque Surface0 over the selection would hide what
# is being captured. The size box (-d) takes its colors from slurp itself.
# The module replaces slurp and grimshot in the system packages, which
# sway.nix no longer lists.
{ config, lib, pkgs, ... }:
let
  inherit (config.ravnix.theme) roles lineWidth font;
  clear = "${roles.canvas}00";
  flags = [
    "-b"
    clear
    "-c"
    "${roles.accent}ff"
    "-s"
    clear
    "-B"
    clear
    "-w"
    (toString lineWidth.frame)
    "-F"
    font
  ];
  slurp = pkgs.symlinkJoin {
    name = "slurp-themed-${pkgs.slurp.version}";
    paths = [ pkgs.slurp ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/slurp --add-flags ${lib.escapeShellArg (lib.escapeShellArgs flags)}
    '';
    inherit (pkgs.slurp) meta;
  };
  grimshot = pkgs.sway-contrib.grimshot.override { inherit slurp; };
in
{
  environment.systemPackages = [
    slurp
    grimshot
  ];
}
