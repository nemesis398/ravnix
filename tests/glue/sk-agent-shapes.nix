# Which end of the security key's agent each shape is, evaluated, with the
# template's values: the laptop shape runs the agent and its loader as user
# units, on ravnix.skAgent.socket, and leaves ssh alone; the server shape
# runs no agent, lets sshd replace a forwarded socket left behind, and puts
# the configuration for the git hosts first in the user's ~/.ssh/config,
# before anything another module adds there. A host with no values does
# nothing at either end; a server with git hosts and no keys is refused by
# name; a key that is not a security key's gets a warning that names it.
# tests/glue/sk-agent.nix runs all of it.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  user = (import ../../templates/default/me.nix).ravnix.user.username;
  quiet = {
    system.stateVersion = "26.05";
    warnings = lib.mkForce [ ];
  };
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = hostModules ++ [ { nixpkgs.hostPlatform = lib.mkDefault system; } ] ++ modules;
    };
  # The laptop brings its own boot and disks, so only the template's values.
  buildLaptop =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        quiet
        self.nixosModules.laptop
        self.nixosModules.hardware-ideapad-pro-5-16ahp9
      ]
      ++ modules;
    };

  none = {
    ravnix.skAgent = {
      keys = lib.mkForce [ ];
      hosts = lib.mkForce [ ];
    };
  };
  # A plain key where a security key's belongs, as tests/glue/sk-agent.nix
  # has it.
  plainKey = {
    ravnix.skAgent.keys = lib.mkForce [
      {
        handle = "/home/${user}/.ssh/keys/plain";
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey plain";
      }
    ];
  };

  laptop = buildLaptop [ ];
  laptopNone = buildLaptop [ none ];
  server = build [ self.nixosModules.server ];
  serverNone = build [ self.nixosModules.server none ];
  serverNoKeys = build [
    self.nixosModules.server
    { ravnix.skAgent.keys = lib.mkForce [ ]; }
  ];
  # The warnings of a host, without the helper's mkForce [ ], which hides
  # them.
  serverPlain = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../templates/default/me.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        nixpkgs.hostPlatform = lib.mkDefault system;
      }
      self.nixosModules.server
      plainKey
    ];
  };

  home = s: s.config.home-manager.users.${user};
  units = s: (home s).systemd.user.services;
  sshConfig = s: (home s).home.file.".ssh/config".text or "";
  hasAgent = s: (units s) ? sk-agent || (units s) ? sk-agent-keys;
  firstLine = s: lib.head (lib.splitString "\n" (sshConfig s));
  includesOurs =
    s:
    (home s).programs.ssh.enable && builtins.match "Include /nix/store/[a-z0-9]{32}-sk-agent-ssh-config" (firstLine s) != null;
  failedOf = s: map (a: a.message) (lib.filter (a: !a.assertion) s.config.assertions);
  unlink = s: s.config.services.openssh.settings.StreamLocalBindUnlink or null;

  agent = (units laptop).sk-agent or { };
  # home-manager keeps a directive as a list of its values.
  agentStart = lib.concatStringsSep " " (lib.toList (agent.Service.ExecStart or [ ]));
  loader = (units laptop).sk-agent-keys or { };

  check = cond: msg: lib.optional (!cond) msg;
  failures =
    check (hasAgent laptop) "the laptop shape runs no sk-agent with the template's keys"
    ++ check (lib.hasInfix "/bin/ssh-agent -D -P none -a %t/sk-agent.sock" agentStart)
      "sk-agent does not run ssh-agent in the foreground on %t/sk-agent.sock: ${agentStart}"
    ++ check (lib.elem "sk-agent-keys.service" (lib.toList (agent.Unit.Wants or [ ]))) "sk-agent does not pull in its loader"
    ++ check (lib.elem "sk-agent.service" (lib.toList (loader.Unit.BindsTo or [ ]))) "sk-agent-keys is not bound to sk-agent"
    ++ check (lib.elem "default.target" (lib.toList (agent.Install.WantedBy or [ ]))) "sk-agent does not start with the user's session"
    ++ check (!lib.hasInfix "sk-agent" (sshConfig laptop)) "the laptop's ~/.ssh/config has the server's sk-agent configuration"
    ++ check (!(hasAgent server)) "the server shape runs an sk-agent of its own"
    ++ check (includesOurs server) "the server's ~/.ssh/config does not begin with the sk-agent configuration: ${firstLine server}"
    ++ check (unlink server == true) "the server's sshd does not replace a forwarded socket left behind"
    ++ check (failedOf server == [ ]) "the server shape with the template's values fails: ${lib.concatStringsSep "; " (failedOf server)}"
    ++ check (failedOf laptop == [ ]) "the laptop shape with the template's values fails: ${lib.concatStringsSep "; " (failedOf laptop)}"
    ++ check (!(hasAgent laptopNone)) "a laptop without keys runs an sk-agent"
    ++ check (!(includesOurs serverNone)) "a server without git hosts includes the sk-agent configuration"
    ++ check (lib.any (lib.hasInfix "ravnix.skAgent.keys") (failedOf serverNoKeys))
      "a server with git hosts and no keys is not refused by ravnix.skAgent.keys"
    ++ check (lib.any (lib.hasPrefix "ravnix.skAgent.keys[0].publicKey is an ssh-ed25519 key") serverPlain.config.warnings)
      "a plain key in ravnix.skAgent.keys gets no warning that names it";
in
pkgs.runCommand "glue-sk-agent-shapes" { } (
  if failures == [ ] then
    ''
      # What the server's ssh reads, built: the git hosts' block and its guard.
      config=${lib.removePrefix "Include " (firstLine server)}
      grep -qx 'Match host github.com,git.example.org !exec ".*/bin/sk-agent-check /run/user/%i/sk-agent.sock %h"' "$config"
      grep -qx 'Host github.com git.example.org' "$config"
      grep -qx '  IdentityAgent /run/user/%i/sk-agent.sock' "$config"
      grep -qx '  IdentitiesOnly yes' "$config"
      [ "$(grep -c '^  IdentityFile /nix/store/' "$config")" = 1 ]
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
