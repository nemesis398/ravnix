# Claude Code as ravnix ships it (lib/claude-code.nix): the claude-code
# input's package, unchanged, with the download it was made from as
# passthru.download, which the gate verifies against Anthropic's release
# manifest. This test evaluates only; the download itself is checked by the
# full gate, which needs the network.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  withDownload = import ../../lib/claude-code.nix { inherit lib; };
  shipped = self.packages.${system}.claude-code;
  upstream = inputs.claude-code.packages.${system}.claude-code;
  refused = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  # Stand-ins for claude-code-nix's package: an install phase that uses one
  # file named claude, none, or two.
  claudeFile = text: pkgs.writeText "claude" text;
  one = claudeFile "one";
  fake =
    files:
    pkgs.stdenvNoCC.mkDerivation {
      name = "fake-claude-code";
      dontUnpack = true;
      installPhase = "mkdir $out; " + lib.concatMapStrings (f: "cat ${f} >>$out/claude; ") files;
    };

  failures =
    lib.optional (shipped.outPath != upstream.outPath)
      "packages.claude-code is not the claude-code input's package: ${shipped.outPath} against ${upstream.outPath}"
    ++ lib.optional (
      shipped.version != upstream.version
    ) "packages.claude-code has another version than its input"
    ++ lib.optional (!(shipped ? download)) "packages.claude-code has no download"
    ++ lib.optional (
      shipped ? download && shipped.download.name != "claude"
    ) "the download is named ${shipped.download.name}, not claude"
    ++ lib.optional (
      shipped ? download && !(builtins.hasContext "${shipped.download}")
    ) "the download is a plain string, which Nix would not build"
    # The download is an input of the package, so the program in it was made
    # from these bytes.
    ++ lib.optional (
      shipped ? download
      && !(
        builtins.getContext shipped.drvAttrs.installPhase
          ? ${builtins.unsafeDiscardStringContext shipped.download.drvPath}
      )
    ) "the download is not an input of the package's install phase"
    ++ lib.optional (
      (withDownload (fake [ one ])).download.outPath != one.outPath
    ) "with one file named claude, that file is not the download"
    ++ lib.optional (
      !refused (withDownload (fake [ ])).download
    ) "a package whose install phase uses no file named claude was not refused"
    ++ lib.optional (
      !refused
        (withDownload (fake [
          one
          (claudeFile "two")
        ])).download
    ) "a package whose install phase uses two files named claude was not refused"
    ++ lib.optional (
      !refused (withDownload (pkgs.runCommand "no-install-phase" { } "touch $out")).download
    ) "a package without an install phase was not refused";
in
if failures != [ ] then
  throw "claude-package:\n${lib.concatMapStrings (f: "- ${f}\n") failures}"
else
  pkgs.runCommand "claude-package" { } "touch $out"
