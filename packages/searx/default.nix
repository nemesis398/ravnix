# searx: web search through the user's SearXNG, printed as a numbered list.
# Carried over from Fedora's bin-searx and still Bash (AGENTS.md, rule 4);
# README.md has what changed. The URL is not built in: SEARXNG_URL, else the
# skill value web.searxngUrl (claude/README.md).
{
  lib,
  writeShellApplication,
  coreutils,
  curl,
  jq,
}:
writeShellApplication {
  name = "searx";
  # The script sets its own options (set -uo pipefail); errexit would change
  # what it does.
  bashOptions = [ ];
  runtimeInputs = [
    coreutils
    curl
    jq
  ];
  text = lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile ./searx.sh);
  meta = {
    description = "Web search through a self-hosted SearXNG, as a numbered list";
    license = lib.licenses.agpl3Plus;
    mainProgram = "searx";
  };
}
