# A value reserved for documentation (RFC 5737, RFC 3849, RFC 2606) left in
# me.nix gets a warning that names its option, so a forgotten placeholder
# shows in every build. The template, made of such values, warns for each;
# a value that only looks like one (192.0.20.1, notexample.org,
# 2001:db80::1) and every real-looking value does not. A service's derived
# url is not reported again.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;

  withService = eval [
    template
    {
      ravnix.services.paperless = {
        enable = true;
        host = "nas";
        port = 8000;
      };
    }
  ];
  named = option: lib.any (lib.hasPrefix "${option} is ") withService.config.warnings;

  # The template's placeholders, one per kind of value.
  expected = [
    "ravnix.user.email"
    "ravnix.user.signingKey"
    "ravnix.hosts.huginn.address"
    "ravnix.hosts.muninn.sshTarget"
    "ravnix.hosts.nas.sshTarget"
    "ravnix.server.netbirdAddress"
    "ravnix.secrets.rbwBaseUrl"
    "ravnix.matrix.homeserver"
    "ravnix.matrix.rooms.sessions.botUser"
  ];

  # One value at a time, in a skill value, which takes any string.
  warnsFor =
    value:
    lib.any (lib.hasPrefix "ravnix.claude.skillValues.probe is ")
      (eval [
        template
        { ravnix.claude.skillValues.probe = value; }
      ]).config.warnings;
  placeholders = [
    "192.0.2.1"
    "198.51.100.200"
    "203.0.113.9"
    "alice@198.51.100.10"
    "2001:db8::1"
    "2001:DB8:0:1::5"
    "2001:0db8::1"
    "alice@example.org"
    "https://vault.example.net/x"
    "nas.example.com"
    "NAS.EXAMPLE.ORG"
    "cache.example.org-1:abc"
    "muninn.example.org."
  ];
  real = [
    "10.20.30.40"
    "192.0.20.1"
    "100.64.1.2"
    "2001:db80::1"
    "fd00::1"
    "nas.home.arpa"
    "alice@mailbox.org"
    "notexample.org"
    "my-example.com"
    "example.organic"
    "example.com.au"
    "Example Corp Monitor 0x00000000"
  ];

  inList =
    (eval [
      template
      {
        ravnix.claude.skillValues.list = [
          "x"
          "192.0.2.1"
        ];
      }
    ]).config.warnings;

  failures =
    map (option: "no warning names ${option}") (lib.filter (o: !(named o)) expected)
    ++ lib.optional (named "ravnix.services.paperless.url") "the derived url of a service is reported as well"
    ++ map (w: "a warning does not start with the option it names: ${w}") (
      lib.filter (w: !(lib.hasPrefix "ravnix." w)) withService.config.warnings
    )
    ++ map (v: "no warning for the placeholder ${v}") (lib.filter (v: !(warnsFor v)) placeholders)
    ++ map (v: "a warning for the real-looking ${v}") (lib.filter warnsFor real)
    ++ lib.optional (
      !(lib.any (lib.hasPrefix "ravnix.claude.skillValues.list[1] is ") inList)
    ) "a placeholder in a list is not named by its index";
in
pkgs.runCommand "options-placeholders" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
