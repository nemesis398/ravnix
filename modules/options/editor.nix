# The languages the editor (modules/common/nvim.nix) installs language
# servers, formatters and linters for. A value a user may set in me.nix, so
# the option is declared here and not in the editor module: me.nix is checked
# against the options module alone.
{ lib, ... }:
let
  # What modules/common/nvim.nix knows how to install, one entry per name; it
  # refuses to evaluate when its list and this one differ.
  languages = [
    "bash"
    "json"
    "languagetool"
    "lua"
    "markdown"
    "nix"
    "odin"
    "python"
    "web"
  ];
in
{
  options.ravnix.editor.languages = lib.mkOption {
    type = lib.types.listOf (lib.types.enum languages);
    default = languages;
    example = [
      "lua"
      "nix"
    ];
    description = ''
      The languages the editor gets language servers, formatters and linters
      for. All of them by default. A host that needs fewer says which: the
      Odin toolchain behind `odin` is 2.3 GiB, and `languagetool` brings a
      JDK. The editor turns off what a language left out would have started,
      so a file of that language opens with no error. `web` stands for
      prettier (CSS, HTML, JavaScript, TypeScript, YAML and JSON).
    '';
  };
}
