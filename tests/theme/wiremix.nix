# wiremix's colors, from the roles. wiremix 0.11 has a `[themes.NAME]` table
# with a style (fg, bg, modifiers) per element, hex colors included, and the
# binary refuses a config with an element it does not know (it prints the
# list), so the element names below are the ones it printed. Rendered with the
# Mauve and the Teal accent, the file holds only palette colors and only the
# accent slots move: the selector, the filled part of a volume bar, the open
# dropdown's frame, the active tab. An overloaded meter is Peach, a warning.
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
  user = (import ../../templates/default/me.nix).ravnix.user.username;
  mauve = (host "mauve").config.home-manager.users.${user};
  teal = (host "teal").config.home-manager.users.${user};
  inherit (mauve.ravnix.theme) palette roles;

  file = c: c.xdg.configFile."wiremix/wiremix.toml".source;
  textOf = c: builtins.readFile (file c);
  parsed =
    c:
    builtins.fromJSON (
      builtins.readFile (
        pkgs.runCommand "wiremix.json" { nativeBuildInputs = [ pkgs.remarshal ]; } ''
          remarshal -if toml -of json < ${file c} > $out
        ''
      )
    );
  t = (parsed mauve).themes.ravnix;
  tt = (parsed teal).themes.ravnix;

  # The elements the binary named, every one of which the theme sets: an
  # element left out falls back to the built-in colors.
  elements = [
    "default_device"
    "default_stream"
    "selector"
    "tab"
    "tab_selected"
    "tab_marker"
    "list_more"
    "node_title"
    "node_target"
    "volume"
    "volume_empty"
    "volume_filled"
    "meter_inactive"
    "meter_active"
    "meter_overload"
    "meter_center_inactive"
    "meter_center_active"
    "config_device"
    "config_profile"
    "dropdown_icon"
    "dropdown_border"
    "dropdown_item"
    "dropdown_selected"
    "dropdown_more"
    "help_border"
    "help_item"
    "help_more"
  ];
  accentFg = [
    "selector"
    "tab_marker"
    "volume_filled"
    "meter_active"
    "meter_center_active"
    "dropdown_border"
    "help_border"
  ];
  extra =
    lib.optional ((parsed mauve).theme or null != "ravnix") "theme is not ravnix"
    ++ lib.optional (t."inherit" or null != "plain") "the theme does not start from plain"
    ++ map (k: "element ${k} is not set") (lib.filter (k: !(t ? ${k})) elements)
    ++ map (k: "element ${k} is not one wiremix knows") (lib.filter (k: !(lib.elem k (elements ++ [ "inherit" ]))) (lib.attrNames t))
    ++ lib.concatMap (
      k:
      lib.optional (t.${k}.fg or null != roles.accent) "${k} is ${toString (t.${k}.fg or null)}, not the accent"
      ++ lib.optional (tt.${k}.fg or null != teal.ravnix.theme.roles.accent) "${k} does not follow the accent"
    ) accentFg
    ++ lib.optional (
      t.tab_selected.bg or null != roles.accent || t.tab_selected.fg or null != roles.deepest
    ) "the active tab is not Crust on the accent"
    ++ lib.optional (t.dropdown_selected.bg or null != roles.selected) "the selected entry is not Surface1"
    ++ lib.optional (t.meter_overload.fg or null != palette.peach) "an overloaded meter is not Peach"
    ++ lib.optional (t.volume_empty.fg or null != roles.line) "the empty part of a volume bar is not Surface2";
in
colors.check "theme-wiremix" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
}
