# Malformed values are refused when they are read, not passed on to the
# tools that would choke on them later; and the unusual values that are
# right (an umlaut in a name, a security-key signing key, a room id without
# a server part) are accepted, so the checks are not stricter than the world.
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
    (eval [
      template
      (force module)
    ]).values.success;

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
