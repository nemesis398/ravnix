# bash as the Fedora laptop has it, ported from its .bashrc: the history, the
# aliases, the functions, the tools' shell integrations in the order they need
# (bash-preexec, starship, zoxide, fzf, atuin), the readline keyboard layer,
# and ai-unlock with the `claude` function. The functions are real files in
# ./bash, so shellcheck reads them and the tests source them.
#
# The order of the interactive part is the Fedora one, and it matters:
# the seam first (ravnix.shell.autoAttach), then the SWAYSOCK repair, the
# tools, the functions, and last the aliases, at the order 5000 of initExtra,
# so that they follow what other modules add too. Home-manager writes
# programs.bash.shellAliases before everything in initExtra, so the aliases
# of this module are not there: written that way, `ls` would be eza (and
# `cd` zd, which is not defined yet) in the SWAYSOCK repair and in whatever
# the seam runs, and a function body would have an alias in it, expanded
# when the function is defined and not when it is called.
#
# Left to other modules, on purpose:
#   - the terminal auto-attach, the herdr hook and its alias `t`, which Task
#     5.2 adds through ravnix.shell.autoAttach, the seam at the top of the
#     interactive part;
#   - the ssh agent's socket, which the host's agent module sets.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.shell;
  exe = pkg: lib.getExe pkg;

  # The Fedora aliases. Tools are not tested for first: they are installed.
  aliases = {
    # `cat` is bat, or chafa for images (functions.bash). bcat is the real one,
    # pcat has no decorations at all.
    bcat = "command cat";
    pcat = "bat --plain --paging=never";
    ls = "eza -lh --group-directories-first --icons=auto";
    lsa = "ls -a";
    lt = "eza --tree --level=2 --long --icons --git";
    lta = "lt -a";
    ld = "eza --tree --level=6 --long --icons --git";
    lda = "ld -a";
    # hl PATTERN: highlight matches in a stream without dropping the other
    # lines (`journalctl -b | hl error`).
    hl = "rg --passthru";
    # A fuzzy file picker that previews the file in bat.
    ff = "fzf --preview 'bat --style=numbers --color=always {}'";
    eff = ''$EDITOR "$(ff)"'';
    # zoxide-driven cd (zd, in functions.bash).
    cd = "zd";
    ".." = "cd ..";
    "..." = "cd ../..";
    "...." = "cd ../../..";
    tl = "tldr";
    # Odin: `or` builds and runs the package in the current directory.
    or = "odin run";
    g = "git";
    gcm = "git commit -m";
    gcam = "git commit -a -m";
    gcad = "git commit -a --amend";
    gp = "git push";
  };

  # The aliases as shell code, in name order: what home-manager would write
  # for programs.bash.shellAliases, but where this module chooses (see the
  # header). The `--` keeps a name that starts with a dash from being an option.
  aliasLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: value: "alias -- ${lib.escapeShellArg name}=${lib.escapeShellArg value}"
    ) aliases
  );

  # Which variable comes from which rbw item (ravnix.shell.secretEnv), as
  # "NAME=item" in name order. The names are checked to be shell names, and
  # so hold no "="; the items are quoted.
  secretTable = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: item: lib.escapeShellArg "${name}=${item}") cfg.secretEnv
  );

  # The claude that the `claude` function starts: the one in home-manager's own
  # profile, by its absolute path, so the secrets from rbw and every fallback
  # go to the build programs.claude-code installs and never to another claude
  # that comes first on the PATH (a native install in ~/.local/bin, say). Not
  # the store path of that build: a shell reads the bashrc once and lives for
  # days (a herdr pane), and a path into one generation would keep it on the
  # Claude Code of the generation it started in, and fail with 127 once that
  # generation is collected. The profile is the same path after every switch
  # and holds the current build. Empty when Claude Code is off or has no
  # package (home-manager installs finalPackage only then, and it has no value
  # without a package), and the function starts the first claude on the PATH.
  # The module that turns Claude Code on is claude-code.nix, which
  # homeModules.common imports through homeModules.claude-skills.
  claudeBin = lib.optionalString (
    config.programs.claude-code.enable && config.programs.claude-code.package != null
  ) "${config.home.profileDirectory}/bin/claude";

  # The shell integrations of starship, zoxide, fzf and atuin, written once at
  # build time and sourced, instead of four programs started to print them in
  # every shell: it is a tenth of an interactive start. They depend on nothing
  # but the program, not on its configuration (atuin's output is the same
  # with any valid settings, and it only needs a place to look for them).
  integrations = pkgs.runCommand "ravnix-shell-integrations" { } ''
    export HOME="$TMPDIR" XDG_CONFIG_HOME="$TMPDIR/config" XDG_DATA_HOME="$TMPDIR/data"
    mkdir -p "$out"
    ${exe config.programs.starship.package} init bash --print-full-init > "$out/starship.bash"
    {
      ${exe config.programs.zoxide.package} init bash
      ${exe config.programs.fzf.package} --bash
      ${exe config.programs.atuin.package} init bash --disable-up-arrow
    } > "$out/tools.bash"
  '';

  gitCompletion = "${config.programs.git.package}/share/bash-completion/completions/git";

  # The seam: the text of ravnix.shell.autoAttach, first in the interactive
  # part, before the completion that home-manager loads early and before
  # anything else, so a shell that `exec`s away has paid for nothing. It runs
  # before the aliases and the functions of this module, so `cd` there is the
  # builtin; an alias another module adds through programs.bash.shellAliases
  # is live, and a function is not.
  seam = ''
    # ─── Terminal auto-attach (a seam) ──────────────────────────────────────
    # The module that drops a new terminal into a persistent session adds its
    # code here, through ravnix.shell.autoAttach. Nothing in this module does.
    # No alias of this module and no function is defined yet.
    ${cfg.autoAttach}
  '';

  main = ''
    # herdr has no equivalent of tmux's `update-environment`, so a pane inherits
    # the server's SWAYSOCK, which is PID-specific and dies with the sway
    # process. Fix it per shell instead of per server: this file runs in every
    # new pane, so every new pane self-heals after a sway restart. Panes open
    # at the time stay stale.
    if [[ -n "$SWAYSOCK" && ! -S "$SWAYSOCK" ]]; then
        SWAYSOCK=$(ls -t /run/user/"$UID"/sway-ipc."$UID".*.sock 2>/dev/null | head -1)
        export SWAYSOCK
    fi

    # Time format for `history` output (printed by `history -E`). A leading
    # space does NOT hide a command from history or atuin: bash-preexec needs
    # space-prefixed commands, so ignorespace would only be stripped again. For
    # secret redaction use atuin's history_filter and secrets_filter.
    HISTTIMEFORMAT="%F %T  "

    # ─── Init / evaluators ────────────────────────────────────────────────────
    # Order matters. bash-preexec comes before every consumer that registers
    # a DEBUG trap (atuin, starship's timing). fzf comes before atuin: both
    # bind Ctrl-R and the last one wins, and Ctrl-R is atuin's. The up arrow
    # stays bash's own history (--disable-up-arrow).
    source ${pkgs.bash-preexec}/share/bash/bash-preexec.sh
    if [[ ''${TERM:-} != "dumb" ]]; then
        source ${integrations}/starship.bash
    fi
    source ${integrations}/tools.bash

    # ─── Functions ──────────────────────────────────────────────────────────
    ${builtins.readFile ./bash/functions.bash}

    # Tab completion for `g` as for `git`. bash-completion loads git's
    # completion lazily, on the first `git <Tab>`, and `g` needs its
    # __git_complete. Loading it here costs milliseconds in every new shell,
    # so the first `g <Tab>` loads it instead: the stub sources the file, puts
    # git's own completion on g, and returns 124, which tells bash to restart
    # the completion with the new one.
    _g_complete_load() {
        source ${gitCompletion} &&
            __git_complete g __git_main &&
            return 124
    }
    complete -o bashdefault -o default -o nospace -F _g_complete_load g

    # ─── Secrets ────────────────────────────────────────────────────────────
    # ravnix.shell.secretEnv: which variable comes from which rbw item, for
    # `claude`; ai-unlock only unlocks the vault. And the claude it starts, by
    # path (empty: the first on the PATH).
    _ravnix_secrets=(${secretTable})
    _ravnix_claude_bin=${lib.escapeShellArg claudeBin}
    ${builtins.readFile ./bash/secrets.bash}
  '';

  # The aliases, as a definition of their own at an order after everything a
  # module normally asks for (lib.mkAfter is 1500, a plain definition 1000), so
  # that they are the end of the whole bashrc and not only of this module's
  # part: a function another module defines is read when it is defined, and an
  # alias that was live then would be expanded in its body for good (see the
  # header). A module that asks for an order above this knows what it does.
  aliases' = ''
    # ─── Aliases ────────────────────────────────────────────────────────────
    # Last, after every function of every module (see the header).
    ${aliasLines}
  '';
in
{
  programs.bash = {
    enable = true;
    enableCompletion = true;

    # appended across sessions, duplicates dropped. ignoredups and not
    # ignoreboth: see HISTTIMEFORMAT below.
    historyControl = [ "ignoredups" ];
    historySize = 32768;
    historyFileSize = 32768;
    # A bare directory name as a command changes into it (`Documents` is `cd
    # Documents`). cdspell is left off on purpose: `cd` is the zd wrapper,
    # which calls the builtin only for paths that exist, so the builtin's typo
    # fixing could never fire, and zoxide already matches fuzzily.
    shellOptions = [
      "histappend"
      "autocd"
    ];

    # Everything a shell needs that is not interactive too: home-manager's
    # session variables and PATH. A terminal in the graphical session, a herdr
    # pane, Claude Code's shell snapshot and a plain `ssh host cmd` source this
    # file without a login, and the file that sets them is only read at login.
    # It is guarded against a second reading.
    bashrcExtra = ''
      . "${config.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh"
    '';

    initExtra = lib.mkMerge [
      (lib.mkOrder 50 seam)
      (lib.mkOrder 1000 main)
      (lib.mkOrder 5000 aliases')
    ];
  };

  # ~/.local/bin: user-installed scripts, ahead of everything else.
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.sessionVariables = {
    # Neovim, and sudo edits through it (functions.bash: `sudo nvim` is
    # sudoedit). git has its own core.editor.
    EDITOR = "nvim";
    VISUAL = "nvim";
    SUDO_EDITOR = "nvim";

    # Color man pages with bat.
    MANROFFOPT = "-c";
    MANPAGER = "sh -c 'col -bx | bat -l man -p'";

    # tldr's page colors. The Python client has a fixed 8-color ANSI palette,
    # not Catppuccin, which the terminal re-interprets through its own: bold
    # heading, no description color, green example flags, red commands.
    TLDR_COLOR_NAME = "bold";
    TLDR_COLOR_DESCRIPTION = "";
    TLDR_COLOR_EXAMPLE = "green";
    TLDR_COLOR_COMMAND = "red";
    TLDR_COLOR_PARAMETER = "";
  };

  # The keyboard layer: completion cycles with Tab and Shift-Tab, the arrow
  # keys search the history for what is typed so far, and completion shows
  # what it finds in color.
  programs.readline = {
    enable = true;
    variables = {
      meta-flag = true;
      input-meta = true;
      output-meta = true;
      convert-meta = false;
      completion-ignore-case = true;
      completion-prefix-display-length = 2;
      show-all-if-ambiguous = true;
      show-all-if-unmodified = true;
      # Add a trailing slash at once when completing a symlink to a directory.
      mark-symlinked-directories = true;
      # Do not complete hidden files unless the pattern begins with a dot.
      match-hidden-files = false;
      # Show all completions at once, and ask above 200.
      page-completions = false;
      completion-query-items = 200;
      # Show extra file information when completing, like `ls -F`.
      visible-stats = true;
      # Look at the text after the cursor too: `cd ~/src/mozil|la` completes
      # to `~/src/mozilla`, not `~/src/mozillala`.
      skip-completed-text = true;
      colored-stats = true;
      # On the first Tab, complete the common prefix before cycling.
      menu-complete-display-prefix = true;
    };
    bindings = {
      "\\e[A" = "history-search-backward";
      "\\e[B" = "history-search-forward";
      "\\e[C" = "forward-char";
      "\\e[D" = "backward-char";
      "\\e[Z" = "menu-complete-backward";
    };
    # TAB is a key name, which the bindings above would quote as three letters.
    extraConfig = ''
      TAB: menu-complete
    '';
  };
}
