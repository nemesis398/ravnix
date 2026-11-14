# modules/common/dictionary-watch.nix and the adapters of the wrapper
# (modules/common/dictionary.nix), as home-manager evaluates them: the
# service runs the wrapper's sync with home-manager's state directory, the
# path unit watches the dictionary and the list of every adapter that has a
# file, the timer covers the cloud, and ravnix.dictionary.watch = false
# leaves all three out. Which adapters a host gets: the prose skill's
# everywhere, LanguageTool's on the laptop shape, Handy's where the desktop
# installs Handy (checked on a whole laptop host, through the forwarding).
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };
  file = "/home/alice/src/ravnix-private/dictionary.txt";
  plain = (hm [ ]).config;
  laptop = (hm [ { ravnix.shape = "laptop"; } ]).config;
  handy = (hm [ { ravnix.dictionary.adapters.handy = true; } ]).config;
  off = (hm [ { ravnix.dictionary.watch = lib.mkForce false; } ]).config;
  name = "ravnix-dict-sync";
  service = c: c.systemd.user.services.${name} or { };
  path = c: c.systemd.user.paths.${name} or { };
  timer = c: c.systemd.user.timers.${name} or { };
  prose = "/home/alice/.config/prose/dictionary.txt";
  handySettings = "/home/alice/.local/share/com.pais.handy/settings_store.json";

  # The laptop shape as a host builds it (as tests/desktop/apps.nix does):
  # the desktop's Handy and the shape reach home-manager through the
  # forwarding of modules/common/nixos.nix.
  huginn = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../templates/default/me.nix
      {
        system.stateVersion = "26.05";
        warnings = lib.mkForce [ ];
      }
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
    ];
  };
  huginnHome = huginn.config.home-manager.users.${huginn.config.ravnix.user.username};

  failures =
    lib.optional (service plain == { }) "no ${name}.service"
    ++
      lib.optional
        (
          service plain != { }
          &&
            lib.toList (service plain).Service.ExecStart
            != [ "${lib.getExe plain.ravnix.dictionary.package} sync" ]
        )
        "the service does not run the wrapper's sync: ${builtins.toJSON (service plain).Service.ExecStart}"
    ++ lib.optional (
      service plain != { }
      && !(lib.elem "XDG_STATE_HOME=${plain.xdg.stateHome}" (
        lib.toList (service plain).Service.Environment
      ))
    ) "the service does not get home-manager's XDG_STATE_HOME"
    ++ lib.optional (
      service plain != { } && lib.toList (service plain).Service.Type != [ "oneshot" ]
    ) "the service is no oneshot"
    ++ lib.optional (
      lib.toList ((service plain).Unit.ConditionPathExists or null) != [ file ]
    ) "the service runs without a dictionary, and fails"
    ++ lib.optional (
      (path plain).Path.PathChanged or null != [
        file
        prose
      ]
    ) "without Handy, the path unit watches ${builtins.toJSON ((path plain).Path.PathChanged or null)}"
    ++ lib.optional (
      (path handy).Path.PathChanged or null != [
        file
        handySettings
        prose
      ]
    ) "with Handy, the path unit watches ${builtins.toJSON ((path handy).Path.PathChanged or null)}"
    ++ lib.optional (
      (path plain).Install.WantedBy or null != [ "default.target" ]
    ) "the path unit is not started"
    ++ lib.optional (
      lib.toList ((timer plain).Timer.OnUnitInactiveSec or null) != [ "15min" ]
    ) "no timer every 15 minutes"
    ++ lib.optional (
      (timer plain).Install.WantedBy or null != [ "timers.target" ]
    ) "the timer is not started"
    ++ lib.optional (
      service off != { } || path off != { } || timer off != { }
    ) "watch = false still has a unit"
    ++ lib.optional (
      !lib.elem off.ravnix.dictionary.package off.home.packages
    ) "watch = false drops ravnix-dict itself"
    ++ lib.optional (plain.ravnix.dictionary.adapters.languagetool) "LanguageTool is synced off the laptop"
    ++ lib.optional (
      !laptop.ravnix.dictionary.adapters.languagetool
    ) "LanguageTool is not synced on the laptop"
    ++ lib.optional (plain.ravnix.dictionary.adapters.handy) "Handy is synced without the desktop"
    ++ lib.optional (
      !huginnHome.ravnix.dictionary.adapters.handy || !huginnHome.ravnix.dictionary.adapters.languagetool
    ) "huginn's home-manager does not sync Handy and LanguageTool"
    ++ lib.optional (
      !lib.elem huginnHome.ravnix.dictionary.paths.handy ((path huginnHome).Path.PathChanged or [ ])
    ) "huginn's path unit does not watch Handy's store";

  wrapper = c: "${c.ravnix.dictionary.package}/bin/ravnix-dict";
in
pkgs.runCommand "common-dictionary-watch" { nativeBuildInputs = [ pkgs.gnugrep ]; } (
  if failures != [ ] then
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    ''
      fail() { echo "common-dictionary-watch: $*" >&2; exit 1; }
      # The wrapper names the adapters of the host, and where they look.
      grep -q "RAVNIX_DICT_ADAPTERS.*'prose'" ${wrapper plain} || fail "the plain wrapper's adapters: $(grep ADAPTERS ${wrapper plain})"
      grep -q "RAVNIX_DICT_ADAPTERS.*'languagetool,prose'" ${wrapper laptop} || fail "the laptop's adapters: $(grep ADAPTERS ${wrapper laptop})"
      grep -q "RAVNIX_DICT_ADAPTERS.*'handy,prose'" ${wrapper handy} || fail "Handy's adapters: $(grep ADAPTERS ${wrapper handy})"
      grep -qF ${lib.escapeShellArg handySettings} ${wrapper plain} || fail "the wrapper does not name Handy's store"
      grep -qF ${lib.escapeShellArg prose} ${wrapper plain} || fail "the wrapper does not name the prose dictionary"
      # It runs: a sync of the prose adapter alone, against files here.
      export HOME="$PWD/home"
      mkdir -p "$HOME"
      printf 'Huginn\nOpen WebUI\n' >dict.txt
      RAVNIX_DICT_FILE="$PWD/dict.txt" RAVNIX_DICT_PROSE_FILE="$PWD/prose/dictionary.txt" \
        ${wrapper plain} sync >out 2>err || fail "sync failed: $(cat err)"
      grep -qx 'Open WebUI' prose/dictionary.txt || fail "the prose dictionary: $(cat prose/dictionary.txt)"
      touch "$out"
    ''
)
