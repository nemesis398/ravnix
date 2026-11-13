# ravnix-dict: one dictionary of custom words for every tool that keeps a
# word list (README.md). The adapters for Handy, LanguageTool and the prose
# skill come with Task 7.2; modules/common/dictionary.nix puts the tool on
# PATH with the dictionary from ravnix.dictionary.file.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "ravnix-dict";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench syncs bench/dictionary.txt (2000 made-up words, with comments,
  # fields and umlauts) against bench/state, whose known list has two words
  # that are gone from the file, as a line deleted by hand: the reading, the
  # parsing, the lock, and the record of the removals, written back. With no
  # adapter in the package yet, no tool is read or written.
  benchArgs = [
    "--file"
    "dictionary.txt"
    "--state"
    "state"
    "sync"
  ];
}
