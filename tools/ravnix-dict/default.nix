# ravnix-dict: one dictionary of custom words for every tool that keeps a
# word list (README.md), with its adapters for Handy, LanguageTool and the
# prose skill (adapters/). modules/common/dictionary.nix puts the tool on
# PATH with the dictionary from ravnix.dictionary.file, and
# modules/common/dictionary-watch.nix syncs it when a list changes.
{ buildOdinTool, pkgs, ... }:
buildOdinTool {
  name = "ravnix-dict";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The LanguageTool adapter's requests go through this curl, which the
  # tests then have as well: they run it against a fake API.
  odinFlags = [ "-define:RAVNIX_DICT_CURL=${pkgs.curl}/bin/curl" ];
  # The bench syncs bench/dictionary.txt (2000 made-up words, with comments,
  # fields and umlauts) against bench/state, whose known list has two words
  # that are gone from the file, as a line deleted by hand: the reading, the
  # parsing, the lock, and the record of the removals, written back. The
  # bench's environment sets no RAVNIX_DICT_ADAPTERS, so no tool is read or
  # written.
  benchArgs = [
    "--file"
    "dictionary.txt"
    "--state"
    "state"
    "sync"
  ];
}
