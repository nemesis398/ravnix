# The radial menu behind the four-finger pinch on the trackpad (`sway-radial`,
# packages/sway-radial). Its menu is a file of the user's own, so the file is a
# value to set in me.nix; the option is declared here and not in the desktop
# module because me.nix is checked against the options module alone, and
# home-manager reads it too (modules/desktop/sway-radial.nix).
{ lib, ... }:
{
  options.ravnix.desktop.radial.menu = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    example = lib.literalExpression "./radial/menu.toml";
    description = ''
      Your own menu for the radial launcher, as a TOML file: a path in your
      flake (which Nix copies into the store) or an absolute path. It decides
      what the eight sectors of the ring hold and what each one runs; the
      default menu at `packages/sway-radial/menu.toml` in ravnix is the model
      to copy and edit, and its header explains the one rule that bites (Back
      is always the south sector of a submenu).

      Null, the default, is ravnix's own menu: apps, workspaces, clipboard,
      capture, system, audio, tools and display, built only from what the
      desktop module installs and holding nothing that belongs to one machine
      (no sink, no address). A menu is the place for what does: a sink name, a
      display profile, an app of yours.

      A file that is missing, not TOML or not a valid menu does not stop the
      launcher: it starts with ravnix's menu and says in the journal which
      file it refused, which menu and which direction (`journalctl --user -u
      sway-radial`). A rebuild that changes the file restarts the launcher.
    '';
  };
}
