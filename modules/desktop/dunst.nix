# dunst, the notification daemon: a systemd user service of the session
# (home-manager's services.dunst, started with graphical-session.target, which
# sway-session.target brings up), and the dunstctl keys of the Sway config.
# The colors, the 1 px frame, the font and the Peach frame of a critical
# notification are the theme module's (modules/theme/default.nix).
#
# The geometry is PINNED below to what dunst 1.13.2 compiles in. The old setup
# ran on those defaults on purpose (its dunstrc only added the theme), so a new
# dunst must not move the popups or change their padding unnoticed: a changed
# default now needs a changed line here. The values are read from dunst's own
# settings_data.h, not from the example dunstrc, which differs from the
# compiled defaults.
{ pkgs, ... }:
{
  # dunstctl, for the keys that close, act on and pause notifications.
  environment.systemPackages = [ pkgs.dunst ];

  home-manager.sharedModules = [
    {
      # home-manager's unit is activated by D-Bus and has no Install section.
      # dunst's D-Bus service file is not named after the name it provides
      # (org.knopwob.dunst.service for org.freedesktop.Notifications), which
      # dbus-broker, NixOS's bus, refuses, so nothing would ever start dunst.
      # The session starts it instead: this links it into
      # graphical-session.target.wants, which sway-session.target brings up.
      systemd.user.services.dunst.Install.WantedBy = [ "graphical-session.target" ];

      services.dunst = {
        enable = true;
        settings.global = {
          # Where a notification goes: the top right, 10 px from the right edge
          # and 50 px from the top (below the bar), 300 px wide and as high as
          # its text, up to 300 px, and at most twenty at once.
          origin = "top-right";
          offset = "(10, 50)";
          width = 300;
          height = "(0, 300)";
          notification_limit = 20;
          # Inside a notification: 8 px of padding all around, no gap between
          # stacked ones and a 1 px separator line, square corners, no
          # transparency, a 10 px progress bar between 150 and 300 px wide.
          # Everything is dunst 1.13.2's compiled default but the separator,
          # whose default of 2 px is neither a frame nor a marker
          # (docs/style.md: 1 px frames, 2 px markers, no other widths).
          padding = 8;
          horizontal_padding = 8;
          text_icon_padding = 0;
          gap_size = 0;
          separator_height = 1;
          corner_radius = 0;
          transparency = 0;
          progress_bar_height = 10;
          progress_bar_min_width = 150;
          progress_bar_max_width = 300;
          progress_bar_frame_width = 1;
          progress_bar_corner_radius = 0;
          # The text: left aligned, wrapped, cut in the middle when too long.
          alignment = "left";
          word_wrap = true;
          ellipsize = "middle";
          icon_position = "left";
        };
      };
    }
  ];
}
