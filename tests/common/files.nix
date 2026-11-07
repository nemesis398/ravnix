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

  teal = (hm [ { ravnix.theme.accent = "teal"; } ]).config;
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
          ../../modules/common/options.nix
          { ravnix.shell.secretEnv = lib.genAttrs names (_: "item"); }
        ];
      };
    in
    map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions);
  badNames = secretNames [
    "bad name"
    "1STARTS_WITH_A_DIGIT"
    "A=B"
    "GOOD_ONE"
    "_ALSO_GOOD2"
  ];
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
    (lib.optional (base.programs.git.settings.core.pager != "delta") "git core.pager is not delta")
    (lib.optional (base.programs.git.settings.pull.ff != "only") "git pull.ff is not only")
    (lib.optional (
      base.programs.git.settings.init.defaultBranch != "main"
    ) "git init.defaultBranch is not main")
    (lib.optional (base.programs.git.settings.alias.st != "status -sb") "git alias st is missing")
    # The Fedora aliases, exactly, and the shell options and history.
    (lib.optional (
      base.programs.bash.shellAliases != aliases
    ) "the bash aliases differ from Fedora's: ${builtins.toJSON base.programs.bash.shellAliases}")
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
      lib.length badNames != 3
    ) "secretEnv should refuse three names, refused: ${toString badNames}")
    (lib.optional (
      !lib.all (n: lib.any (m: lib.hasInfix "\"${n}\"" m) badNames) [
        "bad name"
        "1STARTS_WITH_A_DIGIT"
        "A=B"
      ]
    ) "the refused secretEnv names are not named in the messages")
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
    bashrcSeam = fileOf withSeam ".bashrc";
    bashrcSecrets = fileOf withSecrets ".bashrc";
    inputrc = base.home.file.".inputrc".source or base.xdg.configFile."readline/inputrc".source;
  }
  ''
    status=0
    ${lib.concatMapStrings (m: "echo ${lib.escapeShellArg m} >&2; status=1\n") checks}

    # The seam: the text goes in after the guard of the interactive shell and
    # before anything else; with no text there is no hook at all.
    line() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
    guard=$(line "$bashrcSeam" '[[ $- == *i* ]] || return')
    seam=$(line "$bashrcSeam" 'echo THE-SEAM-TEXT')
    first=$(line "$bashrcSeam" 'SWAYSOCK')
    if ! [ -n "$guard" ] || ! [ -n "$seam" ] || ! [ -n "$first" ] \
      || ! [ "$guard" -lt "$seam" ] || ! [ "$seam" -lt "$first" ]; then
      echo "the seam is not between the interactive guard and the rest: guard=$guard seam=$seam first=$first" >&2
      status=1
    fi
    ! grep -q 'THE-SEAM-TEXT' "$bashrc" || { echo "seam text without being set" >&2; status=1; }
    ! grep -qE 'exec +herdr|herdr --session' "$bashrc" || { echo "the bashrc holds the herdr hook, which is Task 5.2's" >&2; status=1; }
    grep -qi 'auto-attach' "$bashrc" || { echo "the seam has no name in the bashrc" >&2; status=1; }

    # The secrets: none by default, and the item names quoted when there are.
    grep -qF 'declare -A _ravnix_secret_env=()' "$bashrc" || { echo "no empty secret table by default" >&2; status=1; }
    ! grep -q '_ravnix_load_secrets$' "$bashrc" || { echo "secrets load at startup without any configured" >&2; status=1; }
    grep -qF "[PLANE_TOKEN]='Plane - token (it'\'''s here)'" "$bashrcSecrets" || { echo "the item name is not quoted for the shell" >&2; status=1; }
    grep -qE '^(\(\(.*\)\) && )?_ravnix_load_secrets|_ravnix_load_secrets$' "$bashrcSecrets" || { echo "secrets are not loaded at startup when configured" >&2; status=1; }

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
