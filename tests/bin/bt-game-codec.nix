# bt-game-codec (packages/bt-game-codec): pactl is a stand-in in front of the
# script's own, so no headphones are switched. The script has no tests in
# Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
let
  stubFirst = import ./helpers/stub-first.nix { inherit pkgs; };
in
pkgs.runCommand "bin-bt-game-codec"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
    ];
    BT_GAME_CODEC_UNDER_TEST = stubFirst "${self.packages.${system}.bt-game-codec}/bin/bt-game-codec";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/bt-game-codec/tests/bt-game-codec.test.sh}
    touch "$out"
  ''
