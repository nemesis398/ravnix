# claude-telemetry, carried over from Fedora's bin-claude-telemetry with its
# tests: fixtures stand in for the transcripts, the settings and the memory
# notes, the lint of the ai-memory skill is a stand-in (the skill is not part
# of ravnix), and the privacy case requires that a marker planted in every
# place that holds text appears in no file the script writes. The units are
# the ones modules/common/scripts.nix generates with the weekly report on, and
# the cases for where the folders come from are new.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hm = import ./../common/helpers/hm.nix { inherit self inputs pkgs lib; };
  files = (hm [ { ravnix.scripts.claudeTelemetry.report = true; ravnix.claude.skillValues.nextcloud.root = "/srv/cloud"; } ]).config.xdg.configFile;
  unit = name: {
    inherit name;
    path = files."systemd/user/${name}".source;
  };
  units = pkgs.linkFarm "claude-telemetry-units" (
    map unit [
      "claude-telemetry-extract.service"
      "claude-telemetry-extract.timer"
      "claude-telemetry-report.service"
      "claude-telemetry-report.timer"
    ]
  );
in
pkgs.runCommand "bin-claude-telemetry"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.python3
      pkgs.systemd
    ];
    CLAUDE_TELEMETRY_UNDER_TEST = "${self.packages.${system}.claude-telemetry}/bin/claude-telemetry";
    CLAUDE_TELEMETRY_UNITS = units;
    # The user units of systemd itself (basic.target, timers.target), which the
    # verification of a unit that orders itself after them has to find.
    SYSTEMD_UNIT_PATH = "${pkgs.systemd}/example/systemd/user";
    src = lib.fileset.toSource {
      root = ../../packages/claude-telemetry;
      fileset = ../../packages/claude-telemetry/tests;
    };
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp -r "$src/tests" tests
    chmod -R u+w tests
    bash tests/claude-telemetry.test.sh
    touch "$out"
  ''
