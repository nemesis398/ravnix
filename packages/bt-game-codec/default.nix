# bt-game-codec: switches Bluetooth headphones to SBC while a game runs, and
# back, to cut the latency of AAC. Carried over from Fedora's bin-bt-game-codec
# and still Bash (AGENTS.md, rule 4); README.md has what changed. pactl comes
# from the pulseaudio package, which speaks to PipeWire's pulse server too.
{
  lib,
  writeShellApplication,
  coreutils,
  gawk,
  gnugrep,
  pulseaudio,
}:
writeShellApplication {
  name = "bt-game-codec";
  # The script sets its own options (set -u); errexit would change what it
  # does: it always exits 0.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    gawk
    gnugrep
    pulseaudio
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./bt-game-codec.sh);
  meta = {
    description = "Switches Bluetooth headphones to SBC while a game runs";
    license = lib.licenses.agpl3Plus;
    mainProgram = "bt-game-codec";
  };
}
