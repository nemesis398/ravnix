# The one dictionary of custom words that every tool with a word list gets,
# and which tools ravnix-dict keeps in step with it on a host.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
  adapter =
    default: description:
    mkOption {
      type = types.bool;
      inherit default description;
      # Set by the shape and the modules that install the tool, not in
      # me.nix: one me.nix serves both hosts, and the tools differ.
      internal = true;
    };
in
{
  options.ravnix.dictionary = {
    file = mkOption {
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

    watch = mkOption {
      type = types.bool;
      default = true;
      example = false;
      description = ''
        Whether a user service runs `ravnix-dict sync` whenever the
        dictionary or a tool's word list changes, and every 15 minutes for
        the lists no file shows (LanguageTool's). Without it, the tools get
        the dictionary's words when you run `ravnix-dict sync` yourself.
      '';
    };

    adapters = {
      handy = adapter false ''
        Whether ravnix-dict syncs Handy's custom words. The desktop sets
        it, where it installs Handy.
      '';
      languagetool = adapter (config.ravnix.shape == "laptop") ''
        Whether ravnix-dict syncs the word list of the LanguageTool account.
        On the laptop only: a sync takes the cloud list's new words into the
        host's own checkout of the dictionary, so on a second host they would
        come in again, as changes of that checkout, and a word removed on one
        host would go back into the cloud until the other had pulled the
        removal.
      '';
      prose = adapter true ''
        Whether ravnix-dict syncs the prose skill's dictionary,
        ~/.config/prose/dictionary.txt.
      '';
    };
  };
}
