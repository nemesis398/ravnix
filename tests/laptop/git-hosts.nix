# The git hosts on the laptop take the security key and never an agent: for
# each host of ravnix.laptop.gitKeys, the laptop's ssh config, as ssh itself
# reads it (`ssh -G`), has IdentityAgent none, IdentitiesOnly and that host's
# key handles as the only identity files, whatever the case of the name
# (ssh compares host names without it), and whatever a block after the
# include sets for that name (a later Host * or Host <name>). rbw's agent
# holds touch-free keys for the same hosts (the vault's fallback keys), so a
# git host that reached SSH_AUTH_SOCK would push without the touch. An alias
# is pinned through its HostName. The fallback the module's header
# documents reaches the agent and opens no master that pinned connections
# would reuse. Every other host keeps the agent, and without gitKeys there
# is no such block.
{
  self,
  inputs,
  lib,
  system,
  pkgs,
  ...
}:
let
  me = ../../templates/default/me.nix;
  values = import me;
  user = values.ravnix.user.username;
  gitKeys = values.ravnix.laptop.gitKeys;
  build =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        self.nixosModules.laptop
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
          warnings = lib.mkForce [ ];
          ravnix.editor.languages = lib.mkForce [ "nix" ];
        }
        extra
      ];
    };
  configOf = s: s.config.home-manager.users.${user}.home.file.".ssh/config".source or null;
  laptop = configOf (build { });
  without = build { ravnix.laptop.gitKeys = lib.mkForce { }; };
  hosts = lib.attrNames gitKeys;
  # The fallback as the header of the module writes it, with the socket
  # filled in: the documented line itself is what is checked.
  fallbackLines = lib.filter (m: m != null) (
    map (builtins.match ''#   GIT_SSH_COMMAND="ssh (.*)" git push'') (
      lib.splitString "\n" (builtins.readFile ../../modules/desktop/git-hosts.nix)
    )
  );
  fallbackArgs = lib.splitString " " (
    lib.replaceStrings [ "$SSH_AUTH_SOCK" ] [ "/run/user/1000/fallback.sock" ] (
      lib.head (lib.head fallbackLines)
    )
  );
  # The configs the pin must hold in: the user's blocks after the include,
  # an alias of their own, and then a block of the first pass that sets the
  # pinned options otherwise, for every name (Host *, as home-manager's old
  # defaults and a desktop agent's setup bring them) or for the git hosts
  # by name.
  variants = {
    plain = "";
    star = " after a later Host *";
    named = " after a later Host <name>";
  };
  cases = lib.concatMap (h: [
    {
      name = h;
      files = gitKeys.${h};
    }
    {
      name = lib.toUpper h;
      files = gitKeys.${h};
    }
  ]) hosts;
in
assert hosts != [ ];
pkgs.runCommand "laptop-git-hosts"
  {
    nativeBuildInputs = [ pkgs.openssh ];
  }
  ''
    export HOME=$TMPDIR
    status=0
    fail() { echo "$*" >&2; status=1; }
    # ssh refuses a config the build user does not own, which a store path
    # in the sandbox is not: copy the config and its includes, and point
    # the copy at the copies.
    cp ${laptop} config
    chmod u+w config
    for inc in $(sed -n 's/^Include //p' config); do
      cp "$inc" "inc-''${inc##*/}"
      sed -i "s|$inc|$PWD/inc-''${inc##*/}|" config
    done
    first=${lib.escapeShellArg (lib.head hosts)}
    cp config plain
    printf 'Host gitalias\n  HostName %s\n' "$first" >>plain
    printf 'Host gitfallback\n  HostName %s\n  IdentityAgent /run/user/1000/fallback.sock\n  IdentitiesOnly no\n  ControlPath none\n' "$first" >>plain
    { cat plain; printf 'Host *\n  IdentityAgent /run/user/1000/star.sock\n  IdentitiesOnly no\n  ControlMaster no\n  ControlPath ~/.ssh/master-%%r@%%n:%%p\n  ControlPersist no\n  ForwardAgent yes\n'; } >star
    { cat plain; printf 'Host %s\n  IdentityAgent /run/user/1000/named.sock\n  IdentitiesOnly no\n  ControlMaster no\n  ForwardAgent yes\n' ${lib.escapeShellArg (toString hosts)}; } >named
    chmod 600 config plain star named inc-* 2>/dev/null || true
    g() { local f=$1; shift; ssh -G -F "$PWD/$f" "$@" 2>&1 || echo "ssh -G failed: $?"; }

    ${lib.concatMapStrings (
      v:
      lib.concatMapStrings (
        c:
        let
          n = "${c.name}${variants.${v}}";
        in
        ''
          got=$(g ${v} ${lib.escapeShellArg c.name})
          grep -qx 'identityagent none' <<<"$got" || fail "${n}: ssh may ask an agent: $(grep -i '^identityagent' <<<"$got")"
          grep -qx 'identitiesonly yes' <<<"$got" || fail "${n}: IdentitiesOnly is off: $(grep '^identitiesonly' <<<"$got")"
          files=$(grep '^identityfile ' <<<"$got" | sort || true)
          want=$(printf 'identityfile %s\n' ${lib.escapeShellArgs c.files} | sort)
          [ "$files" = "$want" ] || fail "${n}: the identity files are $files, not $want"
          grep -qx 'forwardagent no' <<<"$got" || fail "${n}: the agent is forwarded"
          # One touch holds for ten minutes, on a socket in the runtime
          # directory, and `ssh -O check` finds it, as on Fedora.
          grep -qx 'controlmaster auto' <<<"$got" || fail "${n}: no ControlMaster: $(grep '^controlmaster' <<<"$got")"
          grep -qx 'controlpersist 600' <<<"$got" || fail "${n}: ControlPersist is not 10 minutes"
          grep -q '^controlpath /run/user/' <<<"$got" || fail "${n}: the ControlPath is not in the runtime directory: $(grep '^controlpath' <<<"$got")"
        ''
      ) cases
    ) (lib.attrNames variants)}

    # The alias reaches the pin through its HostName.
    got=$(g plain gitalias)
    grep -qx 'identityagent none' <<<"$got" || fail "an alias of $first asks an agent"
    files=$(grep '^identityfile ' <<<"$got" | sort || true)
    want=$(printf 'identityfile %s\n' ${lib.escapeShellArgs gitKeys.${lib.head hosts}} | sort)
    [ "$files" = "$want" ] || fail "an alias of $first has the identity files $files"

    # The deliberate fallback, by hand, still reaches the agent, and opens
    # no master: one on the pinned ControlPath would carry every plain push
    # for ten minutes with no touch. Both as the header writes it on the
    # command line and as an alias with ControlPath none.
    ${
      if fallbackLines == [ ] then
        ''fail "the header of modules/desktop/git-hosts.nix documents no GIT_SSH_COMMAND fallback"''
      else
        ''
          got=$(g plain ${lib.escapeShellArgs fallbackArgs} "$first")
          grep -qx 'identityagent /run/user/1000/fallback.sock' <<<"$got" || fail "the documented fallback does not override the pin: $(grep '^identityagent' <<<"$got")"
          grep -qx 'identitiesonly no' <<<"$got" || fail "the documented fallback keeps IdentitiesOnly"
          if grep -q '^controlpath ' <<<"$got"; then fail "the documented fallback opens a master that pinned pushes reuse: $(grep '^controlpath' <<<"$got")"; fi
        ''
    }
    got=$(g plain gitfallback)
    grep -qx 'identityagent /run/user/1000/fallback.sock' <<<"$got" || fail "a fallback alias of $first does not reach its agent"
    if grep -q '^controlpath ' <<<"$got"; then fail "a fallback alias with ControlPath none opens a master: $(grep '^controlpath' <<<"$got")"; fi

    # Any other host keeps rbw's agent.
    got=$(g plain other.example.org)
    if grep -qx 'identityagent none' <<<"$got"; then fail "other.example.org gets no agent"; fi

    ${lib.optionalString ((configOf without) != null) ''
      if grep -qi 'identityagent none' ${configOf without}; then fail "a git host block without ravnix.laptop.gitKeys"; fi
    ''}
    [ "$status" = 0 ] && touch $out
    exit $status
  ''
