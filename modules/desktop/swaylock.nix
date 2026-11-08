# swaylock, the screen lock. Run by keep-awake's swayidle (after 5 minutes, on
# `loginctl lock-session`, before sleep) as `lock-screen || swaylock -f`, so
# the config below is the lock screen whenever lock-screen (Task 3.8) is not
# there; lock-screen passes the wallpaper image and reads this file for the
# rest. The ring is a gauge and the one place the style allows a line wider
# than 2 px and a translucent fill (the inside of the ring, so that it circles
# the picture): see docs/style.md.
#
#   idle ring       Surface2 on the Base screen, always visible (so that the
#                   screen never looks dead: indicator-idle-visible)
#   typing          key highlight in the accent, backspace highlight in Red
#   verifying       Blue ring, a Base wash inside, Text
#   wrong password  Red ring and text
#   cleared         Yellow ring
#   Caps Lock       Peach ring and line, Maroon backspace, Peach key highlight:
#                   easy to hit unnoticed on a de/us layout, where it turns
#                   every keystroke into a failed unlock
#
# There is no `ignore-empty-password`: Enter on an empty field is how a
# security key unlocks the screen (Enter, then touch), and the option would
# keep that Enter from reaching PAM.
#
# PAM: NixOS's programs.sway already gives swaylock its service; it is stated
# here as well, because the lock screen is useless without it.
{ config, lib, ... }:
let
  inherit (config.ravnix.theme) palette roles font;
  c = hex: lib.removePrefix "#" hex;
  # The wash inside the ring while it prints text over the picture: Base at
  # 80 %, the only translucent color of the style.
  wash = "${c roles.canvas}cc";
  clear = "${c roles.canvas}00";
in
{
  security.pam.services.swaylock = { };

  home-manager.sharedModules = [
    {
      programs.swaylock = {
        enable = true;
        settings = {
          # No image of its own: the fallback colour is the Base screen.
          color = c roles.canvas;
          inherit font;
          indicator-radius = 110;
          indicator-thickness = 10;
          indicator-idle-visible = true;
          show-failed-attempts = true;
          indicator-caps-lock = true;

          inside-color = clear;
          line-color = c roles.canvas;
          ring-color = c roles.line;
          text-color = c roles.text;
          separator-color = c roles.canvas;

          inside-clear-color = clear;
          line-clear-color = c roles.canvas;
          ring-clear-color = c palette.yellow;
          text-clear-color = c roles.canvas;

          inside-ver-color = wash;
          line-ver-color = c roles.canvas;
          ring-ver-color = c palette.blue;
          text-ver-color = c roles.text;

          inside-wrong-color = wash;
          line-wrong-color = c roles.canvas;
          ring-wrong-color = c palette.red;
          text-wrong-color = c palette.red;

          key-hl-color = c roles.accent;
          bs-hl-color = c palette.red;

          # The keyboard layout box under the ring blends into Base.
          layout-bg-color = c roles.canvas;
          layout-border-color = c roles.canvas;
          layout-text-color = c roles.text;

          inside-caps-lock-color = wash;
          line-caps-lock-color = c palette.peach;
          ring-caps-lock-color = c palette.peach;
          text-caps-lock-color = c roles.text;
          caps-lock-key-hl-color = c palette.peach;
          caps-lock-bs-hl-color = c palette.maroon;
        };
      };
    }
  ];
}
