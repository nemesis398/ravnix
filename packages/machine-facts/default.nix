# machine-facts: prints the volatile state of this laptop as a Markdown block,
# and keeps the block of a vault note true. Carried over from Fedora's
# bin-machine-facts and still Bash (AGENTS.md, rule 4); README.md has what
# changed and what was left out. The tools of the session (sway, swaymsg,
# nmcli, resolvectl, hostnamectl, sudo) are looked up on the PATH.
{
  lib,
  writeShellApplication,
  coreutils,
  diffutils,
  efibootmgr,
  findutils,
  gawk,
  gnugrep,
  gnused,
  jq,
  kmod,
  procps,
  util-linux,
}:
writeShellApplication {
  name = "machine-facts";
  # The script is deliberately not errexit ("report per-section and keep
  # going") and sets set -uo pipefail itself.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    diffutils
    efibootmgr
    findutils
    gawk
    gnugrep
    gnused
    jq
    kmod
    procps
    util-linux
  ];
  text = lib.removePrefix "#!/bin/bash\n" (builtins.readFile ./machine-facts.sh);
  meta = {
    description = "The volatile state of a laptop as a Markdown block";
    license = lib.licenses.agpl3Plus;
    mainProgram = "machine-facts";
  };
}
