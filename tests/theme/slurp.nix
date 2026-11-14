# The area selector of the Print key. grimshot calls plain `slurp -d`, whose
# colors are a white dim and a black frame, and slurp takes colors by flag
# only, so the desktop puts a slurp with the style's flags on the PATH and
# builds grimshot against it (modules/desktop/slurp.nix). Rendered with the
# Mauve and the Teal accent, the wrapper holds only palette colors, the 1 px
# frame is the accent and nothing else moves; there is no dim over the screen
# and no fill in the selection (a clear alpha, not a tint). The host has one
# slurp, the themed one, and grimshot is built against it.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  colors = import ./helpers/colors.nix { inherit pkgs lib; };
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  host =
    accent:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.desktop
        { ravnix.theme.accent = lib.mkForce accent; }
      ];
    };
  mauve = host "mauve";
  teal = host "teal";
  inherit (mauve.config.ravnix.theme) palette roles;

  slurps = h: lib.filter (p: lib.getName p == "slurp-themed") h.config.environment.systemPackages;
  plainSlurps = h: lib.filter (p: lib.getName p == "slurp") h.config.environment.systemPackages;
  one = h: lib.head (slurps h);
  textOf = h: builtins.readFile "${one h}/bin/slurp";
  # The wrapper holds `-x 'value'` pairs; the font has spaces.
  has = h: flag: value: lib.hasInfix " ${flag} '${value}' " (textOf h);

  grimshot = h: lib.filter (p: lib.getName p == "grimshot") h.config.environment.systemPackages;
  grimshotText = h: builtins.readFile "${lib.head (grimshot h)}/bin/grimshot";
  # The store path of the themed slurp, as plain text to look for.
  slurpPath = h: builtins.unsafeDiscardStringContext (toString (one h));

  portal = mauve.config.xdg.portal.wlr.settings.screencast or { };

  extra =
    lib.optional (lib.length (slurps mauve) != 1) "the host has ${toString (lib.length (slurps mauve))} themed slurps, not one"
    ++ lib.optional (plainSlurps mauve != [ ]) "the unthemed slurp is still in the system packages"
    ++ lib.optional (lib.length (grimshot mauve) != 1) "grimshot is not in the system packages once"
    # grimshot's own PATH is the one that finds slurp.
    ++ lib.optional (
      !lib.hasInfix (slurpPath mauve) (builtins.unsafeDiscardStringContext (grimshotText mauve))
    ) "grimshot does not call the themed slurp"
    ++ lib.optional (!has mauve "-c" "${roles.accent}ff") "the frame (-c) is not the accent"
    ++ lib.optional (
      !has teal "-c" "${teal.config.ravnix.theme.roles.accent}ff"
    ) "the frame does not follow the accent"
    ++ lib.optional (!lib.hasInfix " -w 1 " (textOf mauve)) "the frame is not 1 px"
    ++ lib.optional (!has mauve "-F" mauve.config.ravnix.theme.font) "the font is not the theme's"
    # Nothing dims the screen and the selection is not tinted: clear, so no
    # transparent layer is drawn.
    ++ lib.optional (!has mauve "-b" "${roles.canvas}00") "the background (-b) is not clear"
    ++ lib.optional (!has mauve "-s" "${roles.canvas}00") "the selection (-s) is not clear"
    ++ lib.optional (!has mauve "-B" "${roles.canvas}00") "the box highlight (-B) is not clear"
    # xdg-desktop-portal-wlr has a slurp of its own (the screen-share output
    # chooser, in the portal's PATH), so it is told to run the themed one with
    # the portal's own default arguments.
    ++ lib.optional (
      portal.chooser_type or null != "simple"
    ) "the portal's chooser_type is ${toString (portal.chooser_type or null)}, not simple"
    ++ lib.optional (
      builtins.unsafeDiscardStringContext (portal.chooser_cmd or "")
      != "${slurpPath mauve}/bin/slurp -f 'Monitor: %o' -or"
    ) "the portal's chooser_cmd is not the themed slurp with the portal's default arguments: ${portal.chooser_cmd or "unset"}";
in
colors.check "theme-slurp" {
  inherit palette extra;
  # The wrapper names itself by store path, which differs with the accent.
  mauve = builtins.replaceStrings [ (slurpPath mauve) ] [ "SLURP" ] (textOf mauve);
  teal = builtins.replaceStrings [ (slurpPath teal) ] [ "SLURP" ] (textOf teal);
}
