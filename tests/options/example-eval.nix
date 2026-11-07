# The template a new user starts from, templates/default/, evaluates: its
# me.nix passes every type and assertion of ravnix's options, sets every
# option there is (so it stays the complete list a user fills in), its
# backups.toml and dictionary.txt hold what their tools read, and its
# flake.nix's own checks evaluate against this checkout of ravnix.
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

  retention = builtins.fromTOML (builtins.readFile me.config.ravnix.backup.retentionFile);
  counts = [
    "daily"
    "weekly"
    "monthly"
    "yearly"
  ];
  badTargets =
    lib.concatMap
      (
        target:
        let
          t = retention.targets.${target} or null;
        in
        if t == null then
          [ "backups.toml has no [targets.${target}]" ]
        else
          lib.concatMap (
            key:
            lib.optional (
              !(builtins.isInt (t.${key} or null)) || t.${key} < 0
            ) "backups.toml: targets.${target}.${key} is not a non-negative integer"
          ) counts
      )
      [
        "nas"
        "internxt"
      ];

  # The dictionary format of ravnix-dict: `word`, then optional fields
  # ` | lang=de,en` and ` | heard=Hugin;def VM`; `#` starts a comment line.
  dictionaryLines = lib.filter (l: l != "" && !(lib.hasPrefix "#" l)) (
    lib.splitString "\n" (builtins.readFile (template + "/dictionary.txt"))
  );
  entry = "[^#|[:space:]]([^|]*[^|[:space:]])?( [|] (lang=[a-z]{2}(,[a-z]{2})*|heard=[^|;]*[^|;[:space:]](;[^|;]*[^|;[:space:]])*))*";
  badWords = lib.filter (l: builtins.match entry l == null) dictionaryLines;

  # The template's flake.nix, its inputs given by hand: ravnix is this
  # checkout, nixpkgs and claude-code are the ones this flake locks.
  templateFlake = import (template + "/flake.nix");
  templateOutputs = templateFlake.outputs {
    self = templateOutputs // {
      outPath = template;
    };
    ravnix = self;
    inherit (inputs) nixpkgs claude-code;
  };
  templateChecks = templateOutputs.checks.${system} or { };

  failures =
    lib.optional (me.failed != [ ])
      "the template's me.nix fails assertions:\n${lib.concatMapStrings (m: "  - ${m}\n") me.failed}"
    ++ lib.optional (!me.values.success) "a value in the template's me.nix does not evaluate"
    ++
      lib.optional (unset != [ ])
        "the template's me.nix does not set ${lib.concatStringsSep ", " unset}; it must list every option, with a comment"
    ++ badTargets
    ++ lib.optional (dictionaryLines == [ ]) "the template's dictionary.txt has no entries"
    ++ map (l: "dictionary.txt: not an entry: ${l}") badWords
    ++ lib.optional (!(templateFlake.inputs ? ravnix)) "the template's flake.nix has no ravnix input"
    ++ lib.optional (
      (templateFlake.inputs.ravnix.inputs.claude-code.follows or null) != "claude-code"
    ) "the template does not hand its claude-code input to ravnix"
    ++ lib.optional (!(templateChecks ? me)) "the template's flake has no check `me`"
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
