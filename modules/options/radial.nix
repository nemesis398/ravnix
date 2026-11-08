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
      flake (`./radial/menu.toml`; the flake's source is in the store, and
      Nix copies the file with it), or a store path that comes from a
      derivation (a string with string context). Nothing else is read: a
      string that names a file outside the store, a store path typed out as plain text (it has no
      context, so Nix does not know it) and a path literal outside your flake
      are refused with a message that names this option, because a flake
      evaluates purely and could not copy them. The file is a copy, so a change
      of the menu takes a rebuild, which restarts the launcher.

      The menu decides what the eight sectors of the ring hold and what each
      one runs; the default menu at `packages/sway-radial/menu.toml` in ravnix
      is the model to copy and edit, and its header explains the one rule that
      bites (Back is always the south sector of a submenu).

      Null, the default, is ravnix's own menu: apps, workspaces, clipboard,
      capture, system, audio, tools and display, built only from what the
      desktop module installs and holding nothing that belongs to one machine
      (no sink, no address). A menu is the place for what does: a sink name, a
      display profile, an app of yours.

      A file that is missing, not TOML or not a valid menu does not stop the
      launcher: it starts with ravnix's menu and says in the journal which
      file it refused, which menu and which direction (`journalctl --user -u
      sway-radial`).
    '';
  };
}
