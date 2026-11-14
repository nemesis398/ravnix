# iamb's colors, from the roles. iamb 0.13 has a `theme` table (a color, a
# background and modifiers per element, hex colors, a line style for borders),
# so it no longer draws with the terminal's ANSI palette. Rendered with the
# Mauve and the Teal accent, the file holds only palette colors and only the
# accent slots move: the focused border, the prompt, the focused tab, the
# unread marker.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  server = import ./helpers/server.nix { inherit self inputs lib; };
  colors = import ./helpers/colors.nix { inherit pkgs lib; };

  # A Matrix account, or iamb gets no configuration file at all.
  account = {
    ravnix.matrix = {
      userId = lib.mkForce "@alice:example.org";
      homeserver = lib.mkForce "https://matrix.example.org";
    };
  };
  mauve = (server "mauve" account).config;
  teal = (server "teal" account).config;
  inherit (mauve.ravnix.theme) palette roles;

  fileOf = c: c.home.file."${c.xdg.configHome}/iamb/config.toml".source;
  textOf = c: builtins.readFile (fileOf c);
  parsed =
    c:
    builtins.fromJSON (
      builtins.readFile (
        pkgs.runCommand "iamb.json" { nativeBuildInputs = [ pkgs.remarshal ]; } ''
          remarshal -if toml -of json < ${fileOf c} > $out
        ''
      )
    );
  t = (parsed mauve).theme;
  tt = (parsed teal).theme;
  at = x: path: lib.attrByPath path null x;

  # (path, key, what it must be in Mauve and in Teal)
  accentSlots = [
    [ "windows" "border_focused" "color" ]
    [ "cmdbar" "prompt" "color" ]
    [ "tabs" "title_focused" "background" ]
    [ "timeline" "unread_marker" "color" ]
    [ "rooms" "notification" "number" "color" ]
  ];
  fixed = [
    {
      path = [ "default" "color" ];
      want = roles.text;
    }
    {
      path = [ "default" "background" ];
      want = roles.canvas;
    }
    {
      path = [ "selected" "background" ];
      want = roles.selected;
    }
    {
      path = [ "windows" "border" "color" ];
      want = roles.line;
    }
    {
      path = [ "tabs" "title_focused" "color" ];
      want = roles.deepest;
    }
  ];
  noRainbow = (t.users.colors or null) == [ ];
  extra =
    lib.concatMap (
      p:
      lib.optional (at t p != roles.accent) "theme.${lib.concatStringsSep "." p} is ${toString (at t p)}, not the accent"
      ++ lib.optional (at tt p != teal.ravnix.theme.roles.accent) "theme.${lib.concatStringsSep "." p} does not follow the accent"
    ) accentSlots
    ++ lib.concatMap (
      f:
      lib.optional (at t f.path != f.want) "theme.${lib.concatStringsSep "." f.path} is ${toString (at t f.path)}, want ${f.want}"
    ) fixed
    # TUIs draw the single light line.
    ++ lib.concatMap (
      k: lib.optional (at t [ "windows" k "line" ] != "plain") "windows.${k} is not a plain line"
    ) [ "border" "border_focused" ]
    # Names are not a rainbow of ANSI hues.
    ++ lib.optional (!noRainbow) "usernames still use a palette of hues"
    ++ lib.optional (at (parsed mauve) [ "profiles" "main" "user_id" ] != "@alice:example.org") "the profile is gone";
in
colors.check "theme-iamb" {
  inherit palette extra;
  mauve = textOf mauve;
  teal = textOf teal;
}
