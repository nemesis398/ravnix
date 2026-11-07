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
    # One definition: a list option joins its definitions, so a host module
    # that wrote a shorter list beside the one in me.nix would get both
    # together, every language, and no error. uniq refuses the second one.
    type = lib.types.uniq (lib.types.listOf (lib.types.enum languages));
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

      The list is defined once. me.nix in the template defines it with every
      language: to narrow it, edit that list, or write `lib.mkForce [ ... ]`
      in a host module. A second plain definition is an error ("defined
      multiple times") and not a union, which would leave every language in.
    '';
  };
}
