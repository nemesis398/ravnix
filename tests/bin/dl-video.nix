# dl-video (packages/dl-video): systemd-run, systemctl, ffmpeg, ffprobe and
# notify-send are stand-ins in front of the script's own tools, so no unit is
# started and no network is used. The script has no tests in Fedora; these are
# new.
{
  self,
  pkgs,
  system,
  ...
}:
let
  stubFirst = import ./helpers/stub-first.nix { inherit pkgs; };
in
pkgs.runCommand "bin-dl-video"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
    ];
    DL_VIDEO_UNDER_TEST = stubFirst "${self.packages.${system}.dl-video}/bin/dl-video";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/dl-video/tests/dl-video.test.sh}
    touch "$out"
  ''
