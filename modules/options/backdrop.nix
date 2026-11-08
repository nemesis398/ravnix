# The wallpaper and the lock image of the desktop (`backdrop`, packages/backdrop).
# Both are personal, so they are values a user may set in me.nix, and the
# options are declared here and not in the desktop module: me.nix is checked
# against the options module alone, and home-manager reads them too
# (modules/desktop/backdrop.nix).
{ lib, ... }:
{
  options.ravnix.desktop.backdrop = {
    image = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./wallpaper.jpg";
      description = ''
        Your own picture for the wallpaper and the lock image, as an absolute
        path or a path in your flake (which Nix copies into the store). PNG,
        JPEG and the other formats gdk-pixbuf reads; it is scaled until it
        covers each output and cropped at the middle. Null, the default, is
        ravnix's own wallpaper: Base, with the ravnix mark in the middle, the
        phyllon mark in the top left corner at the same size, and the NixOS
        logo with the system facts in the top right.

        The marks and the facts are drawn on your picture as they are on Base,
        and the lock image is the picture with the ravnix mark alone, which
        sits inside the lock ring. A picture that is missing, unreadable or
        larger than 64 megapixels is replaced by the default, with one line in
        the journal.
      '';
    };

    tools = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ ./backdrop-logos/odin.svg ./backdrop-logos/rust.svg ]";
      description = ''
        SVG logos of the tools you work with, drawn on the wallpaper (never on
        the lock image) in two Surface grays that alternate, spread evenly
        around the marks and the facts. Each logo is drawn as a single-color
        shape, so its own colors do not matter, and fits a box of 88 by 44
        logical pixels. Mind each logo's license and trademark: ravnix ships
        no logo of a tool. Empty, the default, draws none.
      '';
    };
  };
}
