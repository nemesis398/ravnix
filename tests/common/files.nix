# What the common module writes for home-manager, read from the evaluated
# configuration and from the generated files: git with the user's identity and
# signing, the Fedora aliases, the options and the seam in the bashrc, atuin's
# sync follows the services option, the ports of Catppuccin follow the accent,
# the tools the spec drops are not installed, and the dev checkout's
# activation exists only when asked for. The running behavior is
# checks.common-shell (a VM) and checks.common-functions.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };
  me = (import ../../templates/default/me.nix).ravnix;
  base = (hm [ ]).config;
  palette = base.ravnix.theme.palette;

  failed = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
  packageNames = c: map lib.getName c.home.packages;

  # "#rrggbb" as the ANSI truecolor parameters fastfetch takes.
  ansi =
    hex:
    "38;2;${
      lib.concatMapStringsSep ";" (i: toString (lib.fromHexString (builtins.substring i 2 hex))) [
        1
        3
        5
      ]
    }";

  withAtuin =
    enable:
    (hm [
      {
        ravnix.services.atuin = {
          inherit enable;
          host = "nas";
          port = 8888;
        };
      }
    ]).config;
  atuinOn = withAtuin true;
  atuinOff = withAtuin false;

  teal = (hm [ { ravnix.theme.accent = lib.mkForce "teal"; } ]).config;
  withCheckout =
    (hm [
      {
        ravnix.dev = {
          checkout = lib.mkForce "/home/alice/src/ravnix";
          denyList = lib.mkForce "/home/alice/src/private/deny-list.txt";
        };
      }
    ]).config;
  # The option's own assertions, away from home-manager, which refuses to
  # evaluate a configuration whose assertions fail.
  secretNames =
    names:
    let
      evaluated = lib.evalModules {
        modules = [
          lib.genericModules.assertions
          ../../modules/options/shell.nix
          { ravnix.shell.secretEnv = lib.genAttrs names (_: "item"); }
        ];
      };
    in
    map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions);
  badNames = secretNames [
    "bad name"
    "1STARTS_WITH_A_DIGIT"
    "A=B"
    "lower_case"
    "GOOD_ONE"
    "_ALSO_GOOD2"
  ];
  # Names the shell, the loader or Claude Code read themselves.
  reservedNames = secretNames [
    "PATH"
    "HOME"
    "IFS"
    "BASH_ENV"
    "BASHOPTS"
    "PROMPT_COMMAND"
    "LD_PRELOAD"
    "CLAUDECODE"
    "UID"
    "PS1"
    "CLAUDE_CODE_OAUTH_TOKEN"
    "PLANE_API_KEY"
  ];
  # A private flake's me.nix, checked the way its `me` check does: against
  # nixosModules.options alone.
  meWithSecrets =
    (lib.evalModules {
      modules = [
        lib.genericModules.assertions
        self.nixosModules.options
        (import ../../templates/default/me.nix)
        { ravnix.shell.secretEnv.A_TOKEN = "An item"; }
      ];
    }).config;
  # And a host refuses to build with one of them.
  hmRefuses =
    !(builtins.tryEval (hm [ { ravnix.shell.secretEnv."bad name" = "item"; } ]).config.home.username)
    .success;
  withSecrets =
    (hm [
      {
        ravnix.shell.secretEnv = {
          PLANE_TOKEN = "Plane - token (it's here)";
          OTHER_TOKEN = "Other";
        };
      }
    ]).config;
  withSeam = (hm [ { ravnix.shell.autoAttach = "echo THE-SEAM-TEXT"; } ]).config;
  # Other modules add to the interactive part, at the default order, after
  # it (lib.mkAfter) and just below the aliases. The aliases come after all
  # of them: a function defined after them would have them expanded in its body.
  withOthers =
    (hm [
      {
        programs.bash.initExtra = lib.mkMerge [
          "other_default() { :; }"
          (lib.mkAfter "other_after() { :; }")
          (lib.mkOrder 1999 "other_1999() { :; }")
        ];
      }
    ]).config;

  # The Fedora aliases, less the ones of tools the spec drops (httpie, and
  # the herdr alias `t` that the seam gives to Task 5.2).
  aliases = {
    bcat = "command cat";
    pcat = "bat --plain --paging=never";
    ls = "eza -lh --group-directories-first --icons=auto";
    lsa = "ls -a";
    lt = "eza --tree --level=2 --long --icons --git";
    lta = "lt -a";
    ld = "eza --tree --level=6 --long --icons --git";
    lda = "ld -a";
    hl = "rg --passthru";
    ff = "fzf --preview 'bat --style=numbers --color=always {}'";
    eff = ''$EDITOR "$(ff)"'';
    cd = "zd";
    ".." = "cd ..";
    "..." = "cd ../..";
    "...." = "cd ../../..";
    tl = "tldr";
    or = "odin run";
    g = "git";
    gcm = "git commit -m";
    gcam = "git commit -a -m";
    gcad = "git commit -a --amend";
    gp = "git push";
  };

  # The alias lines the bashrc must have, exactly, as `alias -- NAME=VALUE`.
  aliasLines = lib.concatMapStringsSep "\n" (
    n: "alias -- ${lib.escapeShellArg n}=${lib.escapeShellArg aliases.${n}}"
  ) (lib.attrNames aliases);

  # What the spec drops (design spec, "Dropped"), plus Fedora's httpie.
  dropped = [
    "httpie"
    "tmux"
    "procs"
    "dust"
    "hyperfine"
    "borg"
    "borgbackup"
    "snapper"
    "zathura"
    "foot"
    "opencode"
    "mise"
  ];
  wanted = [
    "git"
    "gh"
    "delta"
    "starship"
    "atuin"
    "zoxide"
    "ripgrep"
    "fd"
    "fzf"
    "eza"
    "bat"
    "btop"
    "fastfetch"
    "lazygit"
    "tldr"
    "jq"
    "rbw"
    "chafa"
    "file"
    "neovim"
  ];

  checks = lib.flatten [
    # Git: the identity and the signing key are the user's options.
    (lib.optional (
      base.programs.git.settings.user.email != me.user.email
    ) "git user.email is not ravnix.user.email")
    (lib.optional (
      base.programs.git.settings.user.name != me.user.name
    ) "git user.name is not ravnix.user.name")
    (lib.optional (
      base.programs.git.signing.key != "key::${me.user.signingKey}"
    ) "the signing key is not the key:: form of ravnix.user.signingKey")
    (lib.optional (base.programs.git.signing.format != "ssh") "git does not sign with ssh")
    (lib.optional (base.programs.git.signing.signByDefault != true) "git does not sign by default")
    (lib.optional (
      base.programs.git.signing.allowedSigners != "${me.user.email} ${me.user.signingKey}\n"
    ) "allowed_signers is not 'email key'")
    (lib.optional (base.programs.git.settings.core.editor != "nvim") "git core.editor is not nvim")
    # EDITOR names nvim, so the module installs it (nvim.nix, imported by default.nix).
    (lib.optional (
      !base.programs.neovim.enable
    ) "nvim is the editor, and programs.neovim is not enabled")
    (lib.optional (base.programs.git.settings.core.pager != "delta") "git core.pager is not delta")
    (lib.optional (base.programs.git.settings.pull.ff != "only") "git pull.ff is not only")
    (lib.optional (
      base.programs.git.settings.init.defaultBranch != "main"
    ) "git init.defaultBranch is not main")
    (lib.optional (base.programs.git.settings.alias.st != "status -sb") "git alias st is missing")
    # The Fedora aliases are written by the module itself, at their place
    # in the interactive part (checked on the bashrc below), not by
    # home-manager, which would write them before everything else.
    (lib.optional (base.programs.bash.shellAliases != { })
      "programs.bash.shellAliases is set, so the aliases come before the seam: ${builtins.toJSON base.programs.bash.shellAliases}"
    )
    # The shell options and history.
    (lib.optional (
      lib.sort (a: b: a < b) base.programs.bash.shellOptions != [
        "autocd"
        "histappend"
      ]
    ) "the bash options are not autocd and histappend: ${toString base.programs.bash.shellOptions}")
    (lib.optional (base.programs.bash.historySize != 32768) "HISTSIZE is not 32768")
    (lib.optional (base.programs.bash.historyFileSize != 32768) "HISTFILESIZE is not 32768")
    (lib.optional (
      base.programs.bash.historyControl != [ "ignoredups" ]
    ) "HISTCONTROL is not ignoredups")
    (lib.optional (
      base.home.sessionVariables.EDITOR != "nvim" || base.home.sessionVariables.VISUAL != "nvim"
    ) "EDITOR and VISUAL are not nvim")
    (lib.optional (
      base.home.sessionVariables.TLDR_COLOR_COMMAND != "red"
    ) "the tldr colors are not Fedora's")
    # The tools: the spec's list is in, what it drops is out.
    (map (n: "${n} is not installed") (lib.filter (n: !lib.elem n (packageNames base)) wanted))
    (map (n: "${n} is installed, which the spec drops") (
      lib.filter (n: lib.elem n (packageNames base)) dropped
    ))
    # The accent follows into the ports.
    (lib.optional (
      base.programs.atuin.settings.theme.name != "catppuccin-mocha-mauve"
    ) "atuin's theme is not catppuccin-mocha-mauve")
    (lib.optional (
      teal.programs.atuin.settings.theme.name != "catppuccin-mocha-teal"
    ) "atuin's theme does not follow the accent")
    (lib.optional (
      !base.xdg.configFile ? "eza/theme.yml" || !teal.xdg.configFile ? "eza/theme.yml"
    ) "eza has no theme file")
    (lib.optional (
      base.programs.bat.config.theme != "Catppuccin Mocha"
    ) "bat's theme is not Catppuccin Mocha")
    (lib.optional (
      !lib.hasInfix "/mocha/mauve.yml" base.home.sessionVariables.LG_CONFIG_FILE
    ) "lazygit's theme is not the mauve port")
    (lib.optional (
      !lib.hasInfix "/mocha/teal.yml" teal.home.sessionVariables.LG_CONFIG_FILE
    ) "lazygit's theme does not follow the accent")
    # The TUIs draw the single light line, not the rounded one.
    (lib.optional (
      base.programs.lazygit.settings.gui.border != "single"
    ) "lazygit's border is not single")
    (lib.optional (base.programs.btop.settings.rounded_corners != false) "btop has rounded corners")
    (lib.optional (
      base.programs.lazygit.settings.update.method != "never"
    ) "lazygit offers to update itself")
    # Nothing blinks and nothing is round (docs/style.md): atuin's cursor in
    # every keymap mode, the palette swatches of fastfetch.
    (lib.optional (lib.any (lib.hasPrefix "blink") (lib.attrValues base.programs.atuin.settings.keymap_cursor)) "atuin has a blinking cursor in one of its modes: ${builtins.toJSON base.programs.atuin.settings.keymap_cursor}")
    (lib.optional (lib.any (m: (m.symbol or "block") != "block" && (m.type or "") == "colors") (
      base.programs.fastfetch.settings.modules
    )) "fastfetch draws its palette in a shape that is not the block")
    # Home-manager's `lg` function for lazygit is Fedora's no more (and a `cd`
    # in it would be the zd alias).
    (lib.optional base.programs.lazygit.enableBashIntegration "lazygit's bash integration adds an lg function")
    # Atuin syncs through the service the user places, and nowhere else.
    (lib.optional (
      atuinOn.programs.atuin.settings.sync_address != "http://192.0.2.30:8888"
    ) "atuin's sync_address is not the service's url")
    (lib.optional (
      atuinOn.programs.atuin.settings.auto_sync != true
    ) "atuin does not sync with a service")
    (lib.optional (base.programs.atuin.settings.auto_sync != false) "atuin syncs without a service")
    (lib.optional (
      atuinOff.programs.atuin.settings.auto_sync != false
    ) "atuin syncs with a disabled service")
    (lib.optional (
      base.programs.atuin.settings ? sync_address || atuinOff.programs.atuin.settings ? sync_address
    ) "atuin has a sync_address without a service")
    (lib.optional (
      base.programs.atuin.settings.update_check != false
    ) "atuin checks for updates itself")
    (lib.optional (
      base.programs.atuin.settings.enter_accept != true
    ) "atuin's Enter does not run the command")
    # rbw knows the server and the account from the options.
    (lib.optional (
      base.programs.rbw.settings.email != me.secrets.rbwEmail
      || base.programs.rbw.settings.base_url != me.secrets.rbwBaseUrl
    ) "rbw does not get ravnix.secrets")
    # fastfetch: keys in the accent, the NixOS logo in Blue and Sapphire.
    (lib.optional (
      base.programs.fastfetch.settings.display.color.keys != ansi palette.mauve
    ) "fastfetch's keys are not the accent")
    (lib.optional (
      teal.programs.fastfetch.settings.display.color.keys != ansi palette.teal
    ) "fastfetch's keys do not follow the accent")
    (lib.optional (
      base.programs.fastfetch.settings.logo.color != {
        "1" = ansi palette.blue;
        "2" = ansi palette.sapphire;
      }
    ) "fastfetch's logo is not in Blue and Sapphire")
    # The dev checkout: an activation step when asked for, none otherwise.
    (lib.optional (
      base.home.activation ? ravnixDevCheckout
    ) "the dev checkout is configured without being asked for")
    (lib.optional (
      !withCheckout.home.activation ? ravnixDevCheckout
    ) "ravnix.dev.checkout does not add the activation step")
    (lib.optional (
      withCheckout.home.activation ? ravnixDevCheckout
      && !(
        lib.hasInfix "/home/alice/src/ravnix" withCheckout.home.activation.ravnixDevCheckout.data
        && lib.hasInfix "/home/alice/src/private/deny-list.txt" withCheckout.home.activation.ravnixDevCheckout.data
      )
    ) "the activation step names neither the checkout nor the deny list")
    # The secrets option takes shell-safe names only.
    (lib.optional (failed base != [ ]) "the default configuration fails: ${toString (failed base)}")
    (lib.optional (
      lib.length badNames != 4
    ) "secretEnv should refuse four names, refused: ${toString badNames}")
    (lib.optional (
      !lib.all (n: lib.any (m: lib.hasInfix "\"${n}\"" m) badNames) [
        "bad name"
        "1STARTS_WITH_A_DIGIT"
        "A=B"
        "lower_case"
      ]
    ) "the refused secretEnv names are not named in the messages")
    (lib.optional (lib.length reservedNames != 10)
      "secretEnv should refuse ten reserved names and take the last two, refused: ${toString reservedNames}"
    )
    (lib.optional (lib.any (n: lib.any (m: lib.hasInfix "\"${n}\"" m) reservedNames) [
      "CLAUDE_CODE_OAUTH_TOKEN"
      "PLANE_API_KEY"
    ]) "secretEnv refuses a name that is a good secret's")
    (lib.optional (
      meWithSecrets.ravnix.shell.secretEnv != { A_TOKEN = "An item"; }
    ) "me.nix cannot set ravnix.shell.secretEnv against nixosModules.options")
    (lib.optional (secretNames [ "GOOD_ONE" ] != [ ]) "a good secretEnv name is refused")
    (lib.optional (!hmRefuses) "home-manager builds with a bad secretEnv name")
    (lib.optional (failed withSecrets != [ ]) "good secretEnv names are refused")
  ];

  fileOf = c: path: c.home.file.${path}.source;
in
pkgs.runCommand "common-files"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gawk
      pkgs.jq
    ];
    bashrc = fileOf base ".bashrc";
    expectedAliases = aliasLines;
    bashrcSeam = fileOf withSeam ".bashrc";
    bashrcOthers = fileOf withOthers ".bashrc";
    bashrcSecrets = fileOf withSecrets ".bashrc";
    inputrc = base.home.file.".inputrc".source or base.xdg.configFile."readline/inputrc".source;
  }
  ''
    status=0
    ${lib.concatMapStrings (m: "echo ${lib.escapeShellArg m} >&2; status=1\n") checks}

    # The order of the interactive part is the Fedora one: the guard, the
    # seam (before home-manager's completion, and before anything of this
    # module), the SWAYSOCK repair, the functions, and the aliases last, so
    # that no alias is live in the repair or the seam and none is expanded in
    # a function body when it is defined.
    line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
    guard=$(line "$bashrcSeam" '[[ $- == *i* ]] || return')
    seam=$(line "$bashrcSeam" 'echo THE-SEAM-TEXT')
    completion=$(line "$bashrcSeam" 'bash_completion.sh')
    sway=$(line "$bashrcSeam" 'SWAYSOCK=$(')
    claudefn=$(line "$bashrcSeam" 'claude() {')
    unlockfn=$(line "$bashrcSeam" 'ai-unlock() {')
    gcomplete=$(line "$bashrcSeam" '_g_complete_load() {')
    firstalias=$(line "$bashrcSeam" 'alias -- ')
    lastfn=$(grep -nE '^[a-z_-]+\(\) \{' "$bashrcSeam" | tail -1 | cut -d: -f1)
    for n in guard seam completion sway claudefn unlockfn gcomplete firstalias lastfn; do
      [ -n "''${!n}" ] || { echo "the bashrc has no $n" >&2; status=1; }
    done
    if [ "$status" = 0 ]; then
      [ "$guard" -lt "$seam" ] || { echo "the seam is not after the interactive guard: $guard $seam" >&2; status=1; }
      [ "$seam" -lt "$completion" ] || { echo "the seam is not before home-manager's completion: $seam $completion" >&2; status=1; }
      [ "$completion" -lt "$sway" ] || { echo "the SWAYSOCK repair is not after the completion: $completion $sway" >&2; status=1; }
      [ "$sway" -lt "$firstalias" ] || { echo "an alias comes before the SWAYSOCK repair: $sway $firstalias" >&2; status=1; }
      [ "$seam" -lt "$firstalias" ] || { echo "an alias comes before the seam: $seam $firstalias" >&2; status=1; }
      for fn in "$claudefn" "$unlockfn" "$gcomplete" "$lastfn"; do
        [ "$fn" -lt "$firstalias" ] || { echo "a function is defined after the first alias: line $fn, alias $firstalias" >&2; status=1; }
      done
    fi
    # The aliases are the end of the whole file, not only of this module's
    # part: whatever other modules add to the interactive part, at the default
    # order, after it or just below the aliases, comes before them, and
    # nothing but alias lines follows the first one.
    for f in "$bashrc" "$bashrcOthers"; do
      first=$(line "$f" 'alias -- ')
      [ -n "$first" ] || { echo "no alias in $f" >&2; status=1; continue; }
      tail -n +"$first" "$f" | grep -vE '^(alias -- |$)' >&2 && { echo "something follows the first alias in $f" >&2; status=1; }
    done
    for fn in 'other_default() {' 'other_after() {' 'other_1999() {'; do
      at=$(line "$bashrcOthers" "$fn")
      first=$(line "$bashrcOthers" 'alias -- ')
      [ -n "$at" ] && [ -n "$first" ] && [ "$at" -lt "$first" ] || { echo "$fn of another module is not before the aliases: $at, $first" >&2; status=1; }
    done
    # The alias lines are the Fedora set, exactly, and all at the end.
    grep '^alias -- ' "$bashrc" > aliases.actual || true
    printf '%s\n' "$expectedAliases" > aliases.expected
    diff aliases.expected aliases.actual >&2 || { echo "the alias lines differ from Fedora's" >&2; status=1; }
    ! grep -n '^alias ' "$bashrc" | grep -v ':alias -- ' >&2 || { echo "an alias is written another way" >&2; status=1; }
    [ "$(grep -c '^alias -- ' "$bashrc")" = "$(wc -l < aliases.expected)" ] || status=1
    ! grep -q 'THE-SEAM-TEXT' "$bashrc" || { echo "seam text without being set" >&2; status=1; }
    ! grep -qE 'exec +herdr|herdr --session' "$bashrc" || { echo "the bashrc holds the herdr hook, which is Task 5.2's" >&2; status=1; }
    grep -qi 'auto-attach' "$bashrc" || { echo "the seam has no name in the bashrc" >&2; status=1; }

    # The secrets: none by default, and the item names quoted when there are.
    # `claude` reads them when it starts; no shell loads one at startup, and
    # ai-unlock exports none.
    grep -qxF '_ravnix_secrets=()' "$bashrc" || { echo "no empty secret table by default" >&2; status=1; }
    grep -qF "_ravnix_secrets=('OTHER_TOKEN=Other' 'PLANE_TOKEN=Plane - token (it'\'''s here)')" "$bashrcSecrets" || { echo "the item names are not quoted for the shell, in name order" >&2; status=1; }
    for f in "$bashrc" "$bashrcSecrets"; do
      ! grep -qE '_ravnix_load_secrets|_ravnix_read_secrets|declare -A _ravnix_secret_env' "$f" || { echo "the bashrc still loads secrets into every shell" >&2; status=1; }
    done
    grep -qE '^claude\(\) \{' "$bashrc" || { echo "no claude function" >&2; status=1; }
    ! grep -qE '^(function )?lg\(\)' "$bashrc" || { echo "the bashrc has the lg function of home-manager's lazygit" >&2; status=1; }

    # Both bashrcs parse.
    bash -n "$bashrc" || status=1
    bash -n "$bashrcSecrets" || status=1

    # The inputrc has Fedora's keyboard layer.
    for want in 'set completion-ignore-case on' 'set show-all-if-ambiguous on' \
      'set colored-stats on' 'TAB: menu-complete' 'set menu-complete-display-prefix on'; do
      grep -qF -- "$want" "$inputrc" || { echo "the inputrc lacks: $want" >&2; status=1; }
    done

    [ "$status" = 0 ]
    touch $out
  ''
