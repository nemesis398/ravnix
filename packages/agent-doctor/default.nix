# agent-doctor: catches drift in the agent-instruction corpus (the vault's
# conventions and roles, the Claude Code skills). Carried over from Fedora's
# bin-agent-doctor and still Python, unchanged but for the places it looks in
# (AGENTS.md, rule 4); README.md has what changed. Stdlib only.
{ writers }:
writers.writePython3Bin "agent-doctor"
  {
    # The original fails flake8 on these and is left as it was:
    #   E501  lines past 79 characters (28 of them)
    #   W503  line breaks before binary operators (3), the style of the file;
    #         flake8's own defaults ignore it, and giving an ignore list
    #         replaces the defaults
    flakeIgnore = [
      "E501"
      "W503"
    ];
  }
  (builtins.readFile ./agent-doctor.py)
