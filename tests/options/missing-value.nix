# A value the user must set and did not makes the evaluation fail with a
# message that names the option: the template's me.nix without
# ravnix.user.email fails one assertion, naming ravnix.user.email, and the
# wrapper that refuses like a host build does is caught by builtins.tryEval.
# With nothing set at all, every value without a default is named, each in
# its own message, so a new user sees the whole list at once.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = import ../../templates/default/me.nix;

  withoutEmail = eval [
    (
      template
      // {
        ravnix = template.ravnix // {
          user = builtins.removeAttrs template.ravnix.user [ "email" ];
        };
      }
    )
  ];
  naming = lib.filter (lib.hasInfix "ravnix.user.email") withoutEmail.failed;
  refused = builtins.tryEval (builtins.seq withoutEmail.ok true);
  read = builtins.tryEval withoutEmail.config.ravnix.user.email;

  # The values without a default. A default added to one of them, or a new
  # option without one, shows up here.
  required = [
    "ravnix.user.name"
    "ravnix.user.email"
    "ravnix.user.username"
    "ravnix.user.githubUser"
    "ravnix.user.signingKey"
    "ravnix.server.sshTarget"
    "ravnix.server.netbirdAddress"
    "ravnix.vpn.netbird.managementUrl"
    "ravnix.laptop.diskModel"
    "ravnix.laptop.diskSerial"
    "ravnix.secrets.rbwBaseUrl"
    "ravnix.secrets.rbwEmail"
    "ravnix.matrix.homeserver"
    "ravnix.backup.retentionFile"
    "ravnix.dictionary.file"
  ];
  empty = eval [ ];
  unnamed = lib.filter (
    path: !(lib.any (m: lib.hasPrefix "${path} is not set" m) empty.failed)
  ) required;

  failures =
    lib.optional (
      naming == [ ]
    ) "without ravnix.user.email, no failed assertion names it; failed: ${toString withoutEmail.failed}"
    ++
      lib.optional (lib.length withoutEmail.failed != 1)
        "only ravnix.user.email is missing, but ${toString (lib.length withoutEmail.failed)} assertions failed: ${toString withoutEmail.failed}"
    ++ lib.optional refused.success "the evaluation without ravnix.user.email was not refused"
    ++ lib.optional read.success "reading the unset ravnix.user.email gave a value"
    ++ map (path: "with nothing set, no message says that ${path} is not set") unnamed
    ++
      lib.optional (lib.length empty.failed != lib.length required)
        "with nothing set, expected ${toString (lib.length required)} failed assertions, got ${toString (lib.length empty.failed)}: ${lib.concatStringsSep " / " empty.failed}";
in
pkgs.runCommand "options-missing-value" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
