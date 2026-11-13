# bitwarden-menu (`bwm`, nixpkgs has it) with what it needs on its PATH, and
# its launcher. `modules/desktop/bitwarden-menu.nix` installs it.
#
# nixpkgs' package has no `bw` in its closure, though bwm runs the official CLI
# for everything it does; installed alone it fails at the first step. The
# wrapper puts these in front of the caller's PATH:
#
#   bw          bitwarden-cli, which sends `encryptedFor` (rbw's add and edit get
#               HTTP 422 from Vaultwarden 1.37.4 and later)
#   wtype       the type library of config.ini
#   fuzzel      the menu of config.ini
#   wl-copy     a stand-in for wl-clipboard's (below)
#
# bwm itself is patched to know fuzzel (see `patched` below).
#
# The clipboard. bwm copies a password by running a plain `wl-copy`, and clears
# the clipboard 30 seconds later by running it again with empty input (read
# from its source: `bwm/__init__.py`, `bwm/bwtype.py` in 0.6.0; its README says
# "after 1 paste on Wayland", the code does not use --paste-once). A history
# watcher (`wl-paste --watch cliphist store`, as the Sway session starts it)
# would record every password. wl-clipboard 2.3 has `wl-copy --sensitive`,
# which sets x-kde-passwordManagerHint=secret and makes `wl-paste --watch` run
# its command with CLIPBOARD_STATE=sensitive, which cliphist 0.7.0 honours (it
# stores nothing). bwm has no option for flags, so the stand-in adds it.
# --paste-once would be wrong: the watcher is a paste, and would use it up.
#
# The clear after 30 seconds is `wl-copy` with empty input, so the stand-in marks
# it sensitive too. With wl-clipboard 2.3 and cliphist 0.7.0 that changes
# nothing measurable (measured: a plain clear leaves the history as it is,
# because wl-paste reports an empty clipboard as CLIPBOARD_STATE=nil and
# cliphist 0.7.0 acts only on "clear"); it keeps a later cliphist that deletes
# the last entry on a clear from deleting an unrelated one. The check
# tests/desktop/bitwarden-menu-wrapper.nix requires the history to be the same
# before and after the clear.
{
  lib,
  symlinkJoin,
  makeWrapper,
  makeDesktopItem,
  writeShellApplication,
  bitwarden-menu,
  bitwarden-cli,
  wl-clipboard,
  wtype,
  fuzzel,
}:
let
  # bwm gives a question and hides typed input only for the menus it knows by
  # name (bwm/menu.py, dmenu_cmd: dmenu, rofi, bemenu and wofi). With
  # `fuzzel --dmenu` every question was fuzzel's bare "> ", and the `Password`
  # and `Verify password` prompts of an item whose password is typed by hand
  # showed what was typed. fuzzel 1.15 takes `--prompt=TEXT`, `--lines=N` and
  # `--password` (read from `fuzzel --help`; `--password` has an optional
  # argument, so it stands alone). The `=` form keeps a question that starts
  # with a dash from being read as a flag. The two replacements fail the build
  # when upstream changes the lines they match, so a newer bwm is looked at
  # and not silently left unpatched (tests/desktop/bitwarden-menu-prompts.nix).
  patched = bitwarden-menu.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace bwm/menu.py \
        --replace-fail \
          '"dmenu": ["-p", str(prompt), "-l", str(num_lines)],' \
          '"dmenu": ["-p", str(prompt), "-l", str(num_lines)],
              "fuzzel": [f"--prompt={prompt} ", f"--lines={num_lines}"],' \
        --replace-fail \
          '"wofi": ["-P"],' \
          '"wofi": ["-P"],
              "fuzzel": ["--password"],'
    '';
  });

  copy = writeShellApplication {
    name = "wl-copy";
    # No runtimeInputs: the real one is called by its store path, and the
    # caller's PATH must stay what it was.
    text = ''
      exec ${wl-clipboard}/bin/wl-copy --sensitive "$@"
    '';
  };

  menu = makeDesktopItem {
    name = "bitwarden-menu";
    desktopName = "Bitwarden Menu";
    genericName = "Password Menu";
    comment = "Your vault in a keyboard menu (bwm), beside Bitwarden desktop";
    exec = "bwm";
    tryExec = "bwm";
    icon = "dialog-password";
    terminal = false;
    categories = [
      "Utility"
      "Security"
    ];
    keywords = [
      "bitwarden"
      "bwm"
      "vault"
      "password"
      "passwort"
      "login"
    ];
  };
in
symlinkJoin {
  name = "bitwarden-menu-${patched.version}";
  paths = [
    patched
    menu
  ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    rm $out/bin/bwm
    makeWrapper ${lib.getExe patched} $out/bin/bwm \
      --prefix PATH : ${
        lib.makeBinPath [
          copy
          bitwarden-cli
          wtype
          fuzzel
        ]
      }
  '';
  meta = {
    inherit (bitwarden-menu.meta) description license;
    mainProgram = "bwm";
    platforms = lib.platforms.linux;
  };
}
