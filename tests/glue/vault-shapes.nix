# The vault on the two shapes (modules/glue/vault.nix and the laptop's end
# of modules/glue/link.nix), evaluated as the private flake builds them,
# with the template's values: vault.commitVia of the skill values is git on
# the server and ravnix-link on the laptop, in the user's home-manager
# configuration, which renders skill-values.json; a value of the private
# flake wins, and the other skill values stay. vault-commit is in the
# user's profile on both, with the host's ravnix-link: the server's, which
# commits in the vault, and the laptop's, which reads its copy of the vault
# and sends the commit to the server with a fixed remote command. The VMs
# of tests/glue/link.nix run it.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user.username;
  vault = (import me).ravnix.link.vault;
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    };
  server = [ self.nixosModules.server ];
  laptop = [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  m = (build server).config;
  h = (build laptop).config;
  # The private flake's values: its own commitVia on the server, and other
  # keys beside it.
  mOwn = (build (server ++ [
    {
      ravnix.claude.skillValues = {
        vault.commitVia = "ravnix-link";
        vault.root = "/home/alice/notes";
        nextcloud.root = "/home/alice/cloud";
      };
    }
  ])).config;
  hOther = (build (laptop ++ [
    {
      ravnix.claude.skillValues = {
        vault.root = "/home/alice/notes";
        nextcloud.root = "/home/alice/cloud";
      };
    }
  ])).config;
  hNoVault = (build (laptop ++ [ { ravnix.link.vault = lib.mkForce null; } ])).config;

  check = cond: msg: lib.optional (!cond) msg;
  plain = builtins.unsafeDiscardStringContext;
  infix = a: b: lib.hasInfix (plain a) (plain b);
  values = c: c.home-manager.users.${user}.ravnix.claude.skillValues;
  via = c: (values c).vault.commitVia or null;
  homeNamed = name: c: lib.filter (p: lib.getName p == name) c.home-manager.users.${user}.home.packages;
  text = p: p.text or "";
  one = name: c: lib.head (homeNamed name c ++ [ { } ]);
  # The forward the laptop's ravnix-link names (link.nix keeps it on the
  # command, as forward).
  forwardText = c: text (c.ravnix.link.command.forward or { });

  failures =
    check (via m == "git") "vault.commitVia on the server is ${toString (via m)}, not git"
    ++ check (via h == "ravnix-link") "vault.commitVia on the laptop is ${toString (via h)}, not ravnix-link"
    ++ check (m.ravnix.claude.skillValues.vault.commitVia or null == "git") "the server's NixOS skill values have no vault.commitVia"
    ++ check (via mOwn == "ravnix-link") "the private flake's vault.commitVia does not win on the server"
    ++ check ((values mOwn).vault.root or null == "/home/alice/notes") "the shape's vault.commitVia hides vault.root"
    ++ check ((values mOwn).nextcloud.root or null == "/home/alice/cloud") "the shape's vault.commitVia hides nextcloud.root"
    ++ check (via hOther == "ravnix-link" && (values hOther).vault.root or null == "/home/alice/notes") "vault.commitVia and vault.root do not merge on the laptop"

    # vault-commit, with each host's ravnix-link.
    ++ check (lib.length (homeNamed "vault-commit" m) == 1) "the server has no vault-commit"
    ++ check (lib.length (homeNamed "vault-commit" h) == 1) "the laptop has no vault-commit"
    ++ check (infix "${lib.getExe m.ravnix.link.command}" (text (one "vault-commit" m))) "the server's vault-commit does not run the server's ravnix-link"
    ++ check (infix "${lib.getExe h.ravnix.link.command}" (text (one "vault-commit" h))) "the laptop's vault-commit does not run the laptop's ravnix-link"
    ++ check (infix "--vault ${vault}" (text m.ravnix.link.command)) "the server's ravnix-link does not know the vault"
    ++ check (infix ":-${vault}}" (text (one "vault-commit" m))) "the server's vault-commit does not know the vault"

    # The laptop's ravnix-link: its copy of the vault, and the forward.
    ++ check (h.ravnix.link.command != null && lib.getName h.ravnix.link.command == "ravnix-link") "the laptop has no ravnix-link command"
    ++ check (homeNamed "ravnix-link" h == [ h.ravnix.link.command ]) "the laptop's ravnix-link on the PATH is not the one with the forward"
    ++ check (infix "--vault ${vault}" (text h.ravnix.link.command)) "the laptop's ravnix-link does not know its copy of the vault"
    ++ check (infix "--forward " (text h.ravnix.link.command)) "the laptop's ravnix-link has no forward"
    ++ check (!infix "--vault" (text hNoVault.ravnix.link.command)) "a laptop without a vault still passes --vault"
    ++ check (!infix "--forward" (text m.ravnix.link.command)) "the server's ravnix-link forwards"
    ++ check (infix "--forward ${lib.getExe (h.ravnix.link.command.forward or pkgs.hello)}" (text h.ravnix.link.command)) "the laptop's ravnix-link does not name its forward"
    ++ check (
      infix "-T -o BatchMode=yes -- ravnix-server /run/current-system/sw/bin/ravnix-link receive" (forwardText h)
    ) "the laptop's forward is not ssh to ravnix-server with the fixed command ravnix-link receive";
in
pkgs.runCommand "glue-vault-shapes" { } (
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
