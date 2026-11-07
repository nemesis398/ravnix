# The `claude` function of the shell starts the Claude Code that home-manager
# installs.
#
# bash.nix writes the absolute path of the claude in home-manager's own
# profile (home.profileDirectory, /etc/profiles/per-user/USER on a host) into
# _ravnix_claude_bin, before the function that reads it, so the secrets from
# rbw go to the build programs.claude-code installs and not to whatever claude
# comes first on the PATH (a native install in ~/.local/bin, say). It is the
# profile and not the store path of that build because a shell reads the
# bashrc once and lives for days: the profile is the same path after every
# switch and holds the current build, where a store path would keep the shell
# on its own generation and fail once that is collected. The variable is empty
# when Claude Code is off or has no package, and the function is then what it
# was. The scenarios of the function itself are in
# helpers/functions.test.bash; this checks what the module writes into the
# generated bashrc, that the profile holds the configured package's claude,
# and runs the function out of that bashrc. (That homeModules.common brings
# Claude Code is claude-included; the bashrc here is built from the helper's
# home, which has it.)
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
  # The helper's home is homeModules.common and the template's me.nix, and
  # nothing of Claude Code beside them.
  base = (hm [ ]).config;
  off = (hm [ { programs.claude-code.enable = false; } ]).config;
  noPackage = (hm [ { programs.claude-code.package = lib.mkForce null; } ]).config;
  # A claude that is not packages.claude-code: the function follows the
  # configured package. (It carries the download attribute the module asks
  # for, but is no Claude Code.)
  standIn =
    pkgs.writeShellScriptBin "claude" ''
      echo stand-in "$@"
    ''
    // {
      download = null;
    };
  other = (hm [ { programs.claude-code.package = standIn; } ]).config;

  # The profile's claude is the configured package's: home-manager installs
  # programs.claude-code.finalPackage (not .package, which a plugin wrapper
  # replaces) into home.packages, and its bin/claude is what the profile
  # links. The profile of a host is built from home.packages, so this is what
  # the path in the variable resolves to.
  installed =
    c: lib.elem c.programs.claude-code.finalPackage.outPath (map (p: p.outPath) c.home.packages);

  failed = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  # Claude Code off, without a package or another one: it all evaluates.
  failures = lib.flatten [
    (map (m: "common with Claude Code off fails: ${m}") (failed off))
    (map (m: "common without a Claude Code package fails: ${m}") (failed noPackage))
    (map (m: "common with another Claude Code package fails: ${m}") (failed other))
    (lib.optional (
      !installed base
    ) "finalPackage is not in home.packages, so the profile has no claude")
    (lib.optional (
      !installed other
    ) "the stand-in's finalPackage is not in home.packages, so the profile has no claude")
  ];

  fileOf = c: c.home.file.".bashrc".source;
in
pkgs.runCommand "common-claude-bin"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
    ];
    bashrc = fileOf base;
    bashrcOff = fileOf off;
    bashrcNoPackage = fileOf noPackage;
    bashrcOther = fileOf other;
    expected = "${base.home.profileDirectory}/bin/claude";
    expectedOther = "${other.home.profileDirectory}/bin/claude";
    # The claude that the profile of each home links.
    package = base.programs.claude-code.finalPackage;
    packageOther = other.programs.claude-code.finalPackage;
  }
  ''
    status=0
    ${lib.concatMapStrings (m: "echo ${lib.escapeShellArg m} >&2; status=1\n") failures}

    # The variable's value as the shell reads it: the one line of the bashrc
    # that assigns it, evaluated on its own. It comes before the function.
    must_be() { # NAME FILE VALUE
      if [ "$(grep -c '^_ravnix_claude_bin=' "$2")" != 1 ]; then
        echo "$1: $2 does not assign _ravnix_claude_bin exactly once" >&2
        status=1
        return
      fi
      line=$(grep '^_ravnix_claude_bin=' "$2")
      got=$(unset _ravnix_claude_bin; eval "$line"; printf '%s' "$_ravnix_claude_bin")
      [ "$got" = "$3" ] || { echo "$1: _ravnix_claude_bin is '$got', not '$3'" >&2; status=1; }
    }
    must_be "Claude Code on" "$bashrc" "$expected"
    must_be "Claude Code off" "$bashrcOff" ""
    must_be "no package" "$bashrcNoPackage" ""
    must_be "another package" "$bashrcOther" "$expectedOther"
    # The variable is not a store path: it names the profile, which follows
    # every switch (a store path of the build would not, see bash.nix).
    case "$expected" in
      /nix/store/*) echo "the bashrc names a store path: $expected" >&2; status=1 ;;
    esac
    # What the profile links is the configured package's claude, which exists.
    [ -f "$package/bin/claude" ] && [ -x "$package/bin/claude" ] || { echo "$package/bin/claude is no executable file" >&2; status=1; }

    for f in "$bashrc" "$bashrcOff" "$bashrcNoPackage" "$bashrcOther"; do
      var=$(grep -n '^_ravnix_claude_bin=' "$f" | head -1 | cut -d: -f1)
      fn=$(grep -n '^claude() {' "$f" | head -1 | cut -d: -f1)
      [ -n "$var" ] && [ -n "$fn" ] && [ "$var" -lt "$fn" ] || { echo "the variable (line $var) does not come before the function (line $fn) in $f" >&2; status=1; }
      bash -n "$f" || status=1
    done

    # The function of the real bashrc, with a decoy claude first on the PATH
    # (what a native install in ~/.local/bin would be), runs the claude of
    # the profile with Claude Code on, and the decoy with it off. The profile
    # of the home is /home/alice/.nix-profile, which the sandbox lacks, so the
    # assignment is read from the bashrc and its profile directory replaced by
    # a profile built here the way a host's is: bin/claude links the package's.
    mkdir -p decoy profile/bin
    printf '#!%s\necho DECOY "$@"\n' "$(command -v bash)" > decoy/claude
    chmod +x decoy/claude
    ln -s "$packageOther/bin/claude" profile/bin/claude
    started() { # FILE
      line=$(grep '^_ravnix_claude_bin=' "$1")
      line=''${line//"$expectedOther"/"$PWD/profile/bin/claude"}
      fn=$(sed -n '/^claude() {$/,/^}$/p' "$1")
      PATH="$PWD/decoy:$PATH" bash -c '_ravnix_secrets=(); '"$line"'; '"$fn"'; claude --version'
    }
    [ "$(started "$bashrcOther")" = "stand-in --version" ] || { echo "with another package the function started: $(started "$bashrcOther")" >&2; status=1; }
    [ "$(started "$bashrcOff")" = "DECOY --version" ] || { echo "with Claude Code off the function started: $(started "$bashrcOff")" >&2; status=1; }
    [ "$(started "$bashrcNoPackage")" = "DECOY --version" ] || { echo "without a package the function started: $(started "$bashrcNoPackage")" >&2; status=1; }

    [ "$status" = 0 ]
    touch $out
  ''
