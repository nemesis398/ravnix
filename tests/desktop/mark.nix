# The raven mark on the running system, outside backdrop (whose check,
# desktop-backdrop, covers the wallpaper and the lock image): the mark at the
# left end of Waybar, in the accent, and the mark as text in tuigreet's
# greeting, in the accent. Two evaluations of the desktop module, with the
# default accent and with Teal, so a test cannot pass on Mauve by accident.
#
# The art in assets/ravnix-mark.txt is made by tests/desktop/helpers/
# mark-art.py from assets/ravnix-mark.svg; this check makes it again and fails
# when the two differ, printing the art it made.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  hostOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ modules;
    };
  mauve = hostOf [ ];
  teal = hostOf [ { ravnix.theme.accent = lib.mkForce "teal"; } ];

  source = host: name: "${host.config.home-manager.users.${user}.xdg.configFile.${name}.source}";
  variant = host: {
    inherit (host.config.ravnix.theme.roles) accent;
    config = source host "waybar/config.jsonc";
    focus = source host "waybar/config-focus.jsonc";
    modules = source host "waybar/modules.jsonc";
    style = source host "waybar/style.css";
    greeter = host.config.services.greetd.settings.default_session.command;
    # greetd's own config file, as the service starts greetd with it.
    greetd = host.config.systemd.services.greetd.serviceConfig.ExecStart;
  };

  # backdrop's interpreter and typelibs have cairo, librsvg and GdkPixbuf.
  inherit ((pkgs.extend self.overlays.default).ravnix) backdrop;
  python = "${backdrop.python}/bin/python3";

  # As many rows as the checked-in art has, so a new height is one edit of the
  # file; mark-checks.py bounds the rows to 10 to 16.
  rows = lib.length (lib.splitString "\n" (lib.removeSuffix "\n" (builtins.readFile ../../assets/ravnix-mark.txt)));
  fresh = pkgs.runCommand "ravnix-mark-art" {
    GI_TYPELIB_PATH = backdrop.typelibPath;
    PYTHONDONTWRITEBYTECODE = "1";
  } "${python} -I ${./helpers/mark-art.py} ${../../assets/ravnix-mark.svg} ${toString rows} > $out";

  args = pkgs.writeText "desktop-mark-args.json" (
    builtins.toJSON {
      palette = import ../../modules/theme/palette.nix;
      svg = ../../assets/ravnix-mark.svg;
      art = ../../assets/ravnix-mark.txt;
      imageFixture = ./fixtures/waybar-image-no-interval.jsonc;
      inherit fresh;
      variants = {
        mauve = variant mauve;
        teal = variant teal;
      };
    }
  );
in
pkgs.runCommand "desktop-mark"
  {
    GI_TYPELIB_PATH = backdrop.typelibPath;
    # The SVG loader of GdkPixbuf, which wrapGAppsHook3 gives Waybar too.
    GDK_PIXBUF_MODULE_FILE = "${lib.getLib pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
    PYTHONDONTWRITEBYTECODE = "1";
  }
  ''
    ${python} -I ${./helpers/mark-checks.py} ${args} 2>&1 | tee $out
    test "''${PIPESTATUS[0]}" = 0
  ''
