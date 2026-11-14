# tldr's page colors. The Python client takes the eight ANSI names only
# (blue, green, yellow, cyan, magenta, white, grey, red) and no accent, so the
# colors that mean something else are out: Red is failure and a command is not
# an error, Green is success, Yellow pending and Blue busy. A command is Teal
# (cyan), a placeholder is underlined, not colored, and the rest is the
# terminal's own Text.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ../common/helpers/hm.nix { inherit self inputs pkgs lib; };
  vars = (hm [ ]).config.home.sessionVariables;

  state = [
    "red"
    "green"
    "yellow"
    "blue"
  ];
  accepted = [
    "cyan"
    "magenta"
    "white"
    "bold"
    "underline"
    ""
  ];
  keys = [
    "TLDR_COLOR_NAME"
    "TLDR_COLOR_DESCRIPTION"
    "TLDR_COLOR_EXAMPLE"
    "TLDR_COLOR_COMMAND"
    "TLDR_COLOR_PARAMETER"
  ];

  failures =
    lib.concatMap (
      k:
      lib.optional (!(vars ? ${k})) "${k} is not set"
      ++ lib.optional (lib.elem (vars.${k} or "") state) "${k} is ${vars.${k}}, a state color"
      ++ lib.optional (!lib.elem (vars.${k} or "") accepted) "${k} is ${vars.${k} or "unset"}"
    ) keys
    ++ lib.optional (vars.TLDR_COLOR_COMMAND or "" != "cyan") "a command is not Teal (cyan)"
    ++ lib.optional (vars.TLDR_COLOR_PARAMETER or "" != "underline") "a placeholder is not underlined";
in
pkgs.runCommand "theme-tldr" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
