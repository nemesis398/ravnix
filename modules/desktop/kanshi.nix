# kanshi, which owns the geometry of the outputs: mode, position and scale of
# each, chosen by the set of outputs that are connected. The layouts are the
# user's (ravnix.laptop.kanshiProfiles); this file writes them in kanshi's
# syntax and adds what every layout needs.
#
# The Sway config starts kanshi (exec_always, restarting it on every reload,
# because a reload resets the outputs to scale 1 and would undo the profile),
# so there is no kanshi service here: a second instance would fight the first
# over the outputs. The Sway config sets no `output ... mode` for the same
# reason.
#
# After a profile applied, kanshi runs one command line: ravnix.desktop.kanshi.exec
# in order (the panel back on the CRTC the console uses, the refresh rate of
# the power profile, the wallpaper redrawn at the new size). kanshi starts each
# exec without waiting, and the three depend on each other's order, so they are
# one script. A command that is not installed is skipped.
#
# The last profile is a fallback the user does not write: any set of outputs no
# profile names (a borrowed projector) is enabled as it comes, and the commands
# still run, so the wallpaper is drawn and the panel is fixed on any display.
# Profiles are matched in file order, so it comes last; the user's own come
# first and win.
{ config, lib, pkgs, ... }:
let
  cfg = config.ravnix.desktop.kanshi;
  profiles = config.ravnix.laptop.kanshiProfiles;

  # `command arguments`, run only when `command` is installed.
  skipMissing =
    command:
    let
      name = lib.head (lib.splitString " " command);
    in
    "if command -v ${lib.escapeShellArg name} >/dev/null 2>&1; then ${command}; fi";

  hook = pkgs.writeShellScript "kanshi-exec" ''
    ${lib.concatMapStringsSep "\n" skipMissing cfg.exec}
  '';

  quote = s: ''"${s}"'';
  # 1.25 and not toString's 1.250000, 2 and not 2.000000.
  number =
    n:
    let
      s = toString n;
    in
    builtins.head (builtins.match "([0-9]+([.][0-9]*[1-9])?)[.]?0*" s);
  output =
    o:
    lib.concatStringsSep " " (
      [
        "output"
        (quote o.criteria)
      ]
      ++ lib.optional (o.status != null) o.status
      ++ lib.optional (o.mode != null) "mode ${o.mode}"
      ++ lib.optional (o.position != null) "position ${o.position}"
      ++ lib.optional (o.scale != null) "scale ${number o.scale}"
    );

  profile = p: ''
    profile ${p.name} {
    ${lib.concatMapStringsSep "\n" (o: "    ${output o}") p.outputs}
        exec ${hook}
    }
  '';

  fallback = ''
    profile ravnix-fallback {
        ...output * enable
        exec ${hook}
    }
  '';
in
{
  assertions = [
    {
      assertion = lib.length (lib.unique (map (p: p.name) profiles)) == lib.length profiles;
      message = "ravnix.laptop.kanshiProfiles names a profile twice; kanshi logs profiles by name, so give each layout its own.";
    }
    {
      assertion = !(lib.elem "ravnix-fallback" (map (p: p.name) profiles));
      message = "ravnix.laptop.kanshiProfiles: \"ravnix-fallback\" is the name of the profile kanshi.nix adds last; pick another.";
    }
  ];

  environment.systemPackages = [ pkgs.kanshi ];

  home-manager.sharedModules = [
    {
      xdg.configFile."kanshi/config".text =
        "# Generated from ravnix.laptop.kanshiProfiles (modules/desktop/kanshi.nix).\n\n"
        + lib.concatMapStringsSep "\n" profile profiles
        + lib.optionalString (profiles != [ ]) "\n"
        + fallback;
    }
  ];
}
