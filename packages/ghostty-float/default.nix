# ghostty-float: open ghostty as a window of its own with a dedicated Wayland
# app_id, which a compositor rule floats and centers. The terminal apps that
# control the laptop's own hardware (yazi, wiremix, bluetui, nmtui) run in it,
# locally and not in the herdr session on the server.
#
# This only starts ghostty. Floating and sizing are the compositor's, by a rule
# on the same app_id (the Sway configuration of the desktop):
#
#   for_window [app_id="com.mitchellh.ghostty.float"] floating enable, ...
#
# Keep the two identical. The id differs from ghostty's default
# (com.mitchellh.ghostty) on purpose, so the rule scopes to this window alone
# and every other terminal keeps tiling. It must stay a valid GTK application
# id: dotted, lowercase, no hyphens (ghostty also uses it as a D-Bus name). An
# invalid class is dropped without a word and ghostty falls back to the
# default, which would float every ghostty window.
#
# Further arguments go to ghostty, so `ghostty-float -e yazi` runs yazi.
{ writeShellApplication, ghostty }:
writeShellApplication {
  name = "ghostty-float";
  runtimeInputs = [ ghostty ];
  text = ''
    exec ghostty --class=com.mitchellh.ghostty.float "$@"
  '';
}
