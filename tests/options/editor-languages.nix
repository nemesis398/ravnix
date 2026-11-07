# ravnix.editor.languages is defined once. me.nix in the template defines it
# with every language, and a list option would join a second definition to it
# instead of replacing it: a host that wrote a shorter list would get every
# language and no error. So a second definition at the same priority fails,
# saying that the option is defined multiple times and where, a lib.mkForce
# replaces the template's, and a single definition is the value.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;

  value =
    modules:
    let
      languages = (eval modules).config.ravnix.editor.languages;
    in
    builtins.tryEval (builtins.deepSeq languages languages);

  everything = (value [ template ]).value;
  narrowed = [
    "lua"
    "nix"
  ];

  alone = value [ { ravnix.editor.languages = narrowed; } ];
  forced = value [
    template
    { ravnix.editor.languages = lib.mkForce narrowed; }
  ];
  joined = value [
    template
    { ravnix.editor.languages = narrowed; }
  ];
  twice = value [
    { ravnix.editor.languages = narrowed; }
    { ravnix.editor.languages = [ "bash" ]; }
  ];

  failures =
    lib.optional (
      !(value [ template ]).success || lib.length everything != 9
    ) "the template does not give the nine languages: ${builtins.toJSON everything}"
    ++ lib.optional (!alone.success || alone.value != narrowed) "one definition is not the value"
    ++ lib.optional (
      !forced.success || forced.value != narrowed
    ) "a lib.mkForce does not replace the template's list"
    ++ lib.optional joined.success "a second definition beside the template's was joined to it"
    ++ lib.optional twice.success "two definitions at the same priority were accepted";
in
pkgs.runCommand "options-editor-languages"
  {
    nativeBuildInputs = [
      pkgs.nix
      pkgs.gnugrep
    ];
    # The message a host sees: what the module system says about the option,
    # run by nix-instantiate because an evaluation error is not a value a
    # Nix expression can read.
    expression = ''
      let
        lib = import ${inputs.nixpkgs}/lib;
      in
      (lib.evalModules {
        modules = [
          ${self}/modules/options/editor.nix
          { _file = "me.nix"; ravnix.editor.languages = [ "lua" ]; }
          { _file = "host.nix"; ravnix.editor.languages = [ "nix" ]; }
        ];
      }).config.ravnix.editor.languages
    '';
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_LOG_DIR=$TMPDIR/log
        if nix-instantiate --eval --strict --store dummy:// --expr "$expression" > out.txt 2> err.txt; then
          echo "two definitions evaluated: $(cat out.txt)" >&2
          exit 1
        fi
        echo "(expected) the module system refuses the second definition, as it should:"
        cat err.txt
        for text in 'ravnix.editor.languages' 'defined multiple times' 'me.nix' 'host.nix' 'lib.mkForce'; do
          grep -qF -- "$text" err.txt || { echo "the message lacks: $text" >&2; exit 1; }
        done
        touch $out
      ''
  )
