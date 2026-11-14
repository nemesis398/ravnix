# nmtui's colors. newt names the 16 ANSI slots, which Ghostty maps onto Mocha,
# and slot 0 (`black`) is Surface1, so a background of `black` was a grey
# window on a Base screen. newt takes the name `default` (checked on newt
# 0.52 with whiptail: the root area prints the terminal's default foreground
# and background), which is Text on Base. So no background is `black`: the
# window is `default`, a button or the selected row is the accent
# (`brightmagenta`, slot 13), and the darkest text on it is `black`, the nearest
# the 16 slots come to Crust. `black` stays as a background only for the
# washes: the entry field, the selected row of an unfocused list, the empty
# part of a progress bar and the compact button. There is no shadow: it is drawn in the
# background's color.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [ self.nixosModules.desktop ];
  };
  value = host.config.environment.sessionVariables.NEWT_COLORS;

  # "name=fg,bg" pairs.
  pairs = map (
    kv:
    let
      m = builtins.match "([a-z]+)=([a-z]+),([a-z]+)" kv;
    in
    {
      name = lib.elemAt m 0;
      fg = lib.elemAt m 1;
      bg = lib.elemAt m 2;
    }
  ) (lib.splitString " " value);
  by = name: lib.findFirst (p: p.name == name) null pairs;

  washes = [
    "entry"
    "sellistbox"
    "emptyscale"
    "compactbutton"
  ];
  fills = lib.filter (p: p.bg == "brightmagenta") pairs;
  extra =
    # `black` is slot 0, Surface1: only a wash may be that, and a window, a
    # label or the frame may not.
    lib.concatMap (
      p:
      lib.optional (
        p.bg == "black" && !lib.elem p.name washes
      ) "${p.name} has a black (Surface1) background"
    ) pairs
    ++ lib.optional (by "root" == null || (by "root").bg != "default") "the root is not on the default background"
    ++ lib.optional (by "window" == null || (by "window").bg != "default") "the window is not on the default background"
    ++ lib.optional (by "shadow" == null || (by "shadow").bg != "default") "the shadow is not drawn in the background"
    # Text on an accent fill is the darkest the slots offer.
    ++ lib.concatMap (
      p: lib.optional (p.fg != "black") "${p.name}: text on the accent fill is ${p.fg}, not black"
    ) fills
    # The frame and title are the accent.
    ++ lib.optional ((by "border").fg or null != "brightmagenta") "the border is not the accent"
    ++ lib.optional ((by "title").fg or null != "brightmagenta") "the title is not the accent";
in
pkgs.runCommand "theme-nmtui" { } (
  if extra == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs extra} >&2
      exit 1
    ''
)
