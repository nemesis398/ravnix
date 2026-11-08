# ravnix.shell.secretEnv refuses the names that ravnix's own tools use for
# themselves. A secret exported under such a name would not stay a secret:
# claude-bg takes its reason from CLAUDE_BG_WHY and prints it, with-secret-env
# hands over WITH_SECRET_ENV_*, and the others change where a tool looks for
# its table, its vault or its notes. So every name a tool of packages/ reads
# from its environment for its own use must be refused, and this check finds
# those names by reading the sources, so that a tool that starts to read one
# more does not slip past a list that someone forgot to extend.
#
# The scan reads the shell and Python files of packages/NAME (not their
# tests) for the two idioms the tools use: ${NAME:-...}, ${NAME-...},
# ${NAME:=...} and ${NAME:+...} in shell, and os.environ.get("NAME"...),
# os.environ["NAME"] and os.getenv("NAME") in Python.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  hm = import ../common/helpers/hm.nix { inherit self inputs pkgs lib; };
  template = ../../templates/default/me.nix;

  withName =
    name: [
      template
      { ravnix.shell.secretEnv.${name} = "item"; }
    ];
  # The messages of the failed assertions that name this variable.
  refusals = name: lib.filter (m: lib.hasInfix "\"${name}\"" m) (eval (withName name)).failed;
  refusedByAssertion = name: refusals name != [ ];
  # What a host build does: it throws, so the name never reaches a table.
  refusedAtEvaluation =
    name:
    !(builtins.tryEval (builtins.deepSeq (eval (withName name)).ok.ravnix.shell.secretEnv true)).success;

  # The environment variables the sources of packages/ read.
  packagesDir = ../../packages;
  packageNames = lib.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir packagesDir));
  sourcesOf =
    pkg:
    lib.filter (f: lib.hasSuffix ".sh" f || lib.hasSuffix ".py" f) (
      lib.attrNames (lib.filterAttrs (_: t: t == "regular") (builtins.readDir (packagesDir + "/${pkg}")))
    );
  textsOf = lib.concatMap (pkg: map (f: builtins.readFile (packagesDir + "/${pkg}/${f}")) (sourcesOf pkg)) packageNames;
  captures =
    regex: text:
    map lib.head (lib.filter builtins.isList (builtins.split regex text));
  readNames = lib.unique (
    lib.concatMap (
      text:
      captures "[$][{]([A-Z][A-Z0-9_]*)(:-|:=|-|:[+])" text
      ++ captures "environ[.]get[(][\"]([A-Z][A-Z0-9_]*)[\"]" text
      ++ captures "environ[[][\"]([A-Z][A-Z0-9_]*)[\"][]]" text
      ++ captures "getenv[(][\"]([A-Z][A-Z0-9_]*)[\"]" text
    ) textsOf
  );
  # Read after sourcing /etc/os-release, not from the environment.
  notEnvironment = [ "PRETTY_NAME" ];
  toolNames = lib.subtractLists notEnvironment readNames;

  # The two the review named, and one of each family.
  handOff = [
    "CLAUDE_BG_WHY"
    "WITH_SECRET_ENV_WHY"
    "WITH_SECRET_ENV_LOADED"
    "CLAUDE_BG_SECRETS"
    "RAVNIX_SECRET_ENV"
    "RAVNIX_SKILL_VALUES"
    "CCNA_DECK_NAME"
    "SAP_DECK_OUT"
    "AGENT_DOCTOR_NORMS"
    "CLAUDE_TELEMETRY_DIR"
    "VAULT_CHECK_BASELINE"
    "CHROME_DEVTOOLS_HELIUM"
    "CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP"
    "VAULT_DIR"
    "MACHINE_NOTE"
  ];

  # Good secret names that sit next to the families without being in them.
  allowed = [
    "CLAUDE_CODE_OAUTH_TOKEN"
    "PLANE_API_TOKEN"
    "CLAUDE_BGX_TOKEN"
    "RAVNIXTOKEN"
    "SAP_API_KEY"
    "WITH_SECRET_TOKEN"
    "CHROME_DEVTOOLS_API_TOKEN"
  ];

  failures =
    lib.optional (
      !(lib.all (n: lib.elem n readNames) [
        "CLAUDE_BG_WHY"
        "WITH_SECRET_ENV_WHY"
        "RAVNIX_SKILL_VALUES"
        "VAULT_DIR"
        "CCNA_DECK_NAME"
      ])
    ) "the scan of packages/ misses variables the tools read (found: ${toString readNames})"
    ++ map (n: "a secret named ${n}, which a tool reads for itself, is not refused") (
      lib.filter (n: !refusedByAssertion n) (lib.unique (handOff ++ toolNames))
    )
    ++ map (n: "a secret named ${n} does not stop the evaluation") (
      lib.filter (n: !refusedAtEvaluation n) handOff
    )
    ++ lib.optional (
      (builtins.tryEval (hm [ { ravnix.shell.secretEnv.CLAUDE_BG_WHY = "item"; } ]).config.home.username).success
    ) "home-manager builds with a secret named CLAUDE_BG_WHY"
    ++ map (n: "a good secret name ${n} is refused") (lib.filter (n: (eval (withName n)).failed != [ ]) allowed);
in
pkgs.runCommand "options-secret-env-reserved" { } (
  if failures == [ ] then
    ''
      echo ${toString (lib.length (lib.unique (handOff ++ toolNames)))} tool names are refused, ${toString (lib.length allowed)} neighbours are not
      touch "$out"
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
