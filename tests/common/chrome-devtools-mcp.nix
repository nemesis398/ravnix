# The Chrome DevTools MCP server on both hosts (modules/common/
# chrome-devtools-mcp.nix), evaluated: the laptop's desktop and the server
# shape each declare the user-scope MCP server `chrome-devtools` as the
# wrapper of packages/chrome-devtools-mcp-helium, by its store path, and put
# the wrapper on the PATH. A server of the same name that the user sets, in
# me.nix or in home-manager, replaces it whole, instead of merging key by key
# with it, and the servers of me.nix under other names are not lost beside it.
# The VM test desktop-chrome-devtools-mcp runs the server from the
# file this declaration is written to.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  user = (import ../../templates/default/me.nix).ravnix.user.username;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  wrapper = self.packages.${system}.chrome-devtools-mcp-helium;

  host =
    shape: extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ shape ] ++ extra;
    };
  hmOf = h: h.config.home-manager.users.${user};
  serversOf = h: (hmOf h).ravnix.claude.mcpServers;
  failed = h: map (a: a.message) (lib.filter (a: !a.assertion) h.config.assertions);

  mine = {
    type = "http";
    url = "https://mcp.example.test/mcp";
  };
  shapes = {
    server = self.nixosModules.server;
    desktop = self.nixosModules.desktop;
  };

  hm = import ../common/helpers/hm.nix { inherit self inputs pkgs lib; };

  perShape =
    name: shape:
    let
      plain = host shape [ ];
      byMe = host shape [ { ravnix.claude.mcpServers.chrome-devtools = mine; } ];
      beside = host shape [ { ravnix.claude.mcpServers.docs = mine; } ];
      byHome = host shape [
        { home-manager.users.${user}.ravnix.claude.mcpServers.chrome-devtools = mine; }
      ];
      server = (serversOf plain).chrome-devtools or null;
    in
    [
      (lib.optional (failed plain != [ ]) "${name}: an assertion fails: ${toString (failed plain)}")
      (lib.optional (server == null) "${name}: no chrome-devtools server is declared")
      (lib.optional (
        server != null && server.type != "stdio"
      ) "${name}: the server is not a stdio server: ${server.type}")
      (lib.optional (
        server != null && server.command != lib.getExe wrapper
      ) "${name}: the command is not the wrapper of the package: ${server.command}")
      (lib.optional (
        server != null && !lib.hasPrefix "${builtins.storeDir}/" server.command
      ) "${name}: the command is not a store path, so it depends on the PATH of whoever starts Claude Code")
      (lib.optional (server != null && server.args != [ ]) "${name}: the server takes arguments: ${toString server.args}")
      (lib.optional (
        !lib.any (p: p.outPath == wrapper.outPath) (hmOf plain).home.packages
      ) "${name}: the wrapper is not on the PATH of the user")
      (lib.optional (
        (serversOf byMe).chrome-devtools or null != mine
      ) "${name}: a server of me.nix does not replace the declared one whole: ${builtins.toJSON (serversOf byMe).chrome-devtools or null}")
      (lib.optional (
        (serversOf byHome).chrome-devtools or null != mine
      ) "${name}: a server of home-manager does not replace the declared one whole: ${builtins.toJSON (serversOf byHome).chrome-devtools or null}")
      (lib.optional (failed byMe != [ ]) "${name}: a server of me.nix fails an assertion: ${toString (failed byMe)}")
      (lib.optional (
        (serversOf beside).docs or null != mine
      ) "${name}: a server of me.nix under another name is lost: ${builtins.toJSON (serversOf beside)}")
      (lib.optional (
        (serversOf beside).chrome-devtools or null != server
      ) "${name}: a server of me.nix under another name replaces the declared one: ${builtins.toJSON (serversOf beside)}")
    ];

  # homeModules.common by itself, with the overlay on its pkgs, as the helper
  # of the common tests builds it. The template's me.nix is a home-manager
  # module there and sets ravnix.claude.mcpServers plain, which outranks the
  # declaration (see the module), so only that the home evaluates is asked.
  standalone = (hm [ ]).config;

  failures = lib.flatten (
    lib.mapAttrsToList perShape shapes
    ++ [
      (map (m: "homeModules.common alone fails: ${m}") (
        map (a: a.message) (lib.filter (a: !a.assertion) standalone.assertions)
      ))
      (lib.optional (
        !lib.any (p: p.outPath == wrapper.outPath) standalone.home.packages
      ) "homeModules.common alone does not put the wrapper on the PATH")
    ]
  );
in
pkgs.runCommand "common-chrome-devtools-mcp" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
