# A service is placed by naming a host of ravnix.hosts, and clients read only
# its derived url. A service whose host names an undeclared host fails with a
# message naming both, enabled or not; the url follows the host when the
# service moves, puts an IPv6 address in brackets, and cannot be set by hand.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;
  with' = modules: eval ([ template ] ++ modules);

  service = host: {
    ravnix.services.paperless = {
      enable = true;
      inherit host;
      port = 8000;
    };
  };
  hosts = {
    ravnix.hosts = {
      box-a = {
        address = "198.51.100.7";
        runtime = "docker";
      };
      box-b = {
        address = "2001:db8::7";
        runtime = "proxmox-ct";
      };
      box-c = {
        address = "cache.example.org";
        runtime = "external";
      };
    };
  };
  urlOn =
    host:
    (with' [
      hosts
      (service host)
    ]).config.ravnix.services.paperless.url;

  unknown = with' [ (service "nowhere") ];
  naming = lib.filter (
    m: lib.hasInfix "ravnix.services.paperless" m && lib.hasInfix "\"nowhere\"" m
  ) unknown.failed;
  unknownUrl = builtins.tryEval unknown.config.ravnix.services.paperless.url;

  # Disabled or not, an undeclared host is a mistake.
  disabled = with' [
    {
      ravnix.services.paperless = {
        enable = false;
        host = "nowhere";
        port = 8000;
      };
    }
  ];

  # The url is derived; a definition of it is refused.
  setByHand = with' [
    hosts
    (service "box-a")
    { ravnix.services.paperless.url = "http://198.51.100.99:1"; }
  ];
  setUrl = builtins.tryEval (builtins.deepSeq setByHand.config.ravnix.services true);

  expect =
    host: want:
    let
      got = builtins.tryEval (urlOn host);
    in
    lib.optional (!got.success || got.value != want)
      "a service on ${host} should have the url ${want}, got ${
        if got.success then got.value else "an error"
      }";

  failures =
    lib.optional (naming == [ ])
      "no failed assertion names both the service and the missing host; failed: ${toString unknown.failed}"
    ++ lib.optional unknownUrl.success "the url of a service on an undeclared host evaluated"
    ++ lib.optional (
      lib.filter (
        m: lib.hasInfix "ravnix.services.paperless" m && lib.hasInfix "\"nowhere\"" m
      ) disabled.failed == [ ]
    ) "a disabled service on an undeclared host passed the assertions"
    ++ lib.optional setUrl.success "ravnix.services.paperless.url was set by hand and accepted"
    ++ expect "box-a" "http://198.51.100.7:8000"
    ++ expect "box-b" "http://[2001:db8::7]:8000"
    ++ expect "box-c" "http://cache.example.org:8000";
in
pkgs.runCommand "options-unknown-host" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
