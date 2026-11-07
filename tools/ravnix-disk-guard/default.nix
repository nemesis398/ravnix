# ravnix-disk-guard: picks the one disk an installer may write, by model and
# serial, and refuses one that is mounted or held by a mapping (README.md).
# It runs lsblk, whose store path the build puts into the binary, so it
# needs nothing on PATH.
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
buildOdinTool {
  name = "ravnix-disk-guard";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [ "-define:LSBLK=${lib.getExe' pkgs.util-linux "lsblk"}" ];
  # The bench decides on bench/lsblk.json and the links in bench/by-id: a
  # laptop with the two NVMe disks, a USB stick, zram and snap's loop
  # devices, without running lsblk.
  benchArgs = [
    "--model"
    "Example SSD 1TB"
    "--serial"
    "EXAMPLE0SERIAL"
    "--print-device"
    "--lsblk-json"
    "lsblk.json"
    "--by-id"
    "by-id"
  ];
}
