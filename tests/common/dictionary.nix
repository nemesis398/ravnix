# modules/common/dictionary.nix: home-manager puts ravnix-dict on the PATH,
# once, and the command finds the dictionary that ravnix.dictionary.file
# names, while RAVNIX_DICT_FILE and --file still win. The tool's own
# behavior is checks.ravnix-dict-tests.
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
  # A path that exists in no build sandbox: the wrapper's default is told
  # apart from the file the test makes by the message that names it.
  configured = "/nonexistent/ravnix-dict-test/dictionary.txt";
  config =
    (hm [
      { ravnix.dictionary.file = lib.mkForce configured; }
    ]).config;
  dicts = lib.filter (p: lib.getName p == "ravnix-dict") config.home.packages;
  failures = lib.optional (
    lib.length dicts != 1
  ) "home.packages holds ravnix-dict ${toString (lib.length dicts)} times, not once";
  dict = lib.head (dicts ++ [ null ]);
in
pkgs.runCommand "common-dictionary" { nativeBuildInputs = [ pkgs.gnugrep ]; } (
  if failures != [ ] then
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    ''
      export HOME="$PWD/home"
      bin=${lib.getExe dict}
      fail() { echo "common-dictionary: $*" >&2; exit 1; }

      # The default is the option's path, which does not exist here.
      unset RAVNIX_DICT_FILE
      if "$bin" list 2>err; then fail "list found a dictionary at the option's path"; fi
      grep -qF ${lib.escapeShellArg configured} err || fail "the error does not name the option's path: $(cat err)"

      # The environment wins over the default, --file over both.
      printf 'Huginn\nMuninn | lang=en\n' >env.txt
      printf 'Other\n' >flag.txt
      [ "$(RAVNIX_DICT_FILE="$PWD/env.txt" "$bin" list)" = "$(printf 'Huginn\nMuninn')" ] ||
        fail "RAVNIX_DICT_FILE is not read"
      [ "$(RAVNIX_DICT_FILE="$PWD/env.txt" "$bin" --file "$PWD/flag.txt" list)" = Other ] ||
        fail "--file does not win"

      # It writes, with its state under HOME.
      RAVNIX_DICT_FILE="$PWD/env.txt" "$bin" add "Open WebUI" --lang en >/dev/null
      grep -qxF 'Open WebUI | lang=en' env.txt || fail "add did not write: $(cat env.txt)"
      [ -e "$HOME/.local/state/ravnix-dict/lock" ] || fail "the state is not under HOME"

      touch "$out"
    ''
)
