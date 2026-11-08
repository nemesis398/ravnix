# The wallpaper and the lock image: the `backdrop` and `lock-screen` commands
# (packages/backdrop) in the user's profile, and the config they read.
#
# kanshi calls `backdrop wallpaper` on every layout change, and swayidle and
# the lock key call `lock-screen`, so both have to be on the session's PATH;
# the sway module does not install them.
#
# The config is the theme and the two options of this file's namesake in
# modules/options (ravnix.desktop.backdrop.image and .tools), as JSON in
# ~/.config/backdrop/config.json. backdrop writes no color of its own: the
# palette, the accent and the font come from here, so a new accent reaches the
# marks at the next wallpaper. A change of any of it changes the file's store
# path, and the next `backdrop wallpaper` (kanshi runs it on every sway reload)
# draws it.
{ ... }:
{
  home-manager.sharedModules = [
    (
      {
        config,
        pkgs,
        ...
      }:
      let
        cfg = config.ravnix.desktop.backdrop;
        inherit (config.ravnix) theme;
      in
      {
        home.packages = [ pkgs.ravnix.backdrop ];

        xdg.configFile."backdrop/config.json".text = builtins.toJSON {
          inherit (theme) palette font accent;
          inherit (cfg) image tools;
        };
      }
    )
  ];
}
