# The tests of the Claude Code hooks and the status line (claude/), which
# are carried-over Bash and stay Bash behind these tests until their port
# (AGENTS.md, rule 4). Each claude/*/tests/*.test.sh runs with bash in the
# build sandbox, with the tools the hooks and the tests use and nothing
# else; a test that needs a tool missing here fails, and says which.
{ pkgs, lib, ... }:
pkgs.runCommand "claude-hooks"
  {
    src = lib.fileset.toSource {
      root = ../../claude;
      fileset = lib.fileset.unions [
        ../../claude/hooks
        ../../claude/settings
        ../../claude/statusline
      ];
    };
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.diffutils
      pkgs.findutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.procps
      pkgs.python3
      pkgs.util-linux
    ];
  }
  ''
    cp -r "$src" claude
    chmod -R u+w claude
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    # The status line's reset times are local times; without the zone data
    # every time zone would quietly be UTC.
    export TZDIR=${pkgs.tzdata}/share/zoneinfo
    status=0
    for test in claude/*/tests/*.test.sh; do
      echo "==> $test"
      bash "$test" || status=1
    done
    [ "$status" = 0 ]
    touch "$out"
  ''
