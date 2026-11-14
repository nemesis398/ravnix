# ravnix-retention: reads the retention file, backups.toml, and prints the
# flags of `restic forget` for one target and one host (README.md).
{ buildOdinTool, ... }:
buildOdinTool {
  name = "ravnix-retention";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  benchArgs = [
    "flags"
    "--target"
    "internxt"
    "--host"
    "huginn"
    "--file"
    "backups.toml"
  ];
}
