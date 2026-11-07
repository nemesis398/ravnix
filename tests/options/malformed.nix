# Malformed values are refused, by their type when they are read or by an
# assertion, not passed on to the tools that would choke on them later; and
# the unusual values that are right (an umlaut in a name, a security-key
# signing key, a room id without a server part) are accepted, so the checks
# are not stricter than the world.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;
  # Each case replaces the template's value instead of adding a second,
  # conflicting one, which would be refused for the wrong reason.
  force = lib.mapAttrsRecursive (_: lib.mkForce);
  accepted =
    module:
    let
      e = eval [
        template
        (force module)
      ];
    in
    e.values.success && e.failed == [ ];

  room = roomId: botUser: {
    ravnix.matrix.rooms.sessions = { inherit roomId botUser; };
  };
  host = attrs: {
    ravnix.hosts.box = {
      address = "192.0.2.50";
      runtime = "docker";
    }
    // attrs;
  };
  port = n: {
    ravnix.services.paperless = {
      enable = true;
      host = "nas";
      port = n;
    };
  };
  server = attrs: { ravnix.server = attrs; };
  retention = name: {
    ravnix.backup.retentionFile = ./fixtures/retention + "/${name}.toml";
  };
  output = attrs: {
    ravnix.laptop.kanshiProfiles = [
      {
        name = "desk";
        outputs = [
          (
            {
              criteria = "eDP-1";
            }
            // attrs
          )
        ];
      }
    ];
  };

  refused = {
    "an empty name" = {
      ravnix.user.name = "";
    };
    "a name of blanks" = {
      ravnix.user.name = "   ";
    };
    "a mail address without @" = {
      ravnix.user.email = "alice.example.org";
    };
    "a user name with a capital and a space" = {
      ravnix.user.username = "Alice Example";
    };
    "a user name longer than 32 characters" = {
      ravnix.user.username = "a234567890123456789012345678901234";
    };
    "a GitHub user name with a space" = {
      ravnix.user.githubUser = "alice example";
    };
    "a signing key with git's key:: prefix" = {
      ravnix.user.signingKey = "key::ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnly";
    };
    "a signing key without its type" = {
      ravnix.user.signingKey = "AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnly";
    };
    "a checkout given as a Nix path, which would copy it into the store" = {
      ravnix.dev.checkout = ./.;
    };
    "a relative deny list path" = {
      ravnix.dev.denyList = "deny-list.txt";
    };
    "a dictionary given as a Nix path, a read-only copy in the store" = {
      ravnix.dictionary.file = ./helpers/eval.nix;
    };
    "a relative dictionary path" = {
      ravnix.dictionary.file = "dictionary.txt";
    };
    "a host runtime ravnix does not know" = host { runtime = "kubernetes"; };
    "a host address with a scheme" = host { address = "http://192.0.2.50"; };
    "a host address with a prefix length" = host { address = "192.0.2.50/24"; };
    "an IPv4 host address with a port" = host { address = "192.0.2.50:8080"; };
    "a host name with a port" = host { address = "nas.example.org:22"; };
    "an empty host address" = host { address = ""; };
    "a host address with a leading dash, which ssh reads as an option" = host { address = "-v"; };
    "a NetBird address with the /16 that netbird status prints" = server {
      netbirdAddress = "100.64.1.2/16";
    };
    "a NetBird address with a scheme" = server { netbirdAddress = "http://100.64.1.2"; };
    "an ssh target with options after it" = server { sshTarget = "alice@host -p 22"; };
    "an ssh command instead of a target" = server { sshTarget = "ssh alice@192.0.2.20 -p 22"; };
    "an ssh target with a leading dash" = server { sshTarget = "-oProxyCommand=evil"; };
    "an ssh target with another scheme" = server { sshTarget = "https://muninn.example.org"; };
    "an ssh target with two @" = server { sshTarget = "alice@bob@host"; };
    "an ssh URL with a port of six digits" = server { sshTarget = "ssh://alice@host:220022"; };
    "an ssh URL with an IPv6 address outside brackets" = server {
      sshTarget = "ssh://alice@2001:db8::1:22";
    };
    "a host's ssh target with options after it" = host { sshTarget = "admin@nas -p 22"; };
    "a retention file given as an absolute path in a string" = {
      ravnix.backup.retentionFile = "/etc/hostname";
    };
    "a negative retention count" = retention "negative";
    "a retention count with a fraction" = retention "fraction";
    "a retention file without the internxt target" = retention "missing-target";
    "a retention target ravnix does not back up to" = retention "unknown-target";
    "a misspelt retention key" = retention "misspelt-key";
    "a target that keeps nothing" = retention "keeps-nothing";
    "a host override that keeps nothing" = retention "host-keeps-nothing";
    "a misspelt key in a host override" = retention "host-misspelt-key";
    "a disabled service on an undeclared host" = {
      ravnix.services.paperless = {
        enable = false;
        host = "nowhere";
        port = 8000;
      };
    };
    "port 0" = port 0;
    "port 65536" = port 65536;
    "a homeserver without a scheme" = {
      ravnix.matrix.homeserver = "matrix.example.org";
    };
    "an rbw base URL with a space" = {
      ravnix.secrets.rbwBaseUrl = "https://vault example.org";
    };
    "a room id without the leading !" = room "sessions" "@ravnix-sessions:example.org";
    "an empty room id instead of null" = room "" "@ravnix-sessions:example.org";
    "a bot user without its server" = room null "@ravnix-sessions";
    "a bot user without the leading @" = room null "ravnix-sessions:example.org";
    "a kanshi scale of 0" = output { scale = 0; };
    "a kanshi position without a comma" = output { position = "0x0"; };
    "a kanshi mode that is no mode" = output { mode = "big"; };
    "a kanshi profile without outputs" = {
      ravnix.laptop.kanshiProfiles = [
        {
          name = "none";
          outputs = [ ];
        }
      ];
    };
    "a skill value that is a function, which JSON cannot hold" = {
      ravnix.claude.skillValues.hook = x: x;
    };
  };

  allowed = {
    "the template as it is" = { };
    "a name with umlauts" = {
      ravnix.user.name = "Zoë Ångström-Ünal";
    };
    "a user name with _ and -" = {
      ravnix.user.username = "_alice-2";
    };
    "a security-key signing key with a comment" = {
      ravnix.user.signingKey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExampleOnly alice@laptop";
    };
    "an IPv6 host address" = host { address = "2001:db8::50"; };
    "a host name as address" = host { address = "nas.example.org"; };
    "a host reached over ssh" = host { sshTarget = "admin@nas.example.org"; };
    "a host reached by an ssh alias" = host { sshTarget = "nas"; };
    "a host reached as user@IPv4" = host { sshTarget = "admin@192.0.2.50"; };
    "a bare NetBird address" = server { netbirdAddress = "100.64.1.2"; };
    "an IPv6 NetBird address" = server { netbirdAddress = "fd00:1234::5"; };
    "an ssh target with a user" = server { sshTarget = "alice@host"; };
    "an ssh target with an underscore in the user" = server { sshTarget = "nas_admin@192.0.2.20"; };
    "an ssh alias as target" = server { sshTarget = "muninn"; };
    "an ssh target at an IPv6 address" = server { sshTarget = "alice@2001:db8::1"; };
    "an ssh URL with a port" = server { sshTarget = "ssh://alice@host:2222"; };
    "an ssh URL with an IPv6 address in brackets" = server {
      sshTarget = "ssh://alice@[2001:db8::1]:22";
    };
    "a retention file with a host override" = retention "host-override";
    "a disabled service on a declared host" = {
      ravnix.services.paperless = {
        enable = false;
        host = "nas";
        port = 8000;
      };
    };
    "port 65535" = port 65535;
    "a room id of room version 12, without a server part" =
      room "!Abc_123-xyz" "@ravnix-sessions:example.org";
    "a room id with a server part" = room "!abcdef:example.org" "@ravnix-sessions:example.org";
    "a room that does not exist yet" = room null "@ravnix-sessions:example.org";
    "a kanshi output disabled, by description" = output {
      criteria = "Example Corp Monitor 0x00000000";
      status = "disable";
    };
    "a kanshi output at a negative position, scale 1" = output {
      position = "-1920,0";
      scale = 1;
      mode = "1920x1080@59.94Hz";
    };
    "a kanshi mode with its rate but no Hz" = output { mode = "1920x1080@60"; };
    "nested JSON skill values" = {
      ravnix.claude.skillValues = {
        vault.root = "/home/alice/notes";
        plane.projects = [
          "a"
          null
          1
          true
          1.5
        ];
      };
    };
  };

  failures =
    lib.mapAttrsToList (what: _: "accepted ${what}") (lib.filterAttrs (_: accepted) refused)
    ++ lib.mapAttrsToList (what: _: "refused ${what}") (lib.filterAttrs (_: m: !(accepted m)) allowed);
in
pkgs.runCommand "options-malformed" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
