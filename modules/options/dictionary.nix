# The one dictionary of custom words that every tool with a word list gets.
{ lib, ... }:
let
  inherit (lib) mkOption;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.dictionary.file = mkOption {
    # A string, not a Nix path: the tools write words into this file at
    # runtime, and a Nix path would be a read-only copy in the store.
    type = ravnix.absolutePath;
    example = "/home/alice/src/ravnix-private/dictionary.txt";
    description = ''
      The dictionary in your checkout of the private flake, as an absolute
      path in a string. A word added to it, or in any tool, reaches every
      tool without a rebuild. One entry per line: `word`, or
      `word | lang=de,en | heard=what speech recognition wrote instead`;
      lines starting with `#` are comments.
    '';
  };
}
