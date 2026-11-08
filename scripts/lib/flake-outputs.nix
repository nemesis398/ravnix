# What the gate's flake step checks of the flake's outputs besides the
# checks, which scripts/check.sh builds one at a time. It is what
# `nix flake check` (Nix 2.35, `nix flake check --help`) checks of those
# outputs, in one evaluation that reads no check:
#
#   packages.SYSTEM.NAME   a derivation, its drvPath evaluated
#   overlays.NAME          a function whose argument is named final (or
#                          _final, or _), not a set pattern
#   nixosModules.NAME      a module: an attribute set, a function, or a path
#   homeModules.NAME       that exists (nix flake check only evaluates a
#                          NixOS module, and does not look at homeModules)
#   templates.NAME         an attribute set of path (a path that exists),
#                          description (a string) and, optionally,
#                          welcomeText (a string), and nothing else
#   checks.SYSTEM          an attribute set, counted but not read: the gate
#                          builds each check in a nix process of its own
#
# Per-system outputs are checked for SYSTEM, the one nix builds for. Other
# systems are omitted and named in the summary, as nix flake check omits
# them without --all-systems. Any other output (apps, devShells,
# nixosConfigurations, an old name such as overlay, a type of its own) is a
# problem, so a new output is never silently unchecked: check it here first.
#
#   (import ./flake-outputs.nix) SYSTEM OUTPUTS
#   => { problems; summary; report; }
#
# problems is a list of strings, summary one line per output, and report the
# summary, or a throw that names every problem. A value that throws is a
# problem of its own; any other evaluation error ends the evaluation with
# nix's message, which fails the step too.
system: outputs:
let
  inherit (builtins)
    attrNames
    concatMap
    concatStringsSep
    elem
    filter
    head
    isAttrs
    isPath
    isString
    length
    match
    pathExists
    substring
    toXML
    tryEval
    typeOf
    ;

  # The type of v in words, or null when evaluating it throws.
  kind =
    v:
    let
      t = tryEval (typeOf v);
      words = {
        int = "a number";
        float = "a number";
        bool = "a Boolean";
        string = "a string";
        path = "a path";
        null = "null";
        set = "an attribute set";
        list = "a list";
        lambda = "a function";
      };
    in
    if t.success then words.${t.value} or t.value else null;

  # The problems of the attribute set v at path, and of each value in it, as
  # f path value judges it.
  each =
    path: v: f:
    let
      k = kind v;
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k != "an attribute set" then
      [ "${path} is ${k}, not an attribute set" ]
    else
      concatMap (name: f "${path}.${name}" v.${name}) (attrNames v);

  # A per-system output: an attribute set of systems, of which only `system`
  # is judged, by f.
  perSystem =
    path: v: f:
    let
      k = kind v;
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k != "an attribute set" then
      [ "${path} is ${k}, not an attribute set" ]
    else if v ? ${system} then
      each "${path}.${system}" v.${system} f
    else
      [ ];

  derivation =
    path: v:
    let
      k = kind v;
      ok = tryEval ((v.type or null) == "derivation" && isString v.drvPath);
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k != "an attribute set" then
      [ "${path} is ${k}, not a derivation" ]
    else if !ok.success then
      [ "${path} throws when its derivation is evaluated (nix eval .#${path}.drvPath shows why)" ]
    else if !ok.value then
      [ "${path} is an attribute set, not a derivation" ]
    else
      [ ];

  overlay =
    path: v:
    let
      k = kind v;
      arg = match ".*<function>[[:space:]]*<varpat name=\"([^\"]*)\" />.*" (toXML v);
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k != "a function" then
      [ "${path} is ${k}, not a function" ]
    else if
      arg == null
      || !(elem (head arg) [
        "final"
        "_final"
        "_"
      ])
    then
      [ "${path} does not take an argument named final, as nix flake check requires of an overlay" ]
    else
      [ ];

  module =
    path: v:
    let
      k = kind v;
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k == "a path" then
      if pathExists v then [ ] else [ "${path} is the path ${toString v}, which does not exist" ]
    else if k == "an attribute set" || k == "a function" then
      [ ]
    else
      [ "${path} is ${k}, not a module (an attribute set, a function or a path)" ];

  template =
    path: v:
    let
      k = kind v;
      string =
        attr:
        let
          ka = kind v.${attr};
        in
        if ka == null then
          [ "${path}.${attr} throws when evaluated" ]
        else if ka != "a string" then
          [ "${path}.${attr} is ${ka}, not a string" ]
        else
          [ ];
      p = v.path;
      kp = kind p;
    in
    if k == null then
      [ "${path} throws when evaluated" ]
    else if k != "an attribute set" then
      [ "${path} is ${k}, not a template" ]
    else
      (
        if !(v ? path) then
          [ "${path} lacks the attribute path" ]
        else if kp == null then
          [ "${path}.path throws when evaluated" ]
        else if !(isPath p || (isString p && substring 0 1 p == "/")) then
          [ "${path}.path is ${kp}, not a path" ]
        else if !(pathExists p) then
          [ "${path}.path is the path ${toString p}, which does not exist" ]
        else
          [ ]
      )
      ++ (if v ? description then string "description" else [ "${path} lacks the attribute description" ])
      ++ (if v ? welcomeText then string "welcomeText" else [ ])
      ++ map (attr: "${path} has the attribute ${attr}, which nix flake check refuses in a template") (
        filter (
          attr:
          !(elem attr [
            "path"
            "description"
            "welcomeText"
          ])
        ) (attrNames v)
      );

  # The outputs the step knows, each with its judge.
  judges = {
    checks = v: perSystem "checks" v (_: _: [ ]);
    packages = v: perSystem "packages" v derivation;
    overlays = v: each "overlays" v overlay;
    nixosModules = v: each "nixosModules" v module;
    homeModules = v: each "homeModules" v module;
    templates = v: each "templates" v template;
  };

  names = attrNames outputs;
  known = filter (name: judges ? ${name}) names;
  unknown = filter (name: !(judges ? ${name})) names;

  problems =
    map (
      name:
      "flake output ${name} is no output the flake step knows how to check; check it in scripts/lib/flake-outputs.nix first"
    ) unknown
    ++ concatMap (name: judges.${name} outputs.${name}) known;

  # "N things", or "1 thing".
  count =
    n: noun:
    "${toString n} ${noun}${if n == 1 then "" else "s"}";
  sizeOf = v: if isAttrs v then length (attrNames v) else 0;
  systemsOf = v: if isAttrs v then attrNames v else [ ];
  nouns = {
    checks = "check";
    packages = "derivation";
    overlays = "overlay";
    nixosModules = "module";
    homeModules = "module";
    templates = "template";
  };
  perSystemOutputs = [
    "checks"
    "packages"
  ];
  lineOf =
    name:
    if elem name perSystemOutputs then
      "${name}.${system}: ${count (sizeOf (outputs.${name}.${system} or { })) nouns.${name}}${
        if name == "checks" then ", each built on its own" else ""
      }"
    else
      "${name}: ${count (sizeOf outputs.${name}) nouns.${name}}";
  omitted = concatMap (
    name: map (sys: "${name}.${sys}") (filter (sys: sys != system) (systemsOf outputs.${name}))
  ) (filter (name: elem name perSystemOutputs) known);

  summary = concatStringsSep "\n" (
    map lineOf known
    ++ (if omitted == [ ] then [ ] else [ "omitted, not ${system}: ${concatStringsSep ", " omitted}" ])
  );
in
{
  inherit problems summary;
  report =
    if problems == [ ] then
      summary + "\n"
    else
      throw "the flake's outputs have ${count (length problems) "problem"}:\n  ${concatStringsSep "\n  " problems}";
}
