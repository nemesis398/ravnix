# dl-video: stream-copies a remote video to a file, as a background systemd
# user unit. Carried over from Fedora's bin-dl-video and still Bash (AGENTS.md,
# rule 4); README.md has what changed. systemd-run and systemctl are the
# system's and are looked up on the PATH, so they match the running systemd.
{
  lib,
  writeShellApplication,
  coreutils,
  ffmpeg-headless,
  gawk,
  gnugrep,
  libnotify,
}:
writeShellApplication {
  name = "dl-video";
  # The script sets its own options (set -euo pipefail).
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    ffmpeg-headless
    gawk
    gnugrep
    libnotify
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./dl-video.sh);
  meta = {
    description = "Stream-copies a remote video to a file in a background unit";
    license = lib.licenses.agpl3Plus;
    mainProgram = "dl-video";
  };
}
