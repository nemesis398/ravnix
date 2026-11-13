# bitwarden-menu on huginn (modules/desktop/bitwarden-menu.nix, packages/
# bitwarden-menu), the keyboard-driven way to the vault beside Bitwarden desktop.
#
# What an evaluation shows, and a derivation checks without a network:
#
#   - off by default: no package, no config file, no launcher, and no
#     assertion, whatever the personal values are (the template sets them);
#   - on with the three personal values: the wrapped `bwm` is installed, its
#     config.ini is written with every key and parses (Python's configparser,
#     which is what bwm reads it with), the pinentry is a graphical one that
#     exists, and the launcher is a valid .desktop file that starts `bwm`;
#   - on without a value: one failed assertion per missing value, naming the
#     option and saying what to do, and none for the values that are set;
#   - the values are typed: one that would break the INI file or bwm's
#     interpolation (a newline, a space, a percent sign) is refused;
#   - Bitwarden desktop and rbw are unchanged by it.
#
# The wrapper's PATH, and the clipboard, are in bitwarden-menu-wrapper.nix.
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

  mkHost =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ extra;
    };

  values = {
    server = "https://vault.example.org";
    email = "alice@example.org";
    twoFactor = 0;
  };
  setting = v: { ravnix.apps.bitwardenMenu = lib.mapAttrs (_: lib.mkForce) v; };
  on = mkHost [ (setting (values // { enable = true; })) ];
  # Off, with the values set, as the template has it.
  off = mkHost [ (setting (values // { enable = false; })) ];
  # Off, with none of them.
  offBare = mkHost [
    (setting {
      enable = false;
      server = null;
      email = null;
      twoFactor = null;
    })
  ];
  without =
    name:
    mkHost [
      (setting (
        values
        // {
          enable = true;
          ${name} = null;
        }
      ))
    ];
  withoutAll = mkHost [
    (setting {
      enable = true;
      server = null;
      email = null;
      twoFactor = null;
    })
  ];

  userOf = h: h.config.ravnix.user.username;
  hmOf = h: h.config.home-manager.users.${userOf h};
  iniOf = h: (hmOf h).xdg.configFile."bwm/config.ini" or null;
  has = name: h: lib.any (p: lib.getName p == name) h.config.environment.systemPackages;
  failedOf = h: map (a: a.message) (lib.filter (a: !a.assertion) h.config.assertions);
  bwmOf =
    h: lib.findFirst (p: lib.getName p == "bitwarden-menu") null h.config.environment.systemPackages;

  # Whether reading the option throws: the type refuses the value.
  refused =
    value:
    !(builtins.tryEval (
      builtins.deepSeq
        (mkHost [
          {
            ravnix.apps.bitwardenMenu = lib.mapAttrs (_: lib.mkForce) (values // { enable = true; } // value);
          }
        ]).config.ravnix.apps.bitwardenMenu
        true
    )).success;

  named = h: option: lib.any (lib.hasInfix "ravnix.apps.bitwardenMenu.${option}") (failedOf h);

  failures =
    # --- off
    lib.optional (has "bitwarden-menu" off)
      "the menu is installed while ravnix.apps.bitwardenMenu.enable is false"
    ++ lib.optional (has "bitwarden-menu" offBare) "the menu is installed while it is off, with no values"
    ++ lib.optional (iniOf off != null) "bwm/config.ini is written while the menu is off"
    ++ lib.optional (
      failedOf off != [ ]
    ) "the menu is off but an assertion failed: ${toString (failedOf off)}"
    ++ lib.optional (
      failedOf offBare != [ ]
    ) "the menu is off with no values but an assertion failed: ${toString (failedOf offBare)}"
    ++ lib.optional ((mkHost [ ]).config.ravnix.apps.bitwardenMenu.enable
    ) "ravnix.apps.bitwardenMenu.enable is not off by default"
    # --- on
    ++ lib.optional (!has "bitwarden-menu" on) "the menu is not installed with enable = true"
    ++ lib.optional (iniOf on == null) "bwm/config.ini is not written with enable = true"
    ++ lib.optional (
      failedOf on != [ ]
    ) "all values are set but an assertion failed: ${toString (failedOf on)}"
    # Bitwarden desktop and the SSH agent are unchanged.
    ++ lib.optional (
      !has "bitwarden-desktop" on
    ) "Bitwarden desktop is gone from the host with the menu"
    ++ lib.optional (
      !has "bitwarden-desktop" off
    ) "Bitwarden desktop is gone from the host without the menu"
    ++ lib.optional (!(hmOf on).programs.rbw.enable) "rbw is off in the host with the menu"
    ++ lib.optional (
      (hmOf on).programs.rbw.settings != (hmOf off).programs.rbw.settings
    ) "rbw's settings differ between the host with the menu and the one without"
    # --- the assertion
    ++
      lib.concatMap
        (
          name:
          let
            h = without name;
          in
          lib.optional (!named h name)
            "without ${name}, no failed assertion names ravnix.apps.bitwardenMenu.${name}; failed: ${toString (failedOf h)}"
          ++
            lib.optional (lib.length (failedOf h) != 1)
              "only ${name} is missing, but ${toString (lib.length (failedOf h))} assertions failed: ${toString (failedOf h)}"
          ++ lib.optional (
            !lib.all (lib.hasInfix "me.nix") (failedOf h)
          ) "the assertion for ${name} does not say where to set it (me.nix): ${toString (failedOf h)}"
        )
        [
          "server"
          "email"
          "twoFactor"
        ]
    ++ lib.optional (
      lib.length (failedOf withoutAll) != 3
    ) "with no value set, expected 3 failed assertions, got ${toString (failedOf withoutAll)}"
    # --- the types
    ++
      lib.concatMap
        (
          case:
          lib.optional (!refused case.value) "${case.label} is accepted, but would break config.ini or bwm"
        )
        [
          {
            label = "a server with a newline";
            value.server = "https://vault.example.org\n[vault]";
          }
          {
            label = "a server with a space";
            value.server = "https://vault.example.org /x";
          }
          {
            label = "a server with a percent sign (configparser interpolation)";
            value.server = "https://vault.example.org/%2F";
          }
          {
            label = "a server that is no URL";
            value.server = "vault.example.org";
          }
          {
            label = "an empty server";
            value.server = "";
          }
          {
            label = "an email with a newline";
            value.email = "alice@example.org\nx = y";
          }
          {
            label = "an email with a percent sign";
            value.email = "al%ice@example.org";
          }
          {
            label = "an email that is no address";
            value.email = "alice";
          }
          {
            label = "an unknown two-factor type";
            value.twoFactor = 2;
          }
          {
            label = "a negative two-factor type";
            value.twoFactor = -1;
          }
          {
            label = "a two-factor type as a string";
            value.twoFactor = "0";
          }
        ];

  ini =
    if iniOf on == null then pkgs.writeText "none" "" else pkgs.writeText "config.ini" (iniOf on).text;
  expected = builtins.toJSON {
    dmenu = {
      dmenu_command = "fuzzel --dmenu";
    };
    vault = {
      server_1 = values.server;
      email_1 = values.email;
      twofactor_1 = toString values.twoFactor;
      session_timeout_min = "360";
      type_library = "wtype";
      editor = "nvim";
      terminal = "ghostty";
      hide_folders = "Trash";
    };
  };
  package = bwmOf on;
  pinentryPath =
    let
      m = builtins.match ".*pinentry = ([^\n]*).*" (iniOf on).text;
    in
    if m == null then "" else builtins.head m;
in
pkgs.runCommand "desktop-bitwarden-menu"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.desktop-file-utils
      pkgs.gnugrep
    ];
    inherit ini expected pinentryPath;
    package = if package == null then "/nonexistent" else package;
    failures = lib.concatMapStrings (f: "${f}\n") failures;
    passAsFile = [ "failures" ];
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }

    while IFS= read -r line; do
      [ -n "$line" ] && fail "$line"
    done < "$failuresPath"

    # config.ini parses with the parser bwm uses, and holds every key.
    python3 -I - "$ini" "$expected" <<'PY' || fail "config.ini is not what the options say"
    import configparser, json, sys
    conf = configparser.ConfigParser()
    with open(sys.argv[1], encoding="utf-8") as f:
        conf.read_file(f)
    expected = json.loads(sys.argv[2])
    problems = []
    for section, keys in expected.items():
        if not conf.has_section(section):
            problems.append("no section [%s]" % section)
            continue
        for key, want in keys.items():
            got = conf.get(section, key, fallback=None)
            if got != want:
                problems.append("[%s] %s = %r, want %r" % (section, key, got, want))
    # The pinentry is a program: one path, no arguments (bwm runs it without a shell).
    pin = conf.get("dmenu", "pinentry", fallback="")
    if not pin.startswith("/nix/store/") or " " in pin:
        problems.append("[dmenu] pinentry = %r is not one store path" % pin)
    if conf.getint("vault", "session_timeout_min", fallback=0) != 360:
        problems.append("session_timeout_min is not an integer of 360")
    for p in problems:
        print("  " + p)
    sys.exit(1 if problems else 0)
    PY

    # The pinentry exists and is a graphical one: bwm runs it with no terminal.
    [ -x "$pinentryPath" ] || fail "the pinentry $pinentryPath is not an executable"
    case "$pinentryPath" in
      */pinentry-qt) ;;
      *) fail "the pinentry is $pinentryPath, not pinentry-qt: a curses or tty one has no terminal to draw on when bwm starts it from the launcher" ;;
    esac

    # The launcher: valid, and it starts the wrapped binary by name.
    d="$package/share/applications/bitwarden-menu.desktop"
    if [ ! -f "$d" ]; then
      fail "no bitwarden-menu.desktop in the package"
    else
      desktop-file-validate "$d" || fail "bitwarden-menu.desktop is not valid"
      grep -qx 'Exec=bwm' "$d" || fail "the launcher's Exec is not bwm: $(grep '^Exec' "$d")"
      grep -qx 'TryExec=bwm' "$d" || fail "the launcher has no TryExec=bwm"
      grep -qx 'Terminal=false' "$d" || fail "the launcher asks for a terminal"
      grep -q '^Name=' "$d" || fail "the launcher has no name"
      grep -qE '^Name=Bitwarden( |$)' "$d" && ! grep -qx 'Name=Bitwarden' "$d" || fail "the launcher's name does not tell it from Bitwarden desktop's"
    fi
    [ -x "$package/bin/bwm" ] || fail "no bin/bwm in the package"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
