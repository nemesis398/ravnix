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
  inherit (config.ravnix.theme) palette roles;
  color = import ../theme/color.nix { inherit lib; };
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

      # The diff is a wash of its state hue over Base with the syntax colors
      # kept (docs/style.md: a row is a wash), the changed words a stronger
      # one, and delta's Blue file names and boxes are gone, since Blue is the
      # busy state: a file name is Subtext1, a hunk's position the accent, a
      # frame Surface2. The hex colors are the roles' and the washes the
      # theme's arithmetic (modules/theme/color.nix).
      delta =
        let
          wash =
            percent: hue:
            color.mix {
              over = roles.canvas;
              tint = hue;
              inherit percent;
            };
        in
        {
          syntax-theme = "Catppuccin Mocha";
          line-numbers = true;
          # n and N jump between files in the pager.
          navigate = true;
          minus-style = "syntax ${wash 20 palette.red}";
          plus-style = "syntax ${wash 20 palette.green}";
          minus-emph-style = "bold syntax ${wash 35 palette.red}";
          plus-emph-style = "bold syntax ${wash 35 palette.green}";
          minus-empty-line-marker-style = "syntax ${wash 20 palette.red}";
          plus-empty-line-marker-style = "syntax ${wash 20 palette.green}";
          line-numbers-minus-style = palette.red;
          line-numbers-plus-style = palette.green;
          line-numbers-zero-style = roles.muted;
          line-numbers-left-style = roles.line;
          line-numbers-right-style = roles.line;
          file-style = "bold ${roles.label}";
          file-decoration-style = "${roles.line} ul";
          # The attribute is `line-number`, not `line`: a bare `line` makes
          # delta abort with "Invalid color or style attribute: line". The
          # code fragment after the position is Subtext0; the position
          # itself and the file are styled apart, or delta draws them Blue.
          hunk-header-style = "file line-number bold ${roles.secondary}";
          hunk-header-file-style = "bold ${roles.label}";
          hunk-header-line-number-style = "bold ${roles.accent}";
          hunk-header-decoration-style = "${roles.line} box";
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
