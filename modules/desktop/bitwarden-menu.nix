# bitwarden-menu (`bwm`): a keyboard-driven menu to the vault, in fuzzel, beside
# Bitwarden desktop. Off unless ravnix.apps.bitwardenMenu.enable is true, so a
# host decides by its private flake.
# Bitwarden desktop stays the GUI app (apps.nix), and rbw's agent stays the SSH
# agent (modules/common/rbw.nix): this changes neither.
#
# Why it exists next to them: bwm drives the official CLI (`bw`), which sends
# `encryptedFor`, so adding and editing items works against a Vaultwarden of
# 1.37.4 or later, where rbw's `add` and `edit` get HTTP 422 (doy/rbw#385). It
# adds fuzzy search, typing with wtype, TOTP and a timed lock in the menu.
# packages/bitwarden-menu says what the package adds to nixpkgs': `bw` on the
# PATH, and a `wl-copy` that keeps a copied password out of the history.
#
# What this module writes
#   ~/.config/bwm/config.ini   the three personal values (server, mail address,
#                              two-factor type; ravnix.apps.bitwardenMenu) and
#                              public defaults. A file of home-manager is
#                              read-only, which bwm tolerates until it wants to
#                              add a second account to it: add a vault in
#                              me.nix, not in the menu.
#   the launcher               `bitwarden-menu.desktop`, in the package: fuzzel
#                              lists it as "Bitwarden Menu", beside "Bitwarden".
#                              The radial menu's Passwords slot stays Bitwarden
#                              desktop's; bind `bwm` to a key in the Sway
#                              configuration if you want it one stroke away.
#
# The pinentry. bwm asks for the master password, the 2FA code and the client
# secret through the program named by `pinentry`, which it starts without a
# terminal. ravnix ships no pinentry for the desktop: ravnix.rbw.pinentry is the
# curses one, on purpose (a terminal prompt, behind rbw's guard), and the guard
# refuses everything else. So this is pinentry-qt, a Qt 6 program that runs on
# Wayland and follows the qt6ct palette the theme module sets, not the GNOME
# one (pinentry-gnome3, a GTK dialog behind gcr). Without a pinentry bwm would
# ask in fuzzel, which shows what is typed.
#
# The clipboard. A copy carries `x-kde-passwordManagerHint=secret`
# (`wl-copy --sensitive`, from the package's own `wl-copy`), which makes
# `wl-paste --watch cliphist store` (the Sway session's history watcher) skip
# it: wl-clipboard 2.3 passes that as CLIPBOARD_STATE=sensitive and cliphist
# 0.7.0 stores nothing then. tests/desktop/bitwarden-menu-wrapper.nix shows it
# on a real compositor. bwm clears the clipboard 30 seconds after a copy with an
# empty copy, which the same `wl-copy` marks sensitive too (see the package for
# why). cliphist reads CLIPBOARD_STATE, not the MIME type itself, so a copy by
# another route (a browser, the desktop app) is recorded unless it goes through
# wl-copy --sensitive.
#
# --- Style exceptions (docs/style.md, rule 9) ---------------------------------
#   pinentry-qt       a Qt dialog in Fusion style with the qt6ct palette: it has
#                     rounded buttons and a frame the palette does not square.
#   fuzzel            no exception: the menu is the launcher's, in the theme. bwm
#                     knows fuzzel only through the package's patch of menu.py
#                     (packages/bitwarden-menu): it gives every question its prompt
#                     and hides what is typed for secrets.
#
# --- Open, not verified -------------------------------------------------------
#   - Whether bwm shows, types or edits SSH-key items: its README does not say.
#     Bitwarden desktop is for those.
#   - Nothing here ran against a server (no network login in the build); the
#     first run on huginn is the test of the login with the 2FA type.
#   - The popup of pinentry-qt was not seen on screen (Task 3.7).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.apps.bitwardenMenu;

  # The values the user sets, and where; an assertion each, so that the first
  # build names every missing one.
  personal = {
    server = "the address of your Bitwarden or Vaultwarden server";
    email = "the mail address of your vault account";
    twoFactor = "the number of your second factor (0 authenticator app, 1 mail, 3 YubiKey)";
  };
in
{
  config = lib.mkMerge [
    {
      assertions = lib.mapAttrsToList (name: what: {
        assertion = !cfg.enable || cfg.${name} != null;
        message = "ravnix.apps.bitwardenMenu.${name} is not set, but ravnix.apps.bitwardenMenu.enable is true. Set it in me.nix to ${what}, or turn the menu off.";
      }) personal;
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ pkgs.ravnix.bitwarden-menu ];

      home-manager.sharedModules = [
        (
          { config, ... }:
          {
            xdg.configFile."bwm/config.ini".text =
              lib.generators.toINI { mkKeyValue = lib.generators.mkKeyValueDefault { } " = "; }
                (
                  let
                    # What ravnix already sets, as a string, else the trial's values.
                    editor = toString (config.home.sessionVariables.EDITOR or "nvim");
                  in
                  {
                    dmenu = {
                      dmenu_command = "fuzzel --dmenu";
                      pinentry = lib.getExe' pkgs.pinentry-qt "pinentry-qt";
                    };
                    vault = {
                      server_1 = cfg.server;
                      email_1 = cfg.email;
                      twofactor_1 = toString cfg.twoFactor;
                      session_timeout_min = 360;
                      type_library = "wtype";
                      inherit editor;
                      terminal = "ghostty";
                      hide_folders = "Trash";
                    };
                  }
                );
          }
        )
      ];
    })
  ];
}
