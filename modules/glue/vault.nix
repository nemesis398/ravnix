# The vault on both hosts: how a vault skill commits. The vault's git
# history is on the server, muninn, where the agents write; plain edits
# travel through the file sync on both hosts, and the laptop, huginn, has a
# copy of the vault without its .git. So an agent on the laptop writes
# files and never commits there; it asks the server.
#
# The one entry point is `vault-commit MESSAGE [PATH...]` (./vault/,
# installed on both shapes). It reads vault.commitVia from the skill values
# (~/.config/ravnix/skill-values.json). This module sets it to ravnix-link
# on both shapes, as a default the private flake may override, and sets
# vault.repositoryHere, which says where the history is:
#
#   server  ravnix-link, repositoryHere = true: `ravnix-link vault-commit`
#           commits in ravnix.link.vault, in the queue of the link, so a
#           commit waits for the Obsidian operations queued before it (the
#           design's rule: a pending rename and a later edit cannot cross),
#           and it never runs git beside the delivery service, which
#           commits the laptop's requests in the same repository. When
#           nothing waits it commits at once, in the caller's process.
#   laptop  ravnix-link, repositoryHere = false: `ravnix-link vault-commit`
#           sends the commit to the server with the SHA-256 of each file;
#           the server commits once its copy has them (./link.nix,
#           tools/ravnix-link/README.md).
#
# The other value, git, commits at once with git in ravnix.link.vault. It
# is for a host whose vault no ravnix-link serves. On a ravnix server it
# gives up what the queue gives: the order after queued Obsidian operations,
# and one git at a time with the delivery service (a run may fail on git's
# index.lock, or take what the service has staged).
#
# For the skills: commit with vault-commit, never with git commit. On the
# laptop name the files (no folder, no commit of what is staged), and read
# exit 1 as "the server did not answer, ask again later": nothing queues
# on the laptop. Exit 0 may mean queued; vault.repositoryHere says whether
# `git log` here shows the commit.
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
    git = lib.getExe os.ravnix.link.programs.git;
  };
in
{
  config = lib.mkIf (shape != null) {
    ravnix.claude.skillValues.vault = {
      commitVia = lib.mkDefault "ravnix-link";
      repositoryHere = lib.mkDefault (shape == "server");
    };
    home-manager.users.${user}.home.packages = [ vaultCommit ];
  };
}
