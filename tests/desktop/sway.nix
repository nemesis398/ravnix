# The desktop module of the laptop shape: Sway and what runs on it (Waybar,
# fuzzel, dunst, swaylock, kanshi, greetd with tuigreet), on a host with
# nixosModules.desktop and nothing else of ravnix's: no laptop shape and no
# hardware module.
#
# Three stages, all part of this check:
#
#   static   the generated files, read from the evaluated configuration and
#            built: the Sway config validates with `sway --validate` together
#            with the fragments of config.d (and a bad fragment fails the
#            build), every color in every file is one of the palette and the
#            accent's follows the option, the rows of the style spec's table
#            that belong to this module hold, the generated files pass
#            check-style.sh, and the helper scripts behave on the inputs a
#            laptop gives them and on the ones it does not.
#   widths   GTK lays out every Waybar module with the generated stylesheet and
#            the font of the system, in a headless Sway: a module's width must
#            not depend on its value, and its floor is no wider than needed.
#   vm       the VM boots to tuigreet, logs in through it, Sway answers, Waybar,
#            dunst, kanshi and the clipboard watcher run, the bar is 32 px high
#            in all three modes, a notification shows, no unit failed, and
#            swaylock unlocks.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  # No y and no z: the session types on the de layout of the Sway config, where
  # the two keys swap places, and the VM's keyboard sends the US ones.
  password = "correct horse staple";
  palette = import ../../modules/theme/palette.nix;

  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  hostOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.desktop ] ++ modules;
    };
  mauve = hostOf [ ];
  teal = hostOf [ { ravnix.theme.accent = lib.mkForce "teal"; } ];
  gpu = hostOf [ { ravnix.desktop.gpu.primary = "0000:36:00.0"; } ];
  # huginn as the private flake builds it: the laptop shape (which brings the
  # desktop) and the 16AHP9 module, with the template's values. Not the
  # host-modules stub: the shape has file systems and a boot loader of its own.
  huginnOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        { system.stateVersion = "26.05"; }
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ] ++ modules;
    };
  huginn = huginnOf [ ];
  # The iGPU's bus not given, given as Intel's, given wrongly, and the address set by hand.
  huginnNoIds = huginnOf [ { hardware.nvidia.prime.amdgpuBusId = lib.mkForce ""; } ];
  huginnIntel = huginnOf [
    {
      hardware.nvidia.prime = {
        amdgpuBusId = lib.mkForce "";
        intelBusId = "PCI:0:2:0";
      };
    }
  ];
  huginnBadId = huginnOf [ { hardware.nvidia.prime.amdgpuBusId = lib.mkForce "PCI:300:0:0"; } ];
  huginnByHand = huginnOf [ { ravnix.desktop.gpu.primary = "0000:05:00.0"; } ];
  # The proprietary driver on a host that is not huginn, and PRIME on one
  # that has no bus id.
  nvidiaDesktop = hostOf [ { services.xserver.videoDrivers = [ "nvidia" ]; } ];
  # (host-modules.nix forces `warnings` empty, so a warning is read from a host
  # of its own: the same stub without that line.)
  bareOf =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        me
        {
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
        }
        self.nixosModules.desktop
      ] ++ modules;
    };
  bare = bareOf [ ];
  primeDesktop = bareOf [ { hardware.nvidia.prime.offload.enable = true; } ];
  gpuWarnings = host: lib.filter (w: lib.hasInfix "ravnix.desktop.gpu.primary" w) host.config.warnings;

  # NixOS's bus id (decimal, no domain) to the address udev matches.
  pci = import ../../lib/pci.nix { inherit lib; };
  pciCases = [
    [ "PCI:54:0:0" "0000:36:00.0" ] # the 16AHP9's 780M
    [ "PCI:1:0:0" "0000:01:00.0" ] # its RTX 4050
    [ "PCI:0:2:0" "0000:00:02.0" ]
    [ "PCI:9:0:0" "0000:09:00.0" ]
    [ "PCI:10:0:0" "0000:0a:00.0" ] # a bus above 9: a hex letter, lower case
    [ "PCI:15:0:0" "0000:0f:00.0" ]
    [ "PCI:16:0:0" "0000:10:00.0" ] # above 15: two hex digits
    [ "PCI:58:0:0" "0000:3a:00.0" ]
    [ "PCI:255:0:0" "0000:ff:00.0" ]
    [ "PCI:0:13:1" "0000:00:0d.1" ] # a device above 9
    [ "PCI:0:31:7" "0000:00:1f.7" ] # the highest device and function
    [ "PCI:054:0:0" "0000:36:00.0" ] # a leading zero is still decimal
    [ "pci:54:0:0" "0000:36:00.0" ]
    [ "PCI:256:0:0" null ]
    [ "PCI:0:32:0" null ]
    [ "PCI:0:0:8" null ]
    [ "PCI:a:0:0" null ]
    [ "PCI:54:0" null ]
    [ "PCI:1000:0:0" null ]
    [ "pci@0000:36:00.0" null ]
    [ "" null ]
  ];
  pciWrong = lib.filter (c: pci.fromBusId (lib.elemAt c 0) != lib.elemAt c 1) pciCases;
  pciNotAnAddress = lib.filter (
    c: let got = pci.fromBusId (lib.elemAt c 0); in got != null && builtins.match "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}[.][0-7]" got == null
  ) pciCases;

  # A value of a user that looks like a token (a Bitwarden item, a command).
  atHost = hostOf [
    {
      ravnix.desktop.terminal.main = "ghostty -e sh -c 'echo a@b@c'";
      ravnix.desktop.ask = lib.mkForce {
        url = "https://chat.example.org";
        model = "quick";
        rbwItem = "key@work@x";
      };
    }
  ];
  swayLib = import ../../modules/desktop/sway/lib.nix { inherit lib pkgs; };

  # The template sets ravnix.desktop.ask; a user who leaves it out gets no popup.
  askOff = hostOf [ { ravnix.desktop.ask = lib.mkForce null; } ];
  # What another module does with the seams: a fragment of config.d, and the
  # main terminal of the glue.
  seam = hostOf [
    {
      ravnix.desktop.terminal.main = "ghostty -e herdr --remote alice@198.51.100.20";
      home-manager.sharedModules = [
        {
          xdg.configFile."sway/config.d/60-seam.conf".text = ''
            bindsym $mod+Shift+x exec some-app
            for_window [app_id="some-app"] floating enable
          '';
        }
      ];
    }
  ];
  badFragment = hostOf [
    {
      home-manager.sharedModules = [
        { xdg.configFile."sway/config.d/60-bad.conf".text = "frobnicate everything\n"; }
      ];
    }
  ];
  badToken = hostOf [ { ravnix.desktop.terminal.main = "two\nlines"; } ];

  homeOf = host: host.config.home-manager.users.${user};
  files = host: (homeOf host).xdg.configFile;
  source = host: name: "${(files host).${name}.source}";
  scriptsOf =
    host:
    lib.listToAttrs (
      map (p: lib.nameValuePair p.name "${p}/bin/${p.name}") (
        lib.filter (p: builtins.match "waybar-[a-z]+|sway-volume|sway-wait-sni" p.name != null || p.name == "keep-awake") host.config.environment.systemPackages
      )
    );
  variant = host: {
    sway = source host "sway/config";
    swayLaptop = source host "sway/config.d/50-laptop.conf";
    swaynag = source host "swaynag/config";
    swaylock = source host "swaylock/config";
    waybarStyle = source host "waybar/style.css";
    waybarModules = source host "waybar/modules.jsonc";
    waybarConfig = source host "waybar/config.jsonc";
    waybarFocus = source host "waybar/config-focus.jsonc";
    kanshi = source host "kanshi/config";
    fuzzel = source host "fuzzel/fuzzel.ini";
    dunst = source host "dunst/dunstrc";
    scripts = scriptsOf host;
  };

  args = pkgs.writeText "desktop-sway-args.json" (
    builtins.toJSON {
      inherit palette;
      roles = {
        mauve = mauve.config.ravnix.theme.roles;
        teal = teal.config.ravnix.theme.roles;
      };
      teal.accent = teal.config.ravnix.theme.roles.accent;
      variants = {
        mauve = variant mauve;
        teal = variant teal;
      };
      kanshiProfiles = map (p: p.name) me.ravnix.laptop.kanshiProfiles;
      greeter = {
        command = mauve.config.services.greetd.settings.default_session.command;
        user = mauve.config.services.greetd.settings.default_session.user;
        plymouth = mauve.config.boot.plymouth.enable;
        colors = mauve.config.console.colors;
      };
      gpu = {
        session = gpu.config.programs.sway.extraSessionCommands;
        udev = gpu.config.services.udev.extraRules;
      };
      noGpuSession = mauve.config.programs.sway.extraSessionCommands;
      # huginn: the laptop shape with the 16AHP9 module. Nobody sets
      # ravnix.desktop.gpu.primary; it comes from the PRIME bus id.
      huginn = {
        primary = huginn.config.ravnix.desktop.gpu.primary;
        session = huginn.config.programs.sway.extraSessionCommands;
        udev = huginn.config.services.udev.extraRules;
        extraOptions = huginn.config.programs.sway.extraOptions;
        warnings = gpuWarnings huginn;
      };
      # What other tasks call by name has to be on the session's PATH, which
      # is the system profile: environment.systemPackages.
      installed = map (p: p.name) mauve.config.environment.systemPackages;
      ask = {
        entriesOn = lib.attrNames (homeOf mauve).xdg.desktopEntries;
        entriesOff = lib.attrNames (homeOf askOff).xdg.desktopEntries;
        installedOff = map (p: p.name) askOff.config.environment.systemPackages;
        swayOff = source askOff "sway/config";
      };
    }
  );

  # ── static ──────────────────────────────────────────────────────────────────
  static = pkgs.runCommand "desktop-sway-static" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    PYTHONDONTWRITEBYTECODE=1 python3 -I ${./helpers/static-checks.py} ${args} 2>&1 | tee $out
    test "''${PIPESTATUS[0]}" = 0
  '';

  # The generated files, laid out as a tree whose styling sources the style
  # check judges, below modules/theme/ because they hold hex colors by design
  # (the check for every other place is the gate's own run over the sources).
  styleCheck =
    pkgs.runCommand "desktop-sway-style"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.ripgrep
          pkgs.coreutils
        ];
      }
      ''
        root=$PWD/tree
        mkdir -p $root/scripts $root/docs $root/modules/theme/gen
        cp ${../../scripts/check-style.sh} $root/scripts/check-style.sh
        cp ${../../docs/mermaid-theme.json} $root/docs/mermaid-theme.json
        chmod +x $root/scripts/check-style.sh
        g=$root/modules/theme/gen
        cp ${source mauve "sway/config"} $g/sway-config
        cp ${source mauve "sway/config.d/50-laptop.conf"} $g/50-laptop.conf
        cp ${source mauve "swaynag/config"} $g/swaynag-config
        cp ${source mauve "swaylock/config"} $g/swaylock-config
        cp ${source mauve "waybar/style.css"} $g/style.css
        cp ${source mauve "waybar/modules.jsonc"} $g/modules.jsonc
        cp ${source mauve "waybar/config.jsonc"} $g/config.jsonc
        cp ${source mauve "waybar/config-focus.jsonc"} $g/config-focus.jsonc
        cp ${source mauve "kanshi/config"} $g/kanshi-config
        cp ${source mauve "fuzzel/fuzzel.ini"} $g/fuzzel.ini
        cp ${source mauve "dunst/dunstrc"} $g/dunstrc
        cd $root
        bash scripts/check-style.sh modules | tee $out
        test "''${PIPESTATUS[0]}" = 0
        echo "check-style.sh found nothing in the generated files" | tee -a $out
      '';

  # ── the scripts ─────────────────────────────────────────────────────────────
  scriptTests =
    pkgs.runCommand "desktop-sway-scripts"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gawk
          pkgs.python3
          pkgs.procps
        ];
        scriptList = pkgs.writeText "scripts" (
          lib.concatStringsSep "\n" (lib.mapAttrsToList (n: p: "${n} ${p}") (scriptsOf mauve)) + "\n"
        );
        kanshiConfig = source mauve "kanshi/config";
      }
      (builtins.readFile ./helpers/script-tests.sh);

  # ── widths ──────────────────────────────────────────────────────────────────
  cases = [
    { id = "custom-battery"; texts = [ "󰁹 5%" "󰁹 100%" ]; }
    { id = "custom-peripherals"; texts = [ "󰂃 9%" "󰂃 15% (9)" ]; }
    { id = "custom-powerdraw"; texts = [ "󱐋 --" "󱐋 123W+dGPU" ]; }
    { id = "power-profiles-daemon"; texts = [ "󰾅" "󰓅" ]; }
    { id = "window"; texts = [ "x" (lib.concatStrings (lib.replicate 28 "W")) ]; }
    { id = "custom-clock"; texts = [ "Mon 9:05" "W36 30. September 2026" ]; }
    { id = "custom-idle-inhibit"; texts = [ "󰅶" "󰛊" ]; }
    { id = "custom-idle-pad"; texts = [ " " " " ]; }
    { id = "network"; texts = [ "󰈂 down" "󰖩 ↑ 1023.9MB/s ↓ 1023.9MB/s" ]; }
    { id = "bluetooth"; texts = [ "󰂯" "󰂱" ]; }
    { id = "pulseaudio"; texts = [ "󰖁 5%" "󰕾 100%" ]; }
    { id = "cpu"; texts = [ "󰻠 1%" "󰻠 100%" ]; }
    { id = "temperature"; texts = [ "󰔏 5°C" "󰔏 100°C" ]; classes = [ "cpu" ]; }
    { id = "memory"; texts = [ "󰍛 5%" "󰍛 100%" ]; }
    { id = "custom-gpu"; texts = [ "󰢮 0%" "󰢮 100%" ]; }
    { id = "custom-gputemp"; texts = [ "󱃂 5°C" "󱃂 100°C" ]; }
  ];
  fontsConf = pkgs.writeText "fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
    <fontconfig>
      <dir>${pkgs.nerd-fonts.jetbrains-mono}/share/fonts</dir>
      <cachedir>/build/fontconfig-cache</cachedir>
    </fontconfig>
  '';
  gtkLibs = with pkgs; [
    gtk3
    pango
    harfbuzz
    glib
    gdk-pixbuf
    at-spi2-core
    gobject-introspection
    cairo
  ];
  widths =
    pkgs.runCommand "desktop-sway-widths"
      {
        nativeBuildInputs = [
          pkgs.sway
          pkgs.jq
          (pkgs.python3.withPackages (ps: [ ps.pygobject3 ]))
        ];
        GI_TYPELIB_PATH = lib.makeSearchPath "lib/girepository-1.0" (map lib.getLib gtkLibs);
        LD_LIBRARY_PATH = lib.makeLibraryPath (map lib.getLib gtkLibs);
        cases = builtins.toJSON cases;
        passAsFile = [ "cases" ];
      }
      ''
        export HOME=$PWD/home XDG_RUNTIME_DIR=$PWD/run FONTCONFIG_FILE=${fontsConf}
        mkdir -p $HOME $XDG_RUNTIME_DIR /build/fontconfig-cache
        chmod 700 $XDG_RUNTIME_DIR
        export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
        export DBUS_SESSION_BUS_ADDRESS=/dev/null PYTHONDONTWRITEBYTECODE=1
        cat > sway.conf <<EOF
        exec sh -c 'python3 -I ${./helpers/measure-widths.py} ${source mauve "waybar/style.css"} < $casesPath > $PWD/widths.json 2> $PWD/widths.err; swaymsg exit'
        EOF
        sway -c sway.conf > sway.log 2>&1 || true
        cat widths.err >&2 || true
        test -s widths.json || { cat sway.log >&2; echo "GTK measured nothing" >&2; exit 1; }
        jq . widths.json > $out
        bad=0
        if [ "$(jq '.errors | length' widths.json)" != 0 ]; then
          echo "GTK refuses part of style.css:" >&2; jq -r '.errors[]' widths.json >&2; bad=1
        fi
        for id in $(jq -r 'keys[] | select(. != "errors")' widths.json); do
          narrow=$(jq ".\"$id\".widths[0]" widths.json); wide=$(jq ".\"$id\".widths[1]" widths.json)
          natural=$(jq ".\"$id\".natural[1]" widths.json)
          if [ "$narrow" != "$wide" ]; then
            echo "row Fixed widths: $id is $narrow px wide with its narrowest value and $wide px with its widest" >&2; bad=1
          fi
          if [ $((wide - natural)) -gt 8 ]; then
            echo "row Fixed widths: the floor of $id is $((wide - natural)) px wider than its widest value needs (more than one character)" >&2; bad=1
          fi
        done
        test "$(jq 'keys | length' widths.json)" = ${toString (lib.length cases + 1)} || { echo "not every module was measured" >&2; bad=1; }
        exit $bad
      '';

  # ── a bad fragment must stop the build ──────────────────────────────────────
  badFragmentFails = pkgs.testers.testBuildFailure (homeOf badFragment).xdg.configFile."sway/config".source;
  seamConfig = (files seam)."sway/config".source;

  # ── udev accepts the rule that links the GPU ────────────────────────────────
  udevRules = pkgs.runCommand "desktop-sway-udev" { nativeBuildInputs = [ pkgs.systemd ]; } ''
    cp ${pkgs.writeText "99-local.rules" gpu.config.services.udev.extraRules} 99-local.rules
    udevadm verify --no-style 99-local.rules | tee $out
  '';

  # What the module refuses, and what it takes, decided by evaluation alone.
  refused =
    host: lib.any (a: !a.assertion) host.config.assertions;
  evaluates = expr: (builtins.tryEval (builtins.deepSeq expr expr)).success;
  equals = expr: want: evaluates expr && expr == want;
  failures =
    map (c: "pci.fromBusId \"${lib.elemAt c 0}\" is \"${toString (pci.fromBusId (lib.elemAt c 0))}\", not \"${toString (lib.elemAt c 1)}\"") pciWrong
    ++ map (c: "pci.fromBusId \"${lib.elemAt c 0}\" is no address udev matches") pciNotAnAddress
    # The tokens of a data file are filled, and only they are checked: what a
    # user's value holds is the user's.
    ++ lib.optional (!equals (swayLib.fill { a = "x@word@y"; } "v=@a@") "v=x@word@y") "fill refuses, or changes, a value that holds @word@"
    ++ lib.optional (!equals (swayLib.fill {
      a = "@b@";
      b = "B";
    } "@a@") "@b@") "fill fills again a token that a value brought in, or throws on it"
    ++ lib.optional (evaluates (swayLib.fill { a = "x"; } "v=@a@ @typo@")) "fill accepts a token of the file that nobody gives"
    ++ lib.optional (!evaluates ((files atHost)."sway/config".source.drvPath)) "a terminal command with @b@ in it makes the Sway config throw"
    ++ lib.optional (!evaluates (map (p: p.drvPath) (lib.filter (p: p.name == "sway-ask") atHost.config.environment.systemPackages))) "a Bitwarden item with @work@ in it makes the sway-ask script throw"
    # GPU: where the address comes from.
    ++ lib.optional (huginn.config.ravnix.desktop.gpu.primary != "0000:36:00.0") "huginn: gpu.primary is not taken from amdgpuBusId PCI:54:0:0 (it is ${toString huginn.config.ravnix.desktop.gpu.primary})"
    ++ lib.optional (gpuWarnings huginn != [ ]) "huginn: the GPU warning is shown though the address is known"
    ++ lib.optional (huginnIntel.config.ravnix.desktop.gpu.primary != "0000:00:02.0") "gpu.primary is not taken from intelBusId when there is no amdgpuBusId"
    ++ lib.optional (huginnNoIds.config.ravnix.desktop.gpu.primary != null) "gpu.primary is set without a bus id"
    ++ lib.optional (gpuWarnings huginnNoIds == [ ]) "PRIME is on and gpu.primary is null, and nothing warns"
    ++ lib.optional (huginnBadId.config.ravnix.desktop.gpu.primary != null || gpuWarnings huginnBadId == [ ]) "a bus id out of range is taken or not warned about"
    ++ lib.optional (huginnByHand.config.ravnix.desktop.gpu.primary != "0000:05:00.0") "a gpu.primary set by hand does not win over the bus id"
    ++ lib.optional (gpuWarnings primeDesktop == [ ]) "PRIME on with no bus id on the desktop host warns of nothing"
    ++ lib.optional (gpuWarnings bare != [ ]) "a host without PRIME is warned about the GPU"
    # --unsupported-gpu: with the proprietary driver and only then.
    ++ lib.optional (huginn.config.programs.sway.extraOptions != [ "--unsupported-gpu" ]) "huginn (driver nvidia) does not start Sway with --unsupported-gpu"
    ++ lib.optional (nvidiaDesktop.config.programs.sway.extraOptions != [ "--unsupported-gpu" ]) "a host with the nvidia driver does not start Sway with --unsupported-gpu"
    ++ lib.optional (mauve.config.programs.sway.extraOptions != [ ]) "a host without the nvidia driver starts Sway with ${toString mauve.config.programs.sway.extraOptions}"
    ++ lib.optional (!mauve.config.programs.sway.enable) "programs.sway is not enabled"
    ++ lib.optional (!mauve.config.services.greetd.enable) "greetd is not enabled"
    ++ lib.optional (!(homeOf mauve).services.dunst.enable) "dunst is not enabled"
    ++ lib.optional (
      !(files mauve) ? "systemd/user/graphical-session.target.wants/dunst.service"
    ) "dunst is not linked into graphical-session.target.wants, so nothing starts it (dbus-broker refuses its D-Bus service file)"
    ++ lib.optional (!(homeOf mauve).programs.fuzzel.enable) "fuzzel is not enabled"
    ++ lib.optional (!(homeOf mauve).programs.swaylock.enable) "swaylock is not enabled"
    ++ lib.optional (!mauve.config.security.pam.services ? swaylock) "swaylock has no PAM service"
    ++ lib.optional mauve.config.boot.plymouth.enable "Plymouth is on"
    ++ lib.optional (lib.length mauve.config.console.colors != 16) "console.colors is not the 16 colors of the console"
    ++ lib.optional (refused mauve) "the default host is refused by an assertion"
    ++ lib.optional (!refused badToken) "a main terminal command with a line break is not refused"
    ++ lib.optional (
      !refused (hostOf [
        {
          ravnix.desktop.workspaceOutputs = [
            {
              number = 1;
              outputs = [ "a" ];
            }
            {
              number = 1;
              outputs = [ "b" ];
            }
          ];
        }
      ])
    ) "a workspace listed twice is not refused"
    ++ lib.optional (evaluates
      (hostOf [
        {
          ravnix.desktop.workspaceOutputs = [
            {
              number = 1;
              outputs = [ "a\"b" ];
            }
          ];
        }
      ]).config.ravnix.desktop.workspaceOutputs
    ) "a quote in a workspace output is accepted, and would end the quoted name in the Sway config"
    ++ lib.optional (evaluates
      (hostOf [
        {
          ravnix.desktop.workspaceOutputs = [
            {
              number = 11;
              outputs = [ "a" ];
            }
          ];
        }
      ]).config.ravnix.desktop.workspaceOutputs
    ) "workspace 11 is accepted, though the bar shows ten"
    ++ lib.optional (!refused (hostOf [
      {
        ravnix.laptop.kanshiProfiles = [
          {
            name = "ravnix-fallback";
            outputs = [ { criteria = "eDP-1"; } ];
          }
        ];
      }
    ])) "a profile named like the fallback is not refused"
    ++ lib.optional (!refused (hostOf [
      {
        ravnix.laptop.kanshiProfiles = [
          {
            name = "a";
            outputs = [ { criteria = "eDP-1"; } ];
          }
          {
            name = "a";
            outputs = [ { criteria = "DP-1"; } ];
          }
        ];
      }
    ])) "a kanshi profile listed twice is not refused";

  # What evaluation alone decides (the list above), as a stage of its own so
  # that it builds without the VM.
  evalChecks = pkgs.runCommand "desktop-sway-eval" { } ''
    ${lib.concatMapStrings (f: "echo ${lib.escapeShellArg ("FAIL " + f)} >&2\n") failures}
    ${lib.optionalString (failures != [ ]) "exit 1"}
    echo "${toString (lib.length pciCases)} bus ids, the GPU defaults and the Sway options as expected" > $out
  '';

  # The main terminal seam reaches the Sway config, and the fragment of another
  # module is part of what `sway --validate` accepted (the build of seamConfig
  # fails otherwise).
  # The flag is in the Sway that greetd starts (the wrapper binary), when the
  # nvidia driver is loaded, and only then.
  unsupportedGpu = pkgs.runCommand "desktop-sway-unsupported-gpu" { } ''
    grep -aqF -- '--unsupported-gpu' ${huginn.config.programs.sway.package}/bin/sway \
      || { echo "huginn's sway wrapper does not pass --unsupported-gpu" >&2; exit 1; }
    if grep -aqF -- '--unsupported-gpu' ${mauve.config.programs.sway.package}/bin/sway; then
      echo "a host without the nvidia driver starts Sway with --unsupported-gpu" >&2
      exit 1
    fi
    echo "--unsupported-gpu is passed with the nvidia driver and not without" > $out
  '';

  seamCheck = pkgs.runCommand "desktop-sway-seam" { } ''
    grep -qxF 'set $work ghostty -e herdr --remote alice@198.51.100.20' ${seamConfig}
    echo "the seam reaches the Sway config" > $out
  '';

  # ── the VM ──────────────────────────────────────────────────────────────────
  # Slot 0x10 of the root bus of the node (a q35 machine: pcie.0), which the qemu option below pins.
  gpuAddress = "0000:00:10.0";
  vm = pkgs.testers.runNixOSTest {
    name = "desktop-sway";

    nodes.machine =
      { ... }:
      {
        imports = [
          self.nixosModules.desktop
          ../../templates/default/me.nix
        ];
        warnings = lib.mkForce [ ];
        system.stateVersion = "26.05";

        users.users.${user}.password = password;

        # Software rendering only here, in the test node: the VM has no GPU
        # Sway can use. Hardware rendering is the laptop's and is not touched.
        environment.sessionVariables = {
          WLR_RENDERER = "pixman";
          WLR_NO_HARDWARE_CURSORS = "1";
        };
        # The node's only GPU, at a fixed slot, is the one Sway is told to use:
        # the udev rule has to link it, and the wlroots that starts under
        # WLR_DRM_DEVICES=/dev/dri/primary-gpu has to find it there.
        ravnix.desktop.gpu.primary = "${gpuAddress}";
        # A variable of home-manager's, to see in a process that Sway starts.
        home-manager.sharedModules = [ { home.sessionVariables.RAVNIX_TEST_HM_VAR = "from-home-manager"; } ];
        virtualisation = {
          qemu.options = [ "-vga none -device virtio-gpu-pci,bus=pcie.0,addr=0x10" ];
          memorySize = 3072;
          cores = 2;
        };

        environment.systemPackages = [ pkgs.grim ];
      };

    testScript = ''
      USER = "${user}"
      PASSWORD = "${password}"
      BASE = "${palette.base}"
      MANTLE = "${palette.mantle}"
      ACCENT = "${mauve.config.ravnix.theme.roles.accent}"
      GPU_ADDRESS = "${gpuAddress}"
    '' + builtins.readFile ./helpers/vm-test.py;
  };
in
pkgs.runCommand "desktop-sway"
  {
    # The stages are attributes too, so that one can be built alone:
    # nix build .#checks.SYSTEM.desktop-sway.widths
    passthru = {
      inherit
        evalChecks
        static
        styleCheck
        scriptTests
        widths
        udevRules
        seamCheck
        unsupportedGpu
        badFragmentFails
        vm
        ;
    };
  }
  ''
  cat ${evalChecks} ${static} ${styleCheck} ${scriptTests} ${widths} ${udevRules} ${seamCheck} ${unsupportedGpu} > $out
  grep -q "frobnicate" ${badFragmentFails}/testBuildFailure.log || {
    echo "the build of a Sway config with a bad fragment did not fail because of the fragment" >&2
    exit 1
  }
  : ${vm}
''
