# The editor's LanguageTool code (modules/common/nvim/lua/ravnix_languagetool.lua)
# reads the dictionary's lang fields as ravnix-dict does, and appends no word
# that ravnix-dict would refuse: run in a plain headless Neovim, with the
# module and a stand-in for its one dependency, the dictionary's path. The
# whole editor's checks of it are in tests/common/nvim.nix.
{ pkgs, ... }:
pkgs.runCommand "common-nvim-dictionary" { nativeBuildInputs = [ pkgs.neovim-unwrapped ]; } ''
  export HOME="$PWD/home" XDG_STATE_HOME="$PWD/state" XDG_DATA_HOME="$PWD/data"
  mkdir -p "$HOME"
  nvim --clean --headless -l ${./helpers/nvim-dictionary.lua} ${../../modules/common/nvim/lua} "$PWD/dictionary.txt"
  touch "$out"
''
