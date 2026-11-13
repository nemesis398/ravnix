# Helium's native-messaging hosts (modules/desktop/apps.nix): the two
# manifests in ~/.config/net.imput.helium/NativeMessagingHosts/ that let a
# browser extension start a program of the desktop.
#
#   - Claude in Chrome (extension fcoeoabgfenejglbffodgkkbkcdhcgfn) reaches
#     Claude Code through com.anthropic.claude_code_browser_extension.json,
#     whose `path` is a wrapper that runs the claude of the user's profile
#     (/etc/profiles/per-user/USER/bin/claude) with --chrome-native-host, not
#     a store path of one build: Claude Code is updated twice a day, and the
#     manifest has to follow each update. The profile holds the configured
#     package's claude. Run as Helium runs it (the origin as its argument, the
#     message on stdin), the wrapper starts claude with --chrome-native-host
#     alone and hands stdin through; with no claude in the profile it fails.
#     The manifest is a home-manager link, so it is there only while Claude
#     Code is on.
#   - Bitwarden desktop's bridge, com.8bit.bitwarden.json, names the proxy of
#     nixpkgs' bitwarden-desktop and exactly the four extension origins
#     Bitwarden itself writes. Bitwarden rewrites this file at every start
#     (native-messaging.main.ts, generateManifests, then listen), and a write
#     that fails skips listen(), which would cut every browser off. So the
#     file is a regular file the user can write, put there by an activation
#     step, not a link into the read-only store: the step replaces a link or
#     an old file, and leaves a file Bitwarden can write.
#   - The step creates the profile directory 0700, as Helium does, when it is
#     missing, and leaves the mode of one that exists. It creates
#     NativeMessagingHosts/ in a profile that lacks it, as one copied from
#     another machine without that directory does: Bitwarden copies its proxy
#     into it before it writes its manifest, and does not create it, so
#     without it generateManifests() throws and listen() is skipped.
#   - The step runs after writeBoundary and before linkGeneration, so the
#     Claude manifest's link finds the directories already private; after
#     linkGeneration, home-manager would create them 0755.
#   - A step that cannot write only warns: the rest of the home's activation
#     (the desktop's whole configuration) still runs.
#   - Nothing of either on a host without the desktop (the server shape), and
#     no Claude manifest with Claude Code off; Bitwarden's stays, because
#     Bitwarden desktop is still installed.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  mkHost =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ modules;
    };

  desktop = (mkHost [ self.nixosModules.desktop ]).config;
  claudeOff =
    (mkHost [
      self.nixosModules.desktop
      { home-manager.sharedModules = [ { programs.claude-code.enable = false; } ]; }
    ]).config;
  server = (mkHost [ self.nixosModules.common ]).config;

  user = desktop.ravnix.user.username;
  hmOf = c: c.home-manager.users.${user};
  hm = hmOf desktop;

  dir = "net.imput.helium/NativeMessagingHosts";
  claudeName = "${dir}/com.anthropic.claude_code_browser_extension.json";
  step = "ravnixHeliumHosts";

  claudeFile = c: (hmOf c).xdg.configFile.${claudeName} or null;
  hasStep = c: (hmOf c).home.activation ? ${step};
  # Every home file and config file of a home whose target is in the hosts
  # directory.
  hostFiles =
    c:
    lib.filter (n: lib.hasInfix "NativeMessagingHosts" n) (
      lib.attrNames (hmOf c).xdg.configFile ++ lib.attrNames (hmOf c).home.file
    );

  claude = hm.programs.claude-code.finalPackage;
  profileDir = hm.home.profileDirectory;
  # The per-user profile NixOS builds from users.users.USER.packages, where
  # home-manager (useUserPackages) puts home.path, the env of home.packages.
  inProfile =
    lib.elem hm.home.path.outPath (map (p: p.outPath) desktop.users.users.${user}.packages)
    && lib.elem claude.outPath (map (p: p.outPath) hm.home.packages)
    && desktop.environment.etc ? "profiles/per-user/${user}";

  failures = lib.flatten [
    (lib.optional (claudeFile desktop == null) "the desktop has no Claude manifest in ~/.config/${dir}")
    (lib.optional (
      claudeFile desktop != null && !(claudeFile desktop).force
    ) "the Claude manifest does not replace a file in its way")
    (lib.optional (!hasStep desktop) "the desktop has no activation step ${step}")
    (lib.optional (
      hasStep desktop && !(lib.elem "writeBoundary" hm.home.activation.${step}.after)
    ) "the step ${step} does not run after writeBoundary")
    (lib.optional (
      hasStep desktop && !(lib.elem "linkGeneration" hm.home.activation.${step}.before)
    ) "the step ${step} does not run before linkGeneration, whose link would create the profile 0755")
    (lib.optional (claudeFile claudeOff != null) "the Claude manifest is written with Claude Code off")
    (lib.optional (!hasStep claudeOff) "the Bitwarden step is gone with Claude Code off")
    (lib.optional (hostFiles server != [ ]) "the server writes ${toString (hostFiles server)}")
    (lib.optional (hasStep server) "the server has the activation step ${step}")
    (lib.optional (
      profileDir != "/etc/profiles/per-user/${user}"
    ) "the home's profile directory is ${profileDir}, not the per-user profile")
    (lib.optional (!inProfile) "the configured claude is not in the per-user profile")
  ];
in
pkgs.runCommand "desktop-helium-bridges"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.gnugrep
      pkgs.gnused
      pkgs.coreutils
      pkgs.findutils
    ];
    claudeManifest = if claudeFile desktop == null then "" else (claudeFile desktop).source;
    stepData = if hasStep desktop then hm.home.activation.${step}.data else "";
    homeDir = hm.home.homeDirectory;
    configHome = hm.xdg.configHome;
    inherit profileDir;
    claudePkg = claude;
    claudeProfile = pkgs.buildEnv {
      name = "claude-profile";
      paths = [ claude ];
    };
    proxy = "${pkgs.bitwarden-desktop}/libexec/desktop_proxy";
  }
  ''
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    ${lib.concatMapStrings (m: "fail ${lib.escapeShellArg m}\n") failures}

    echo "==> the Claude manifest"
    if [ -n "$claudeManifest" ]; then
      jq -e . "$claudeManifest" > /dev/null || fail "the Claude manifest is no JSON"
      [ "$(jq -r .name "$claudeManifest")" = com.anthropic.claude_code_browser_extension ] \
        || fail "the Claude manifest's name is $(jq -r .name "$claudeManifest")"
      [ "$(jq -r .type "$claudeManifest")" = stdio ] || fail "the Claude manifest's type is not stdio"
      [ "$(jq -c .allowed_origins "$claudeManifest")" = '["chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/"]' ] \
        || fail "the Claude manifest allows $(jq -c .allowed_origins "$claudeManifest")"
      wrapper=$(jq -r .path "$claudeManifest")
      case $wrapper in
        /nix/store/*) ;;
        *) fail "the Claude manifest's path is $wrapper, not a store path" ;;
      esac
      [ -f "$wrapper" ] && [ -x "$wrapper" ] || fail "the Claude manifest's path $wrapper is no executable file"

      echo "==> the wrapper runs the profile's claude"
      grep -qF "$profileDir/bin/claude" "$wrapper" || fail "the wrapper does not name $profileDir/bin/claude"
      if grep -o '/nix/store/[a-z0-9]*-[^/ ]*/bin/claude' "$wrapper" | grep -q .; then
        fail "the wrapper names a store path of claude: $(grep -o '/nix/store/[a-z0-9]*-[^/ ]*/bin/claude' "$wrapper")"
      fi
      # The profile of the host links the configured package's claude
      # (checked at evaluation above); a profile built the same way from that
      # package resolves to it.
      [ "$(readlink -f "$claudeProfile/bin/claude")" = "$(readlink -f "$claudePkg/bin/claude")" ] \
        || fail "a profile of the configured package does not resolve to its claude"
      [ -x "$claudePkg/bin/claude" ] || fail "$claudePkg/bin/claude is not executable"
      # The wrapper, with the profile moved to a scratch one whose claude
      # prints what it was started with, as Helium starts it: with the
      # extension's origin as its argument and the message on stdin.
      mkdir -p fake/bin
      printf '#!%s\nprintf "%%s\\n" "$@"\ncat\n' "$(command -v bash)" > fake/bin/claude
      chmod +x fake/bin/claude
      sed "s|$profileDir|$PWD/fake|g" "$wrapper" > moved
      chmod +x moved
      got=$(printf 'MSG' | ./moved chrome-extension://fcoeoabgfenejglbffodgkkbkcdhcgfn/)
      [ "$got" = "$(printf -- '--chrome-native-host\nMSG')" ] || fail "the wrapper started claude with: $got"
      # A claude that is gone (Claude Code turned off since) fails loudly.
      rm fake/bin/claude
      if ./moved 2> gone.log; then fail "the wrapper succeeds without a claude"; fi
    fi

    echo "==> the Bitwarden manifest, by the activation step"
    if [ -n "$stepData" ]; then
      export HOME=$TMPDIR/home
      run() { "$@"; }
      warnEcho() { printf '%s\n' "$*" >> warn.log; }
      config=$HOME''${configHome#"$homeDir"}
      hosts=$config/${dir}
      activate() { eval "$(printf '%s\n' "$stepData" | sed "s|$homeDir|$HOME|g")"; }

      # A home without a Helium profile: the step makes it, private.
      activate || fail "the step fails on a home without a profile"
      bw=$hosts/com.8bit.bitwarden.json
      [ -f "$bw" ] && [ ! -L "$bw" ] || fail "the Bitwarden manifest is not a regular file"
      [ "$(stat -c %a "$config/net.imput.helium")" = 700 ] || fail "the profile directory is $(stat -c %a "$config/net.imput.helium"), not 700"
      if [ -d "$hosts" ]; then
        [ "$(stat -c %a "$hosts")" = 700 ] || fail "the hosts directory is $(stat -c %a "$hosts"), not 700"
      else
        fail "the step makes no NativeMessagingHosts/: Bitwarden copies its proxy there before it writes its manifest, so without it generateManifests() throws and listen() is skipped for every browser"
      fi
      [ "$(jq -r .name "$bw")" = com.8bit.bitwarden ] || fail "the Bitwarden manifest's name is $(jq -r .name "$bw")"
      [ "$(jq -r .type "$bw")" = stdio ] || fail "the Bitwarden manifest's type is not stdio"
      [ "$(jq -c .allowed_origins "$bw")" = '["chrome-extension://nngceckbapebfimnlniiiahkandclblb/","chrome-extension://hccnnhgbibccigepcmlgppchkpfdophk/","chrome-extension://jbkfoedolllekgbhcbcoahefnbanhhlh/","chrome-extension://ccnckbpmaceehanjmeomladnmlffdjgn/"]' ] \
        || fail "the Bitwarden manifest allows $(jq -c .allowed_origins "$bw")"
      [ "$(jq -r .path "$bw")" = "$proxy" ] || fail "the Bitwarden manifest's path is $(jq -r .path "$bw"), not $proxy"
      [ -f "$proxy" ] && [ -x "$proxy" ] || fail "$proxy is no executable file"
      # Bitwarden's own write at its start (fs.writeFile) must succeed.
      printf '{}' > "$bw" || fail "the user cannot write the Bitwarden manifest"

      # Bitwarden's file, and a link into the store, are replaced by ours.
      activate || fail "the step fails over Bitwarden's own file"
      [ "$(jq -r .path "$bw")" = "$proxy" ] || fail "the step leaves Bitwarden's own file"
      rm "$bw"
      ln -s "$claudeManifest" "$bw"
      activate || fail "the step fails over a link"
      [ -f "$bw" ] && [ ! -L "$bw" ] || fail "the step leaves a link in place"
      [ "$(jq -r .name "$bw")" = com.8bit.bitwarden ] || fail "the step writes through the link"
      printf '{}' > "$bw" || fail "the user cannot write the Bitwarden manifest after a link"

      # A profile that exists keeps its mode.
      activate
      chmod 750 "$config/net.imput.helium"
      activate || fail "the step fails on an existing profile"
      [ "$(stat -c %a "$config/net.imput.helium")" = 750 ] || fail "the step changes the mode of an existing profile"

      # A profile copied from another machine, without NativeMessagingHosts/
      # (the transfer leaves it out): the step makes it.
      rm -rf "$hosts"
      activate || fail "the step fails on a profile without NativeMessagingHosts/"
      [ -d "$hosts" ] || fail "the step makes no NativeMessagingHosts/ in an existing profile: Bitwarden copies its proxy there before it writes its manifest, so without it generateManifests() throws and listen() is skipped for every browser"
      [ -f "$hosts/com.8bit.bitwarden.json" ] || fail "the step writes no Bitwarden manifest into an existing profile"

      # A profile the user cannot write (owned by another user, a full disk):
      # the step warns, and the activation goes on to its next step under
      # set -e, as home-manager runs it.
      rm -rf "$config/net.imput.helium"
      mkdir -p "$config/net.imput.helium"
      chmod 500 "$config/net.imput.helium"
      if touch "$config/net.imput.helium/probe" 2> /dev/null; then
        fail "the build user can write a 0500 directory, so the unwritable case proves nothing"
      fi
      : > warn.log
      # Its own bash process: set -e does not apply inside a command whose
      # status a condition tests, so a subshell under `if` would never stop.
      {
        echo 'set -eu'
        echo 'run() { "$@"; }'
        echo "warnEcho() { printf '%s\\n' \"\$*\" >> $PWD/warn.log; }"
        printf '%s\n' "$stepData" | sed "s|$homeDir|$HOME|g"
        echo 'echo next-step'
      } > guarded.sh
      status=0
      bash guarded.sh > guarded.log 2>&1 || status=$?
      [ "$status" = 0 ] || fail "a step that cannot write stops the activation ($status): $(cat guarded.log)"
      grep -qx next-step guarded.log || fail "the activation does not go on after a step that cannot write"
      [ -s warn.log ] || fail "a step that cannot write does not warn"
      chmod 700 "$config/net.imput.helium"

      # A dry run writes nothing.
      rm -rf "$config"
      run() { echo "would run: $*"; }
      activate > dry.log || fail "the dry run fails"
      [ ! -e "$config" ] || fail "the dry run writes $(find "$config")"
    fi

    [ "$failed" = 0 ] || exit 1
    touch $out
  ''
