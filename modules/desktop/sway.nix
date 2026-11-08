# Sway, for NixOS and the user's home-manager configuration: the compositor
# (programs.sway), the session environment, the ported config
# (modules/desktop/sway/config) with the theme in it, the helper scripts the
# config calls, and the user services that belong to the session.
#
#   NixOS         programs.sway, the session environment, the GPU path, the
#                 helper scripts as packages, sway-game-mode as a user service
#   home-manager  ~/.config/sway/config and config.d/, the xkb files, the
#                 fuzzel launcher, dunst, ghostty, GTK and Qt, the session
#                 environment of systemd user units
#
# The config is a template (sway/config): this file replaces its @tokens@, and
# the build runs `sway --validate` over it together with every fragment of
# config.d before it is installed, so a broken line fails the build of the
# host, never the session.
#
# SEAMS for the other modules, none of which needs an edit of this file:
#
#   Sway bits (bindings, window rules, exec lines)
#       Put a file in config.d from the home-manager configuration:
#
#         home-manager.sharedModules = [ {
#           xdg.configFile."sway/config.d/60-apps.conf".text = ''
#             bindsym $mod+Shift+x exec some-app
#           '';
#         } ];
#
#       Every ~/.config/sway/config.d/*.conf is included at the end of the
#       config, in the order of the names (this module's own is 50-laptop.conf;
#       use 60 and above, so a later file can override a binding with
#       unbindsym). The build validates it with the rest. The variables of the
#       config ($mod, $term, $float, $accent, $base, ...) are in scope.
#
#   The main terminal key ($mod+Return), Task 5.2
#       ravnix.desktop.terminal.main is the command (modules/options/
#       desktop.nix). Set it from a NixOS module of the glue; the key, the
#       session layout's terminal on workspace 2 and nothing else read it.
#       ravnix.desktop.terminal.plain is the second key ($mod+Alt+Return).
#
#   A kanshi hook   ravnix.desktop.kanshi.exec (kanshi.nix)
#   The GPU          ravnix.desktop.gpu.primary, taken from the PRIME bus id
#                    of the hardware module (modules/options/desktop.nix);
#                    --unsupported-gpu is added when the nvidia driver is
#                    loaded (below)
#
# EXCEPTIONS (docs/style.md, rule 9). None for Sway itself. swaynag follows the
# style (swaynag/config below). The GTK and Qt exceptions are in the theme
# module (gtk-qt.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  cfg = config.ravnix.desktop;
  inherit (config.ravnix.theme)
    palette
    roles
    accent
    font
    fontSize
    ;
  swayPackage = config.programs.sway.package;
  helpers = import ./sway/lib.nix { inherit lib pkgs; };
  inherit (helpers) fill;

  # ── the helper scripts, as packages ─────────────────────────────────────────
  # Tools of the session that the scripts call come from the PATH of the
  # session, not from here, when another module provides them: wtype and
  # ghostty-float (Task 3.3 and below), lock-screen and backdrop (Task 3.8),
  # energy, charge-mode and panel-crtc (Task 3.4), btop-auto and
  # magic-trackpad-battery (Task 3.2b), nord (Task 3.6), handy-ptt and
  # obsidian-open-daily (Task 3.3). A script checks for the optional ones.
  opaque = hex: "${lib.removePrefix "#" hex}ff";
  bin = ./sway/bin;
  bash = name: runtimeInputs: tokens: helpers.bash { inherit name runtimeInputs tokens; src = bin + "/${name}"; };

  # flake8 runs on the Python scripts at build time. They were written for a
  # wide editor (E501, the line length) and break a line before a binary
  # operator (W503; W503 and W504 contradict each other, and flake8 ignores
  # both by default, which an explicit list replaces).
  pyIgnore = [
    "E501"
    "W503"
    "W504"
  ];

  prime = config.hardware.nvidia.prime;
  primeOn = prime.offload.enable || prime.sync.enable || prime.reverseSync.enable;
  # sway refuses the proprietary driver with a red bar at every login unless
  # told it is understood (sway 1.12 checks for nvidia-drm).
  nvidiaDriver = lib.elem "nvidia" config.services.xserver.videoDrivers;

  askEnabled = cfg.ask != null;
  askHost = lib.head (lib.splitString "/" (lib.removePrefix "https://" (lib.removePrefix "http://" cfg.ask.url)));

  scripts =
    with pkgs;
    {
      ghostty-float = bash "ghostty-float" [ ghostty ] { };
      keep-awake = bash "keep-awake" [
        swayidle
        swaylock
        procps
        coreutils
        util-linux
        swayPackage
      ] { };
      output-wake = bash "output-wake" [
        util-linux
        jq
        coreutils
        swayPackage
      ] { };
      sway-clipboard = bash "sway-clipboard" [
        cliphist
        fuzzel
        wl-clipboard
        gawk
        libnotify
        coreutils
        findutils
        gnugrep
      ] { };
      sway-keybindings = bash "sway-keybindings" [
        gawk
        coreutils
        libnotify
        fuzzel
        less
      ] { };
      sway-mouse = bash "sway-mouse" [
        swayPackage
        jq
        systemd
        fuzzel
        coreutils
      ] { };
      sway-move-workspace = bash "sway-move-workspace" [
        swayPackage
        jq
      ] { };
      sway-nightlight = bash "sway-nightlight" [
        procps
        libnotify
        coreutils
      ] { };
      sway-powermenu = bash "sway-powermenu" [
        fuzzel
        systemd
        swayPackage
      ] { };
      sway-present = bash "sway-present" [
        util-linux
        jq
        swayPackage
        coreutils
      ] { };
      sway-scratchpad-toggle = bash "sway-scratchpad-toggle" [
        swayPackage
        jq
      ] { };
      sway-settings = bash "sway-settings" [
        swayPackage
        jq
        fuzzel
        pulseaudio
        libnotify
        dunst
        procps
        wl-mirror
        gawk
        coreutils
        gnused
      ] { };
      sway-volume = bash "sway-volume" [
        pulseaudio
        libnotify
        coreutils
      ] { };
      sway-wait-sni = bash "sway-wait-sni" [
        systemd
        coreutils
      ] { };

      # Python, unchanged but for the tokens, and unchecked by flake8 only for
      # the rules the original code does not meet (the line length, mostly:
      # the scripts were written for a wide editor).
      sway-calc = helpers.python {
        name = "sway-calc";
        src = bin + "/sway-calc";
        flakeIgnore = pyIgnore;
      };
      sway-session-layout = helpers.python {
        name = "sway-session-layout";
        src = bin + "/sway-session-layout";
        flakeIgnore = pyIgnore;
      };
      sway-game-mode = helpers.python {
        name = "sway-game-mode";
        src = bin + "/sway-game-mode";
        flakeIgnore = pyIgnore;
      };
    }
    // lib.optionalAttrs askEnabled {
      sway-ask = helpers.python {
        name = "sway-ask";
        src = bin + "/sway-ask";
        tokens = {
          askUrl = lib.removeSuffix "/" cfg.ask.url;
          askModel = cfg.ask.model;
          askRbwItem = cfg.ask.rbwItem;
          askWebappPrefix = "chrome-${askHost}__";
          baseOpaque = opaque roles.canvas;
          textOpaque = opaque roles.text;
        };
        flakeIgnore = pyIgnore;
      };
    };

  # ── the config ──────────────────────────────────────────────────────────────
  quote = s: ''"${s}"'';
  paletteBlock = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: hex: "set \$${name} ${hex}") palette ++ [ "set $accent ${roles.accent}" ]
  );
  workspaceBlock = lib.concatMapStringsSep "\n" (
    w: "workspace ${toString w.number} output ${lib.concatMapStringsSep " " quote w.outputs}"
  ) cfg.workspaceOutputs;

  swayConfig = fill {
    palette = paletteBlock;
    cursorTheme = "catppuccin-mocha-${accent}-cursors";
    inherit font;
    fontSize = toString fontSize.terminal;
    terminalMain = cfg.terminal.main;
    terminalPlain = cfg.terminal.plain;
    workspaceOutputs = workspaceBlock;
    polkitAgent = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
    askBinding =
      if askEnabled then
        "bindsym $mod+Shift+a      exec $ask"
      else
        "# $mod+Shift+a is free: ravnix.desktop.ask is not set, so there is no AI popup.";
  } (builtins.readFile ./sway/config);

  laptopFragment = fill { } (builtins.readFile ./sway/50-laptop.conf);

  # swaynag, the bar that shows a config error: styled like the rest (Base, a
  # 1 px accent frame, Text; a warning is Peach and an error Red, the state
  # colors; buttons are a Surface0 wash framed in the accent). It had no look
  # on the old setup, so this is new, from the style checklist.
  nag = lib.removePrefix "#";
  frame = toString config.ravnix.theme.lineWidth.frame;
  swaynagConfig = ''
    font=${font} ${toString fontSize.launcher}
    background=${nag roles.canvas}
    text=${nag roles.text}
    border=${nag roles.accent}
    border-bottom=${nag roles.accent}
    border-bottom-size=${frame}
    button-background=${nag roles.wash}
    button-text=${nag roles.text}
    button-border-size=${frame}
    details-background=${nag roles.canvas}
    details-border-size=${frame}

    [warning]
    border=${nag palette.peach}
    border-bottom=${nag palette.peach}

    [error]
    border=${nag palette.red}
    border-bottom=${nag palette.red}
  '';

  # The sway config of the system's sway, checked once with every fragment.
  checkedConfig =
    {
      fragments,
      xkb,
    }:
    pkgs.runCommand "sway-config"
      {
        nativeBuildInputs = [ swayPackage ];
        config = pkgs.writeText "sway-config" swayConfig;
      }
      ''
        export HOME=$TMPDIR/home XDG_RUNTIME_DIR=$TMPDIR/run
        export XDG_CONFIG_HOME=$HOME/.config
        mkdir -p $HOME/.config/sway/config.d $XDG_RUNTIME_DIR
        chmod 700 $XDG_RUNTIME_DIR
        cp -r ${xkb}/. $HOME/.config/xkb
        ${lib.concatStrings (
          lib.mapAttrsToList (
            name: file: "cp ${file} $HOME/.config/sway/config.d/${baseNameOf name}\n"
          ) fragments
        )}
        # The wrapper starts a D-Bus session unless told there is one; the
        # headless backend needs no seat, no GPU and no input device.
        export DBUS_SESSION_BUS_ADDRESS=/dev/null
        export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
        # --validate exits non-zero for an error in the main file, but an
        # error in an included file (every fragment of config.d) is only
        # logged, so the log is read as well: any error the parser reports
        # fails the build.
        status=0
        sway --validate -c $config 2>err.log || status=$?
        if [ $status != 0 ] || grep -q '\[sway/config.c:[0-9]*\] Error on line\|\[sway/config.c:[0-9]*\] Failed to' err.log; then
          cat err.log >&2
          echo "sway --validate refused the config (with config.d: ${
            lib.concatStringsSep ", " (map baseNameOf (lib.attrNames fragments))
          })" >&2
          exit 1
        fi
        # Unknown RMLVO options are only a warning of xkbcommon, but a custom
        # option that is missing from the xkb files would silently do nothing.
        if grep -q 'Unrecognized RMLVO option' err.log; then
          cat err.log >&2
          echo "the xkb files lack an option the config uses" >&2
          exit 1
        fi
        cp $config $out
      '';
in
{
  config = {
    assertions = [
      {
        assertion = !(lib.hasInfix "\n" cfg.terminal.main) && !(lib.hasInfix "\n" cfg.terminal.plain);
        message = "ravnix.desktop.terminal.main and .plain are one line each: they are written into the Sway config as `set $work ...`.";
      }
      {
        assertion =
          let
            numbers = map (w: w.number) cfg.workspaceOutputs;
          in
          lib.length numbers == lib.length (lib.unique numbers);
        message = "ravnix.desktop.workspaceOutputs names a workspace twice; Sway would keep the last, so list each workspace once.";
      }
    ];

    warnings = lib.optional (primeOn && cfg.gpu.primary == null) ''
      NVIDIA PRIME is on and ravnix.desktop.gpu.primary is null: Sway will open
      every GPU, the NVIDIA one included, and the card cannot power off while
      it is open. The address is taken from hardware.nvidia.prime.amdgpuBusId
      (or intelBusId) when that is set to the form PCI:bus:device:function
      (decimal, e.g. PCI:54:0:0). Set it there, or set
      ravnix.desktop.gpu.primary to the integrated GPU's address from
      `lspci -D` (e.g. 0000:36:00.0).
    '';

    # ── the compositor ────────────────────────────────────────────────────────
    programs.sway = {
      enable = true;
      # GTK applications find their settings and schemas.
      wrapperFeatures.gtk = true;
      # What the old setup ran Sway with, minus the apps the design drops
      # (foot): brightness and screenshot tools, the PulseAudio client, the idle
      # and lock tools. The rest of the session's tools are below.
      extraPackages = with pkgs; [
        brightnessctl
        grim
        pulseaudio
        swayidle
        swaylock
      ];
      # Sway refuses the proprietary NVIDIA driver unless it is told to go on
      # ("Proprietary GPU drivers are not supported by sway. Do not report
      # issues."): a red swaynag bar at every login. Fedora's setup passes the
      # same flag and its notes call it a red line.
      extraOptions = lib.optional nvidiaDriver "--unsupported-gpu";
      extraSessionCommands = ''
        # home-manager's session variables (QT_QPA_PLATFORMTHEME, QT_PLUGIN_PATH,
        # XCURSOR_*, ...) for the processes Sway starts: the launcher and the
        # keys. systemd units get theirs from environment.d, which these are
        # not in. greetd runs the session through the user's shell, which has
        # them only if its profile reads the file (home-manager's bash writes
        # that line, another shell does not), so the session reads the file
        # itself; it is guarded against a second reading. A fresh install has
        # no such file before the first activation.
        hm_vars="/etc/profiles/per-user/''${USER:-$(id -un)}/etc/profile.d/hm-session-vars.sh"
        if [ -r "$hm_vars" ]; then
          . "$hm_vars"
        fi
        unset hm_vars
        # Wayland where an application can choose; Qt falls back to X11.
        export QT_QPA_PLATFORM="wayland;xcb"
        export ELECTRON_OZONE_PLATFORM_HINT=auto
        export _JAVA_AWT_WM_NONREPARENTING=1
        # The cursor of the session, the same as home-manager's and the config's
        # `seat * xcursor_theme`; set here too for a host without the file.
        export XCURSOR_THEME=catppuccin-mocha-${accent}-cursors
        export XCURSOR_SIZE=24
        ${lib.optionalString (cfg.gpu.primary != null) ''
          # Render on the GPU every connector hangs off. wlroots splits this
          # variable at every colon, so the path must have none, and the
          # names that spell out a PCI address are full of them (gpu.primary).
          export WLR_DRM_DEVICES=/dev/dri/primary-gpu
        ''}
      '';
    };

    # A stable, colon-free path for the primary GPU, matched by its PCI
    # address so that a renumbered cardN cannot break it.
    services.udev.extraRules = lib.mkIf (cfg.gpu.primary != null) ''
      SUBSYSTEM=="drm", KERNEL=="card[0-9]*", KERNELS=="${cfg.gpu.primary}", SYMLINK+="dri/primary-gpu"
    '';

    # The tools the config, the bar and the scripts call, on every user's PATH.
    environment.systemPackages =
      lib.attrValues scripts
      ++ (with pkgs; [
        cliphist
        kanshi
        playerctl
        libnotify
        slurp
        sway-contrib.grimshot
        swaybg
        wl-clipboard
        wl-mirror
        wlsunset
        xdg-user-dirs
        jq
        gawk
        lxqt.lxqt-policykit
      ]);

    # The accent of the session is a user's choice, so the cursor theme the
    # config names must be installed with it; gtk-qt.nix does that for the
    # accent of ravnix.theme.

    # sway-game-mode holds Sway in mode "game" while a game has focus, so the
    # mouse's side buttons and the gesture keys reach the game. A unit of the
    # session: it starts with sway-session.target, which NixOS's programs.sway
    # defines, and restarts when Sway's socket is not there yet.
    systemd.user.services.sway-game-mode = {
      description = ''Sway mode "game" while a game window has focus'';
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "sway-session.target" ];
      path = [ swayPackage ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${scripts.sway-game-mode}/bin/sway-game-mode";
        # After a crash the script's own SIGTERM handler never ran: leave
        # "game" here (mode default, cursor hiding back on), so the mouse
        # buttons are never stuck unbound without the watcher.
        ExecStopPost = "${scripts.sway-game-mode}/bin/sway-game-mode --leave";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };

    # ── the user's side ───────────────────────────────────────────────────────
    home-manager.sharedModules = [
      (
        { config, ... }:
        let
          fragments = lib.mapAttrs (_: f: f.source) (
            lib.filterAttrs (
              name: _: lib.hasPrefix "sway/config.d/" name && lib.hasSuffix ".conf" name
            ) config.xdg.configFile
          );
          xkbFiles = pkgs.runCommand "xkb-custom" { } ''
            mkdir -p $out/symbols $out/rules
            cp ${./sway/xkb/symbols/custom} $out/symbols/custom
            cp ${./sway/xkb/rules/evdev} $out/rules/evdev
          '';
        in
        {
          xdg.configFile = {
            "sway/config" = {
              source = checkedConfig {
                inherit fragments;
                xkb = xkbFiles;
              };
              # Reload a running Sway when the config changed.
              onChange = ''
                swaySocket="''${XDG_RUNTIME_DIR:-/run/user/$UID}/sway-ipc.$UID.$(${pkgs.procps}/bin/pgrep --uid $UID -x sway || true).sock"
                if [ -S "$swaySocket" ]; then
                  ${swayPackage}/bin/swaymsg -s "$swaySocket" reload || true
                fi
              '';
            };
            "sway/config.d/50-laptop.conf".text = laptopFragment;
            "swaynag/config".text = swaynagConfig;
            "xkb/symbols/custom".source = ./sway/xkb/symbols/custom;
            "xkb/rules/evdev".source = ./sway/xkb/rules/evdev;
          };

          # The styled programs: their settings come from the theme module,
          # and apply when they are enabled (fuzzel, dunst, swaylock and Waybar
          # in their own files). GTK and Qt carry the cursor, the icons and the
          # fonts (gtk-qt.nix).
          programs.ghostty.enable = true;
          gtk.enable = true;
          qt.enable = true;

          # The environment of the systemd user units (environment.d), so the
          # tray apps the XDG autostart starts see what the session sees.
          systemd.user.sessionVariables = {
            # The Bitwarden desktop app's SSH agent.
            SSH_AUTH_SOCK = "\${HOME}/.bitwarden-ssh-agent.sock";
            # GTK 4 on Sway sends keys through the text-input protocol, which
            # does no Compose handling; the built-in "simple" context does.
            # Drop it if an input method framework is ever installed.
            GTK_IM_MODULE = "simple";
          };

          # The launcher entries of the two fuzzel popups, so both are findable
          # by name in the launcher as well as on their key. The Exec is
          # absolute, because fuzzel's PATH can differ from the shell's, and has
          # no field codes, which fuzzel drops.
          xdg.desktopEntries =
            {
              sway-calc = {
                name = "Calculator";
                genericName = "Calculator";
                comment = "Calculator popup in fuzzel; understands percent, ans and a history";
                exec = "${scripts.sway-calc}/bin/sway-calc";
                icon = "accessories-calculator";
                terminal = false;
                categories = [ "Utility" ];
                settings.Keywords = "calc;calculator;math;percent;";
              };
            }
            // lib.optionalAttrs askEnabled {
              sway-ask = {
                name = "AI Chat";
                genericName = "AI Assistant";
                comment = "Quick AI question as a fuzzel popup; the key comes from Bitwarden at runtime";
                exec = "${scripts.sway-ask}/bin/sway-ask";
                icon = "internet-chat";
                terminal = false;
                categories = [ "Utility" ];
                settings.Keywords = "ai;chat;ask;assistant;llm;";
              };
            };
        }
      )
    ];
  };
}
