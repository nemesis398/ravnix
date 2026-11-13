# backdrop and lock-screen (packages/backdrop): the pytest tests in
# packages/backdrop/tests run against the built package, in the sandbox, so
# with no network. They draw the wallpaper and the lock image and look at the
# pixels, run lock-screen over stand-ins for swaylock and swaymsg, and run the
# real fastfetch with the fastfetch config that ravnix writes for the user.
#
# sway and swaylock are what the package falls back to, behind the session's
# own; the check builds the package with empty stand-ins for them, so that it
# does not pull a compositor into the sandbox. The test's own stand-ins are in
# packages/backdrop/tests/stubs.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  ravnixPkgs = pkgs.extend self.overlays.default;
  empty = pkgs.runCommand "backdrop-test-empty" { } "mkdir -p $out/bin";
  backdrop = ravnixPkgs.ravnix.backdrop.override {
    sway-unwrapped = empty;
    swaylock = empty;
  };

  python = pkgs.python3.withPackages (ps: [
    ps.pytest
    ps.numpy
    ps.pycairo
    ps.pygobject3
  ]);

  # The palette the tests compare pixels with: the theme module's own, so no
  # test holds a color of its own.
  palette = pkgs.writeText "palette.json" (builtins.toJSON (import ../../modules/theme/palette.nix));

  # The fastfetch config the user's home-manager configuration gets, which the
  # wallpaper's facts come from in real use.
  hm = import ../common/helpers/hm.nix { inherit self inputs lib; pkgs = ravnixPkgs; };
  fastfetchConfig = (hm [ ]).config.xdg.configFile."fastfetch/config.jsonc".source;

  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.nerd-fonts.jetbrains-mono ]; };
in
pkgs.runCommand "desktop-backdrop"
  {
    nativeBuildInputs = [
      python
      pkgs.bash
      pkgs.coreutils
      pkgs.procps
      pkgs.util-linux
    ];
    BACKDROP = "${backdrop}/bin/backdrop";
    # The script itself, so that the tests put their own backdrop on the PATH;
    # the wrapper, whose own backdrop comes first, for the end-to-end test.
    LOCK_SCREEN = "${backdrop}/libexec/backdrop/lock-screen";
    LOCK_SCREEN_WRAPPED = "${backdrop}/bin/lock-screen";
    BACKDROP_TEST_PALETTE = palette;
    BACKDROP_TEST_PHYLLON = ../../assets/phyllon-mark.svg;
    # The marks the package installs, and the brand guide's one-color mark
    # that the ravnix mark among them is a copy of.
    BACKDROP_TEST_SHIPPED = "${backdrop}/share/backdrop";
    BACKDROP_TEST_LOGO_MONO = ../../docs/brand/logo-mono.svg;
    BACKDROP_REAL_FASTFETCH = "1";
    BACKDROP_TEST_FASTFETCH_CONFIG = fastfetchConfig;
    GI_TYPELIB_PATH = backdrop.typelibPath;
    FONTCONFIG_FILE = fonts;
    PYTHONDONTWRITEBYTECODE = "1";
  }
  ''
    export HOME="$TMPDIR"
    pytest -q -p no:cacheprovider --basetemp="$TMPDIR/pytest" ${../../packages/backdrop/tests}
    touch $out
  ''
