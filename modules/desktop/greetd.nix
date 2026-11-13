# The login screen: greetd with tuigreet on the first virtual console, no
# Plymouth. After the login tuigreet starts Sway, and the session is on its
# own VT; the greeter remembers the last user, shows the time and masks the
# password with asterisks.
#
# THE THEME. tuigreet draws with the 16 colors of the console, so the colors
# are the VT palette (console.colors, below) and tuigreet names them by index.
# The palette follows the terminal's (modules/theme/default.nix) with two
# changes that the console needs: color 0 is the background of the whole
# screen, so it is Base, and color 7 is its default text, so it is Text; and
# color 8, the dim text, is Overlay0 and not Surface2, which is too dark on
# Base to read. The accent is color 13, bright magenta, as in the terminal.
#
#   0 Base   1 Red   2 Green   3 Yellow   4 Blue   5 Pink   6 Teal   7 Text
#   8 Overlay0   9 Red   10 Green   11 Yellow   12 Blue   13 accent   14 Teal
#   15 Subtext1
#
# What tuigreet draws with which: the screen and box are Base, the text and
# the typed input Text, the frame and the title the accent (a floating thing
# has a 1 px accent frame), the prompt the accent, the key hints (F2 and so on)
# Overlay0, the time Subtext1, and the greeting the accent.
#
# THE GREETING is the raven mark as text, as fastfetch prints the NixOS logo:
# assets/ravnix-mark.txt, half blocks made from the one-color mark by
# tests/desktop/helpers/mark-art.py (the check desktop-mark makes it again and
# compares). tuigreet centers each line of the greeting on its own, so every
# line is padded with spaces to the widest, and the art stays one picture.
# The art cannot be in greetd's command: greetd's config parser ends a value
# at the end of its line and takes one plain quoted string, so neither the
# art's newlines nor the double quotes a `"$(cat ...)"` needs get through (the
# TOML writer turns either into a multi-line string, and greetd stops). So the
# command starts with a wrapper that reads the art from its file and runs
# tuigreet with it, and the other flags stay on the command.
#
# EXCEPTIONS (docs/style.md, rule 9). The greeter is a text screen on the
# console: no font choice (it is the console font), no frame width and no
# square-corner rule apply, and the box frame is the console's line drawing.
{ config, lib, pkgs, ... }:
let
  inherit (config.ravnix.theme) palette roles;
  c = hex: lib.removePrefix "#" hex;

  # The VT palette, color 0 to 15.
  colors = [
    roles.canvas
    palette.red
    palette.green
    palette.yellow
    palette.blue
    palette.pink
    palette.teal
    roles.text
    roles.muted
    palette.red
    palette.green
    palette.yellow
    palette.blue
    roles.accent
    palette.teal
    roles.label
  ];

  # tuigreet takes a color by name or by index; an index is exact on the
  # console, and a name it does not know is dropped without a word.
  theme = lib.concatStringsSep ";" [
    "container=0"
    "text=7"
    "time=15"
    "border=13"
    "title=13"
    "greet=13"
    "prompt=13"
    "input=7"
    "action=8"
    "button=13"
  ];

  art = lib.splitString "\n" (lib.removeSuffix "\n" (builtins.readFile ../../assets/ravnix-mark.txt));
  # Columns: stringLength counts bytes, and a half block is three of them.
  columns = line: lib.stringLength (builtins.replaceStrings [ "▀" "▄" "█" ] [ "x" "x" "x" ] line);
  artWidth = lib.foldl' lib.max 0 (map columns art);
  pad = line: line + lib.concatStrings (lib.replicate (artWidth - columns line) " ");
  greeting = pkgs.writeText "ravnix-greeting.txt" (lib.concatMapStringsSep "\n" pad art);
  tuigreet = pkgs.writeShellScript "tuigreet-greeting" ''
    exec ${pkgs.tuigreet}/bin/tuigreet --greeting "$(< ${greeting})" "$@"
  '';

  command = lib.concatStringsSep " " [
    "${tuigreet}"
    "--time"
    "--remember"
    "--asterisks"
    "--cmd sway"
    "--theme ${lib.escapeShellArg theme}"
  ];
in
{
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings.default_session = {
      inherit command;
      user = "greeter";
    };
  };

  # The login unlocks the keyring. Helium keeps its cookie key in the Secret
  # Service (--password-store=gnome-libsecret) and gnome-keyring serves it
  # (apps.nix), but the keyring is encrypted with the login password and opens
  # only when the greeter's PAM stack hands it that password. Without that the
  # keyring stays locked and Helium asks for its password at every start.
  #
  # The unlock goes on the `login` service and not on `greetd`: NixOS's greetd
  # service has no rules of its own, it only includes `login`, so
  # security.pam.services.greetd.enableGnomeKeyring would change nothing.
  # services.gnome.gnome-keyring sets the same option; it is set here as well
  # so that the unlock does not hang on that module staying on.
  security.pam.services.login.enableGnomeKeyring = true;

  # tuigreet remembers the last user and session here.
  systemd.tmpfiles.rules = [ "d /var/cache/tuigreet 0755 greeter greeter -" ];

  console.colors = map c colors;

  # No splash: the screen goes from the boot messages to the greeter.
  boot.plymouth.enable = lib.mkDefault false;
}
