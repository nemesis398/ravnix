# The vault on both hosts: how a vault skill commits. The vault's git
# history is on the server, muninn, where the agents write; plain edits
# travel through the file sync on both hosts, and the laptop, huginn, has a
# copy of the vault without its .git. So an agent on the laptop writes
# files and never commits there; it asks the server.
#
# The one entry point is `vault-commit MESSAGE [PATH...]` (./vault/,
# installed on both shapes). It reads vault.commitVia from the skill values
# (~/.config/ravnix/skill-values.json), which this module sets by the
# host's shape, as a default that the private flake may override:
#
#   server  git           git add and git commit in ravnix.link.vault,
#                         where the repository is
#   laptop  ravnix-link   `ravnix-link vault-commit`, which sends the
#                         commit to the server with the SHA-256 of each
#                         file; the server commits once its copy has them
#                         (./link.nix, tools/ravnix-link/README.md)
#
# A skill reads vault.commitVia when it must know whether the commit is
# made here, and calls vault-commit either way. On the server,
# `ravnix-link vault-commit` (commitVia = "ravnix-link" there too) would
# order the commit after the Obsidian operations queued for the laptop;
# git, the default, commits at once.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  shape = os.ravnix.shape;
  user = os.ravnix.user.username;
  vaultCommit = import ./vault/scripts.nix {
    inherit lib pkgs;
    vault = os.ravnix.link.vault;
    link = lib.getExe os.ravnix.link.command;
  };
in
{
  config = lib.mkIf (shape != null) {
    ravnix.claude.skillValues.vault.commitVia = lib.mkDefault (
      if shape == "server" then "git" else "ravnix-link"
    );
    home-manager.users.${user}.home.packages = [ vaultCommit ];
  };
}
