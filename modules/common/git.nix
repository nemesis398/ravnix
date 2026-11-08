# git as the Fedora laptop has it, with the identity from ravnix.user: commits
# are signed with the user's SSH key, whose private half stays in the user's
# Bitwarden vault and is served by rbw's agent (modules/common/rbw.nix), and
# diffs go through delta. The checkout of ravnix that ravnix.dev.checkout
# names gets its git hooks turned on by the activation.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.ravnix) user dev;
  devCheckout = pkgs.callPackage ./dev-checkout.nix { };
in
{
  programs.git = {
    enable = true;

    signing = {
      format = "ssh";
      # The public key as a literal (the key:: prefix): ssh-keygen finds the
      # private half in the agent at the moment of signing.
      key = "key::${user.signingKey}";
      signByDefault = true;
      # Verification needs the signer's address next to the key, or git
      # cannot verify the user's own signatures ("No principal matched").
      allowedSigners = "${user.email} ${user.signingKey}\n";
    };

    settings = {
      user = {
        name = user.name;
        email = user.email;
      };

      core = {
        pager = "delta";
        editor = "nvim";
      };
      interactive.diffFilter = "delta --color-only";

      delta = {
        syntax-theme = "Catppuccin Mocha";
        line-numbers = true;
        # n and N jump between files in the pager.
        navigate = true;
        minus-style = "red bold";
        plus-style = "green bold";
        # The attribute is `line-number`, not `line`: a bare `line` makes
        # delta abort with "Invalid color or style attribute: line".
        hunk-header-style = "file line-number bold yellow";
      };

      diff = {
        tool = "delta";
        colorMoved = "default";
        algorithm = "histogram";
        # A hunk header of a shell script shows the enclosing function, not
        # the nearest line in column 0 (git has no driver for shell).
        # Referenced by `*.sh diff=bash` in the attributes below.
        bash.xfuncname = ''^([[:alpha:]_][[:alnum:]_]* *\(\)|function +[[:alpha:]_][[:alnum:]_]*)'';
      };
      difftool = {
        prompt = false;
        delta.cmd = ''delta "$LOCAL" "$REMOTE"'';
      };

      merge = {
        conflictstyle = "zdiff3";
        # git's built-in three-way Neovim layout, no plugin needed.
        tool = "nvimdiff";
      };

      init.defaultBranch = "main";

      push = {
        # The first push creates the upstream: no -u dance.
        autoSetupRemote = true;
        followTags = true;
      };
      fetch = {
        # Drop remote-tracking refs and tags deleted upstream.
        prune = true;
        pruneTags = true;
      };
      # Pull only fast-forwards; when the branches diverged, stop and let me
      # choose merge or rebase.
      pull.ff = "only";
      rebase = {
        # Stash and pop around the rebase that a refused pull falls back to.
        autoStash = true;
        # Carry stacked local branches along in an interactive rebase.
        updateRefs = true;
      };
      # Record and replay conflict resolutions.
      rerere.enabled = true;
      # The full diff in the commit message buffer.
      commit.verbose = true;
      # Multi-column `git branch` and `git status` on a wide terminal.
      column.ui = "auto";
      # Most recently used branches first, and v1.2.0 before v1.10.0.
      branch.sort = "-committerdate";
      tag.sort = "version:refname";

      alias = {
        st = "status -sb";
        lg = "log --oneline --graph --decorate -20";
        last = "log -1 --stat";
        ds = "diff --staged";
        unstage = "restore --staged --";
        # Drop the last commit and keep its changes staged.
        undo = "reset --soft HEAD~1";
        # Rewrites the commit: not after pushing it.
        amend = "commit --amend --no-edit";
        root = "rev-parse --show-toplevel";
        # Local branches whose upstream is gone. Pairs with fetch.prune,
        # which removes the stale remote-tracking refs first.
        gone = "!git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads | awk '$2 ~ /gone/ {print $1}'";
      };
    };

    ignores = [
      # Editors and tools.
      "*~"
      # Vim and Neovim swap files: .swp, .swo, .swn, ...
      "*.sw[a-p]"
      ".direnv/"
      # A mergetool leaves <file>.orig, a failed `git apply` or `git am`
      # leaves *.rej.
      "*.orig"
      "*.rej"
      ".DS_Store"
      "**/.claude/settings.local.json"
      # Worktrees that Claude Code makes inside a repository: unignored they
      # count as untracked files.
      "**/.claude/worktrees/"
    ];

    # Hunk headers (`@@ ... @@ <context>`) show the enclosing section or
    # function instead of git's generic guess. markdown is built in; bash is
    # the diff.bash driver above.
    attributes = [
      "*.md diff=markdown"
      "*.sh diff=bash"
    ];
  };

  programs.delta.enable = true;

  programs.gh.enable = true;

  # Turn the hooks of the user's own checkout of ravnix on, and point them at
  # the deny list. Each switch does it again, so a checkout cloned later is
  # picked up by the next switch, or by `systemctl restart
  # home-manager-USER.service` straight after the clone. One that is not there
  # yet is no error, but a warning in the journal of that service: until then
  # the checkout has no hooks and no boundary check.
  home.activation = lib.mkIf (dev.checkout != null) {
    ravnixDevCheckout = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe devCheckout} ${lib.escapeShellArg dev.checkout}${
        lib.optionalString (dev.denyList != null) " ${lib.escapeShellArg dev.denyList}"
      }
    '';
  };
}
