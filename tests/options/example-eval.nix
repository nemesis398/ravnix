# The template a new user starts from, templates/default/, evaluates: its
# me.nix passes every type and assertion of ravnix's options (the
# retention schema of its backups.toml among them), sets every option there
# is (so it stays the complete list a user fills in), its dictionary.txt
# holds what ravnix-dict reads, and its flake.nix's own checks evaluate
# against this checkout of ravnix.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default;
  me = eval [ (template + "/me.nix") ];

  # Every option of ravnix a user can set. An option inside a submodule
  # (hosts.<name>.address) is part of its parent and not listed on its own.
  # An option's default counts as a definition, at the priority of
  # mkOptionDefault, so an option the template does not set has no
  # definition above that priority.
  settable = lib.filter (o: !(o.readOnly or false) && !(o.internal or false)) (
    lib.collect lib.isOption me.options.ravnix
  );
  onlyDefault = (lib.mkOptionDefault null).priority;
  unset = map (o: lib.showOption o.loc) (
    lib.filter (o: !o.isDefined || o.highestPrio >= onlyDefault) settable
  );

  # The dictionary format of ravnix-dict: `word`, then optional fields
  # ` | lang=de,en` and ` | heard=Hugin;def VM`; `#` starts a comment line.
  dictionaryLines = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
    lib.splitString "\n" (builtins.readFile (template + "/dictionary.txt"))
  );
  entry = "[^#|[:space:]]([^|]*[^|[:space:]])?( [|] (lang=[a-z]{2}(,[a-z]{2})*|heard=[^|;]*[^|;[:space:]](;[^|;]*[^|;[:space:]])*))*";
  badWords = lib.filter (l: builtins.match entry l == null) dictionaryLines;

  # The template's flake.nix, its inputs given by hand: ravnix is this
  # checkout (or it with one module more), nixpkgs and claude-code are the
  # ones this flake locks. Its nixpkgs.lib turns a warning into a value the
  # test reads, { warning = "..."; }, instead of printing it, so this
  # flake's own check prints none and the test sees each one.
  recording = inputs.nixpkgs // {
    lib = inputs.nixpkgs.lib // {
      warn = message: _: { warning = message; };
      warnIf =
        condition: message: value:
        if condition then { warning = message; } else value;
    };
  };
  templateFlake = import (template + "/flake.nix");
  templateChecksWith =
    ravnix:
    let
      outputs = templateFlake.outputs {
        self = outputs // {
          outPath = template;
        };
        inherit ravnix;
        nixpkgs = recording;
        inherit (inputs) claude-code;
      };
    in
    outputs.checks.${system} or { };
  ravnixWith =
    module:
    self
    // {
      nixosModules = self.nixosModules // {
        options.imports = [
          self.nixosModules.options
          module
        ];
      };
    };
  # The template's placeholders warn on purpose (options-placeholders tests
  # them); without them it must warn about nothing at all.
  quiet.config.warnings = lib.mkForce [ ];
  templateChecks = templateChecksWith (ravnixWith quiet);
  warned = lib.attrNames (
    lib.filterAttrs (name: c: name == "warning" || (builtins.isAttrs c && c ? warning)) templateChecks
  );
  # With them, its me check names them.
  placeholderMe = (templateChecksWith self).me;
  # A contributor who sets dev.denyList but did not git add the list is
  # told, because public-boundary is then silently off.
  contributorMe =
    (templateChecksWith (ravnixWith {
      imports = [ quiet ];
      config.ravnix.dev.denyList = lib.mkForce "/home/alice/src/ravnix-private/deny-list.txt";
    })).me;

  failures =
    lib.optional (me.failed != [ ])
      "the template's me.nix fails assertions:\n${lib.concatMapStrings (m: "  - ${m}\n") me.failed}"
    ++ lib.optional (!me.values.success) "a value in the template's me.nix does not evaluate"
    ++
      lib.optional (unset != [ ])
        "the template's me.nix does not set ${lib.concatStringsSep ", " unset}; it must list every option, with a comment"
    ++ lib.optional (dictionaryLines == [ ]) "the template's dictionary.txt has no entries"
    ++ map (l: "dictionary.txt: not an entry: ${l}") badWords
    ++ lib.optional (!(templateFlake.inputs ? ravnix)) "the template's flake.nix has no ravnix input"
    ++ lib.optional (
      (templateFlake.inputs.ravnix.inputs.claude-code.follows or null) != "claude-code"
    ) "the template does not hand its claude-code input to ravnix"
    ++ lib.optional (!(templateChecks ? me)) "the template's flake has no check `me`"
    ++ map (
      name:
      "the template's flake warns by default, in ${name}: ${
        (templateChecks.${name}.warning or templateChecks.${name})
      }"
    ) warned
    ++ lib.optional (
      !(lib.hasPrefix "ravnix." (placeholderMe.warning or ""))
    ) "the template's me check does not name its placeholders"
    ++ lib.optional (
      !(lib.hasInfix "git add deny-list.txt" (contributorMe.warning or ""))
    ) "a contributor whose deny-list.txt is not tracked is not told to git add it"
    ++ lib.optional (
      templateChecks ? public-boundary
    ) "the template has no deny-list.txt, so its flake must not define public-boundary"
    ++ lib.optional (
      !(builtins.pathExists (self.templates.default.path + "/me.nix"))
    ) "templates.default does not point at the template";
in
pkgs.runCommand "options-example-eval" { } (
  if failures == [ ] then
    ''
      # The template's own check, built so its derivation is proven too.
      echo ${templateChecks.me}
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
