# The MCP servers of Claude Code (ravnix.claude.mcpServers) in a
# home-manager configuration built from the template's me.nix: the servers
# are put into Claude Code's user-scope config by an activation step, a
# server that Claude Code added itself survives a switch, and a header or
# an environment value that is not a ${VAR} reference is refused at
# evaluation, so no token can enter the Nix store. The evaluated facts are
# checked here; the built home is checked in the sandbox, down to the real
# claude adding a server, the activation step running on its file, and
# `claude mcp list` and `claude mcp get` reading the result.
#
# The servers are made up: mcp.example.test is reserved for documentation,
# and so are the variables.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  eval = import ../options/helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;

  user = {
    home = {
      username = "alice";
      homeDirectory = "/home/alice";
      stateVersion = "26.05";
    };
  };
  hm =
    modules:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        self.homeModules.options
        template
        user
        # The warnings are the template's own, about its example values.
        { warnings = lib.mkForce [ ]; }
      ]
      ++ modules;
    };
  # home-manager checks the assertions as soon as anything reads config.
  evaluates = home: (builtins.tryEval (builtins.deepSeq home.config.home.username true)).success;
  package = self.packages.${system}.claude-code;

  servers = {
    example = {
      type = "http";
      url = "https://mcp.example.test/mcp";
      headers = {
        Authorization = "Bearer \${EXAMPLE_TOKEN}";
        x-example = "\${EXAMPLE_VALUE}";
      };
    };
    local = {
      type = "stdio";
      command = "example-mcp";
      args = [
        "--flag"
        "x y"
      ];
      env.EXAMPLE_KEY = "\${EXAMPLE_KEY}";
    };
  };
  withServers = s: [
    self.homeModules.claude-code
    { ravnix.claude.mcpServers = s; }
  ];

  home = hm (withServers servers);
  inherit (home) config;
  oneOnly = hm (withServers { inherit (servers) example; });
  nothing = hm [ self.homeModules.claude-code ];
  off = hm (
    withServers servers
    ++ [
      { programs.claude-code.enable = false; }
    ]
  );
  elsewhere = hm (
    withServers servers
    ++ [
      { programs.claude-code.configDir = "/home/alice/.config/claude"; }
    ]
  );
  # The modules imported twice put the servers in once.
  twice = hm (withServers servers ++ [ self.homeModules.claude-code ]);

  stepOf = h: h.config.home.activation.ravnixClaudeMcp or { after = [ ]; data = ""; };

  # The refusal. A canary stands for a token pasted into the flake by
  # mistake: it must never be echoed in the message that refuses it.
  canary = "s3cr3t-canary-0123";
  failures =
    s:
    lib.filter (m: lib.hasInfix "ravnix.claude.mcpServers" m) (
      (eval [
        template
        { ravnix.claude.mcpServers = s; }
      ]).failed
    );
  refused = s: failures s != [ ];
  accepted = s: failures s == [ ];
  header = v: { x.headers.Authorization = v; };
  envOf = v: { x.env.KEY = v; };
  refusedAll = lib.all refused;
  acceptedAll = lib.all accepted;
  echoes = s: lib.any (lib.hasInfix canary) (failures s);

  checks = [
    {
      name = "no assertion fails";
      ok = evaluates home;
    }
    {
      name = "there are no servers unless the user declares them";
      ok =
        nothing.config.ravnix.claude.mcpServers == { }
        && (eval [ template ]).config.ravnix.claude.mcpServers == { };
    }
    {
      name = "the servers are the ones declared";
      ok = config.ravnix.claude.mcpServers == servers;
    }
    {
      name = "they do not go through home-manager's programs.claude-code.mcpServers, which makes a plugin of them (plugin:hm:NAME, tools named mcp__plugin_hm_NAME__TOOL)";
      ok =
        config.programs.claude-code.mcpServers == { }
        && !(config.home.file ? ".claude/skills/claude-code-home-manager");
    }
    {
      name = "an activation step of ravnix's own puts them in, after home-manager has written its files";
      ok = lib.elem "writeBoundary" (stepOf home).after;
    }
    {
      name = "the step names ~/.claude.json, where Claude Code keeps its user-scope config";
      ok = lib.hasInfix "/home/alice/.claude.json" (stepOf home).data;
    }
    {
      name = "with another config directory it names the .claude.json inside it, as Claude Code does when CLAUDE_CONFIG_DIR is set";
      ok =
        lib.hasInfix "/home/alice/.config/claude/.claude.json" (stepOf elsewhere).data
        && elsewhere.config.home.sessionVariables.CLAUDE_CONFIG_DIR == "/home/alice/.config/claude";
    }
    {
      name = "the step names the old .config.json of the config directory, which Claude Code may read instead";
      ok =
        lib.hasInfix "/home/alice/.claude/.config.json" (stepOf home).data
        && lib.hasInfix "/home/alice/.config/claude/.config.json" (stepOf elsewhere).data;
    }
    {
      name = "the step is there with no servers declared, to take out the ones it put in before";
      ok = nothing.config.home.activation ? ravnixClaudeMcp;
    }
    {
      name = "the modules imported twice put each server in once";
      ok = twice.config.ravnix.claude.mcpServers == servers;
    }

    # What the store may hold.
    {
      name = "a header and a variable that are references are accepted: \${VAR}, Bearer \${VAR}, Basic \${VAR}, Token \${VAR}";
      ok = acceptedAll [
        (header "\${A}")
        (header "Bearer \${A}")
        (header "Basic \${A_1}")
        (header "Token \${_a}")
        (envOf "\${A}")
        { x.headers = { }; }
        { x.env = { }; }
        { x = { type = "http"; url = "https://mcp.example.test/mcp"; }; }
      ];
    }
    {
      name = "a literal header is refused, and the message does not repeat it";
      ok = refusedAll [
        (header canary)
        (header "Bearer ${canary}")
      ]
      && !(echoes (header canary))
      && !(echoes (header "Bearer ${canary}"));
    }
    {
      name = "a literal environment value is refused, and the message does not repeat it";
      ok = refused (envOf canary) && !(echoes (envOf canary));
    }
    {
      name = "the refusal names the server, the field and the key";
      ok =
        let
          m = lib.concatStrings (failures {
            plane.headers.Authorization = canary;
            tool.env.KEY = canary;
          });
        in
        lib.hasInfix "plane" m
        && lib.hasInfix "headers" m
        && lib.hasInfix "Authorization" m
        && lib.hasInfix "tool" m
        && lib.hasInfix "env" m
        && lib.hasInfix "KEY" m;
    }
    {
      name = "a reference with a default is refused: the default is a place for a token";
      ok = refusedAll [
        (header "\${A:-${canary}}")
        (header "Bearer \${A:-${canary}}")
        (envOf "\${A:-}")
      ] && !(echoes (header "\${A:-${canary}}"));
    }
    {
      name = "a reference mixed with other text is refused: only an auth scheme may stand before it";
      ok = refusedAll [
        (header "Bearer ${canary} \${A}")
        (header "x-\${A}")
        (header "\${A}-${canary}")
        (header "\${A}\${B}")
        (header "Digest \${A}")
        (header "bearer \${A}")
        (header "Bearer  \${A}")
        (header "Bearer \${A} ")
        (envOf "Bearer \${A}-x")
      ];
    }
    {
      name = "what is not a reference is refused: a bare $VAR, an empty or numeric or unclosed name";
      ok = refusedAll [
        (header "$A")
        (header "\${}")
        (header "\${1A}")
        (header "\${A")
        (header "\${A-B}")
        (header "")
        (header "Bearer ")
        (envOf "$A")
      ];
    }
    {
      name = "a value that is no string is refused";
      ok = refusedAll [
        (header 42)
        (header true)
        (header null)
        (header [ "\${A}" ])
        (header { a = "\${A}"; })
        (envOf 1.5)
        (envOf null)
      ];
    }
    {
      name = "headers or env that are no set of values, or a server that is no set, are refused";
      ok = refusedAll [
        { x.headers = canary; }
        { x.headers = [ "\${A}" ]; }
        { x.headers = null; }
        { x.env = canary; }
        { x.env = [ ]; }
        { x = canary; }
        { x = null; }
        { x = [ ]; }
      ];
    }
    {
      name = "one bad value in many is refused, and each bad one is named once";
      ok =
        lib.length (failures {
          a.headers.X = "\${A}";
          b.headers.X = canary;
          c.env.Y = canary;
          c.env.Z = "\${Z}";
        }) == 2;
    }
    {
      name = "a home with a literal header does not evaluate, and one with a reference does";
      ok =
        !(evaluates (hm (withServers (header canary))))
        && !(evaluates (hm (withServers (envOf canary))))
        && evaluates (hm (withServers (header "Bearer \${A}")));
    }
    {
      name = "the refusal is in the options, so ravnix's own check of the private flake sees it before any host";
      ok = refused (header canary) && (eval [ template ]).failed == [ ];
    }
  ];

  activation = home.activationPackage;
  oneActivation = oneOnly.activationPackage;
  nothingActivation = nothing.activationPackage;
  offActivation = off.activationPackage;
in
pkgs.runCommand "claude-mcp"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.jq
    ];
    expectedServers = builtins.toJSON servers;
  }
  ''
    # Every check reports, failed or not; the build fails at the end.
    set +e
    fail=0
    check() {
      if [ "$2" = 0 ]; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi
    }
    ${lib.concatMapStrings (c: ''
      check ${lib.escapeShellArg c.name} ${if c.ok then "0" else "1"}
    '') checks}

    # The activation's step, as the activate script runs it, on a config
    # here instead of /home/alice's.
    export HOME=$PWD/home
    mkdir -p "$HOME" state
    config=$HOME/.claude.json
    statefile=$PWD/state/servers.json

    # steps <activation> <name>...: the named steps of its activate script.
    steps() {
      local activate=$1/activate name
      shift
      echo 'errorEcho() { echo "$@" >&2; }'
      for name; do
        awk -v s="$name" '
          $0 == "_iNote \"Activating %s\" \"" s "\"" { on = 1; next }
          on && /^_iNote "Activating %s"/ { exit }
          on' "$activate"
      done
    }
    # rest: every key of the config but mcpServers, sorted. Claude Code keeps
    # its history, account and projects there; a switch must not touch them.
    rest() { jq -S 'del(.mcpServers)' "$config" 2>/dev/null; }
    # switch <activation>: runs the MCP step of that home on $config, and
    # reports whether any other key changed.
    switch() {
      local script before after rc
      script=$(steps "$1" ravnixClaudeMcp)
      [ -n "$script" ] || return 1
      script=''${script//\/home\/alice\/.claude.json/$config}
      script=''${script//\/home\/alice\/.local\/state\/ravnix\/claude-mcp-servers.json/$statefile}
      before=$(rest)
      ${lib.getExe pkgs.bash} -eu -o pipefail -c "$script"
      rc=$?
      after=$(rest)
      [ "$before" = "$after" ]
      check "  (a switch changes no key but mcpServers)" $?
      return $rc
    }
    # claude <arguments>: the real one, with a home of its own.
    claude() {
      env -i HOME="$HOME" PATH="$PATH" DISABLE_AUTOUPDATER=1 \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
        ${pkgs.coreutils}/bin/timeout 120 ${package}/bin/claude "$@"
    }
    # names: the user-scope servers in the config, sorted.
    names() { jq -r '.mcpServers // {} | keys | join(" ")' "$config"; }

    # A server that Claude Code adds itself, with its own command. The time it
    # takes is the yardstick of the lock test below.
    t0=$(date +%s%N)
    added=$(claude mcp add --scope user --transport http added https://added.example.test/mcp 2>&1)
    unlocked=$(( ($(date +%s%N) - t0) / 1000000 ))
    [ "$(names)" = added ]
    check "claude mcp add --scope user writes ~/.claude.json mcpServers ($added)" $?
    [ "$(rest | jq length)" -gt 3 ]
    check "and keys besides mcpServers, so that the comparison after each switch has something to lose ($(rest | jq length) keys)" $?

    switch ${activation}
    rc=$?
    check "the step runs" $rc
    [ "$(names)" = "added example local" ]
    check "a switch keeps the server Claude Code added and puts ravnix's two in" $?
    jq -S '.mcpServers | del(.added)' "$config" >got.json
    printf '%s' "$expectedServers" | jq -S . >want.json
    cmp -s got.json want.json
    check "the two are exactly the declared ones, references and all" $?
    grep -q -F 'Bearer ''${EXAMPLE_TOKEN}' "$config"
    check "the file holds the reference, which Claude Code resolves from its environment" $?
    [ "$(jq -r '.mcpServers.added.url' "$config")" = https://added.example.test/mcp ]
    check "the added server is as Claude Code wrote it" $?
    [ "$(stat -c %a "$config")" = 600 ]
    check "the config is mode 600" $?

    # What Claude Code makes of it.
    listed=$(claude mcp list 2>&1)
    for n in added example local; do
      printf '%s\n' "$listed" | grep -q "^$n: "
      check "claude mcp list lists $n" $?
    done
    got=$(claude mcp get example 2>&1)
    printf '%s\n' "$got" | grep -q 'Scope: User config'
    check "claude mcp get reports example in the user scope" $?
    printf '%s\n' "$got" | grep -q 'Type: http'
    check "as an http server" $?
    got=$(claude mcp get local 2>&1)
    printf '%s\n' "$got" | grep -q 'Scope: User config' && printf '%s\n' "$got" | grep -q 'Type: stdio' && printf '%s\n' "$got" | grep -q 'Command: example-mcp'
    check "and local as a stdio server in the user scope, with its command" $?

    cp "$config" first.json
    switch ${activation}
    cmp -s "$config" first.json
    check "a second switch changes nothing" $?

    # The user removes a ravnix server with claude: the next switch is
    # declarative and puts it back.
    claude mcp remove local --scope user >/dev/null 2>&1
    [ "$(names)" = "added example" ]
    check "claude mcp remove takes a ravnix server out of the user scope" $?
    switch ${activation}
    [ "$(names)" = "added example local" ]
    check "the next switch puts it back" $?

    # A server dropped from the declaration goes, and the added one stays.
    switch ${oneActivation}
    [ "$(names)" = "added example" ]
    check "a server no longer declared is taken out at the next switch, and the added one stays" $?

    # Claude Code adds one more after the switch; it survives the next.
    claude mcp add --scope user --transport http later https://later.example.test/mcp >/dev/null 2>&1
    switch ${activation}
    [ "$(names)" = "added example later local" ]
    check "a server added after a switch survives the next one" $?

    # A same-named one that Claude Code added is replaced, as home-manager's
    # merge replaces a declared key.
    jq '.mcpServers.example = {type: "sse", url: "https://stale.example.test/sse", headers: {stale: "1"}}' "$config" >x.json && mv x.json "$config"
    switch ${activation}
    [ "$(jq -c '.mcpServers.example' "$config")" = "$(printf '%s' "$expectedServers" | jq -c .example)" ]
    check "a declared server replaces a same-named one whole" $?

    # Claude Code off: the servers it put in go, the others stay.
    switch ${offActivation}
    [ "$(names)" = "added later" ]
    check "with Claude Code off the next switch takes ravnix's servers out and keeps the others" $?

    # The lock the step takes is the one Claude Code takes: a directory
    # beside the file. If a bump of Claude Code changes that, this fails.
    # Held for 6 s, which is under the 10 s after which a lock is stale and
    # far over what an unlocked add takes, measured above: an add that is
    # still running then is waiting for the lock, whatever the builder's speed.
    mkdir "$config.lock"
    claude mcp add --scope user --transport http held https://held.example.test/mcp >held.out 2>&1 &
    pid=$!
    sleep 6
    kill -0 "$pid" 2>/dev/null && [ "$(names)" = "added later" ]
    check "claude mcp add is still waiting after 6 s of a held $(basename "$config").lock, and has written nothing" $?
    [ "$unlocked" -lt 3000 ]
    check "the unlocked claude mcp add took $unlocked ms, so 6 s of waiting is the lock and not the work" $?
    rmdir "$config.lock"
    wait "$pid"
    [ "$(names)" = "added held later" ] && [ ! -e "$config.lock" ]
    check "and it writes once the lock is released, and leaves no lock" $?

    # Nothing declared and nothing put in before: no file, no state.
    rm -f "$config" "$statefile"
    switch ${nothingActivation}
    rc=$?
    [ $rc = 0 ] && [ ! -e "$config" ] && [ ! -e "$statefile" ]
    check "a home with no servers makes neither ~/.claude.json nor a state file" $?

    [ "$fail" = 0 ] || exit 1
    touch "$out"
  ''
