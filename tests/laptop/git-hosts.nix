# The git hosts on the laptop take the security key and never an agent: for
# each host of ravnix.laptop.gitKeys, the laptop's ssh config, as ssh itself
# reads it (`ssh -G`), has IdentityAgent none, IdentitiesOnly and that host's
# key handles as the only identity files, whatever the case of the name
# (ssh compares host names without it). rbw's agent holds touch-free keys
# for the same hosts (the vault's fallback keys), so a git host that reached
# SSH_AUTH_SOCK would push without the touch. Every other host keeps the
# agent, and without gitKeys there is no such block.
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
    for inc in $(sed -n 's/^Include //p' config); do
      cp "$inc" "inc-''${inc##*/}"
      sed -i "s|$inc|$PWD/inc-''${inc##*/}|" config
    done
    chmod 600 config inc-* 2>/dev/null || true
    g() { ssh -G -F "$PWD/config" "$1" 2>&1 || echo "ssh -G failed: $?"; }

    ${lib.concatMapStrings (c: ''
      got=$(g ${lib.escapeShellArg c.name})
      grep -qx 'identityagent none' <<<"$got" || fail "${c.name}: ssh may ask an agent: $(grep -i '^identityagent' <<<"$got")"
      grep -qx 'identitiesonly yes' <<<"$got" || fail "${c.name}: IdentitiesOnly is off: $(head -3 <<<"$got")"
      files=$(grep '^identityfile ' <<<"$got" | sort || true)
      want=$(printf 'identityfile %s\n' ${lib.escapeShellArgs c.files} | sort)
      [ "$files" = "$want" ] || fail "${c.name}: the identity files are $files, not $want"
      grep -qx 'forwardagent no' <<<"$got" || fail "${c.name}: the agent is forwarded"
    '') cases}

    # Any other host keeps rbw's agent.
    got=$(g other.example.org)
    if grep -qx 'identityagent none' <<<"$got"; then fail "other.example.org gets no agent"; fi

    ${lib.optionalString ((configOf without) != null) ''
      if grep -qi 'identityagent none' ${configOf without}; then fail "a git host block without ravnix.laptop.gitKeys"; fi
    ''}
    [ "$status" = 0 ] && touch $out
    exit $status
  ''
