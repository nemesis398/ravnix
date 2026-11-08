# sway-radial (packages/sway-radial): the pytest tests in
# packages/sway-radial/tests run against the built package, in the sandbox, so
# with no network, no compositor and no trackpad. They draw the ring and look at
# the pixels, feed the state machine gestures, read menu and theme files of
# every bad kind, and load the real libinput and libudev and compare the
# binding with libinput's own header. The font tests (pytest -m font) measure
# every label and icon of the default menu in JetBrainsMono Nerd Font.
#
# The tests run on the installed copy (PYTHONPATH is the package's lib), which
# is the one with the three library names turned into store paths, and the
# theme file is the one the module writes for the user's service: the accent is
# teal here, so a color that was written into the program instead of read from
# the file would fail. The module's own files are checks.desktop-sway-radial-module.
#
# Two lists come from here, because the sandbox has no machine to ask:
#   the programs the default menu may run, which are the scripts of the Sway
#   config and the bar, and the tools of the session that the config itself
#   runs. Each tool is matched below with the package that provides it on a
#   host with the desktop module, so a program that is dropped from the
#   desktop fails here and not in front of the user;
#   the .desktop ids it may launch, which desktop-apps (the applications) and
#   desktop-webapps (the web apps) prove exist.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  ravnixPkgs = pkgs.extend self.overlays.default;
  sway-radial = ravnixPkgs.ravnix.sway-radial;

  python = pkgs.python3.withPackages (ps: [
    ps.pytest
    ps.pycairo
    ps.pygobject3
  ]);

  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [
      self.nixosModules.common
      ../../modules/desktop/sway-radial.nix
      # Not the default accent: see the header.
      { ravnix.theme.accent = lib.mkForce "teal"; }
    ];
  };
  user = host.config.ravnix.user.username;
  unit = host.config.home-manager.users.${user}.systemd.user.services.sway-radial;
  themeLine = lib.findFirst (lib.hasPrefix "SWAY_RADIAL_THEME=") (throw "the unit sets no SWAY_RADIAL_THEME") unit.Service.Environment;
  themeFile = lib.removePrefix "SWAY_RADIAL_THEME=" themeLine;

  # The desktop module on a stubbed host, for the providers below.
  desktop = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = hostModules ++ [ self.nixosModules.desktop ];
  };
  installed = map lib.getName (
    desktop.config.environment.systemPackages
    ++ desktop.config.home-manager.users.${user}.home.packages
  );

  scripts = lib.concatMap (dir: lib.attrNames (builtins.readDir dir)) [
    ../../modules/desktop/sway/bin
    ../../modules/desktop/waybar/bin
  ];

  # Program -> the package that provides it on a host with the desktop module.
  providers = {
    ghostty = "ghostty";
    yazi = "yazi";
    wiremix = "wiremix";
    bluetui = "bluetui";
    nmtui = "networkmanager";
    grimshot = "grimshot";
    pactl = "pulseaudio";
    playerctl = "playerctl";
    brightnessctl = "brightnessctl";
    bluetoothctl = "bluez";
    netbird = "netbird-client";
    loginctl = "systemd";
    swaymsg = "sway";
    btop-auto = "btop-gpu";
  };
  missingProviders = lib.filter (name: !lib.elem providers.${name} installed) (lib.attrNames providers);

  programs = pkgs.writeText "programs" (lib.concatStringsSep "\n" (scripts ++ lib.attrNames providers) + "\n");

  desktopIds = pkgs.writeText "desktop-ids" (
    lib.concatStringsSep "\n" [
      "helium"
      "md.obsidian.Obsidian"
      "onlyoffice-desktopeditors"
      "bitwarden"
      "webapp-claude"
      "webapp-apple-music"
    ]
    + "\n"
  );

  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.nerd-fonts.jetbrains-mono ]; };

  # Only what the tests and pytest's configuration need, so that an edit of
  # default.nix or of the README does not run them again.
  tests = lib.fileset.toSource {
    root = ../../packages/sway-radial;
    fileset = lib.fileset.unions [
      ../../packages/sway-radial/pyproject.toml
      ../../packages/sway-radial/tests
    ];
  };
in
assert lib.assertMsg (missingProviders == [ ])
  "tests/desktop/sway-radial.nix: the desktop module no longer installs the package behind: ${lib.concatStringsSep ", " missingProviders}";
pkgs.runCommand "desktop-sway-radial"
  {
    nativeBuildInputs = [
      python
      pkgs.coreutils
    ];
    SWAY_RADIAL_THEME = themeFile;
    SWAY_RADIAL_TEST_PROGRAMS = programs;
    SWAY_RADIAL_TEST_DESKTOP_IDS = desktopIds;
    SWAY_RADIAL_TEST_LIBINPUT_H = "${lib.getDev pkgs.libinput}/include/libinput.h";
    GI_TYPELIB_PATH = sway-radial.typelibPath;
    FONTCONFIG_FILE = fonts;
    PYTHONPATH = "${sway-radial}/lib/sway-radial";
    PYTHONDONTWRITEBYTECODE = "1";
    swayRadial = sway-radial;
    runtimePath = sway-radial.runtimePath;
    gtkLaunch = sway-radial.gtkLaunch;
  }
  ''
    export HOME="$TMPDIR"

    # Everything but the tests that need a trackpad or a compositor.
    pytest -p no:cacheprovider --basetemp="$TMPDIR/pytest" \
      -c ${tests}/pyproject.toml --rootdir ${tests} \
      -m 'not hardware and not compositor and not machine' ${tests}/tests

    fail() { echo "FAIL: $*" >&2; exit 1; }

    # The installed program starts, through its wrapper, and says its version.
    "$swayRadial/bin/sway-radial" --version | grep -qx 'sway-radial 0.1.0' || fail "--version"

    # The swaymsg the daemon runs is on the PATH the wrapper adds, and the
    # gtk-launch that Sway runs for a desktop entry is the one it names, by
    # store path, in the variable the program reads.
    found=
    IFS=: read -ra dirs <<< "$runtimePath"
    for dir in "''${dirs[@]}"; do [ -x "$dir/swaymsg" ] && found=1; done
    [ -n "$found" ] || fail "swaymsg is not on the wrapper's PATH"
    [ -x "$gtkLaunch" ] || fail "$gtkLaunch is not an executable"
    grep -qxF "export SWAY_RADIAL_GTK_LAUNCH='$gtkLaunch'" "$swayRadial/bin/sway-radial" \
      || fail "the wrapper does not set SWAY_RADIAL_GTK_LAUNCH to $gtkLaunch"

    # The three libraries are opened by store path, and the wrapper sets no
    # LD_LIBRARY_PATH, which would change the library lookup of swaymsg.
    for pattern in 'LIBINPUT_SONAME = "/nix/store/' 'LIBUDEV_SONAME = "/nix/store/'; do
      grep -q "$pattern" "$swayRadial/lib/sway-radial/sway_radial/libinput.py" || fail "libinput.py: $pattern"
    done
    grep -q 'CDLL("/nix/store/' "$swayRadial/lib/sway-radial/sway_radial/overlay.py" || fail "overlay.py"
    ! grep -q LD_LIBRARY_PATH "$swayRadial/bin/sway-radial" || fail "the wrapper sets LD_LIBRARY_PATH"

    touch $out
  ''
