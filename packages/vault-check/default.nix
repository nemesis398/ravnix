# vault-check: the deterministic health check of the Obsidian vault, carried
# over from Fedora's bin-vault-check and still Bash (AGENTS.md, rule 4);
# README.md has what changed. The vault is VAULT_DIR or the skill value
# vault.root, and the baseline of accepted findings is the user's own file
# (ravnix.scripts.vaultCheck.baseline), neither built in. The Obsidian CLI
# (obsidian) is the session's and is looked up on the PATH.
{
  lib,
  writeShellApplication,
  bc,
  coreutils,
  diffutils,
  findutils,
  gawk,
  gnugrep,
  gnused,
  jq,
  python3,
}:
writeShellApplication {
  name = "vault-check";
  # The script sets its own options (set -uo pipefail); errexit would change
  # what it does.
  bashOptions = [ ];
  runtimeInputs = [
    bc
    coreutils
    diffutils
    findutils
    gawk
    gnugrep
    gnused
    jq
    python3
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./vault-check.sh);
  meta = {
    description = "Deterministic health check for an Obsidian vault";
    license = lib.licenses.agpl3Plus;
    mainProgram = "vault-check";
  };
}
