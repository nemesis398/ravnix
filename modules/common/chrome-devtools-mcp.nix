# The Chrome DevTools MCP server for Claude Code, on both hosts: the user-scope
# MCP server `chrome-devtools`, which is the wrapper chrome-devtools-mcp-helium
# (packages/chrome-devtools-mcp-helium) driving a headless Helium. Claude Code
# sessions mostly run on the server (muninn), so the server gets the browser
# and the wrapper too; the laptop (huginn) has them for the sessions it runs.
# Headless means no window and no display: the browser needs neither, so the
# same entry works on a host with Sway and on one with no graphical session.
#
# The server is declared through ravnix.claude.mcpServers, which
# claude-mcp.nix puts into ~/.claude.json at every switch, so it keeps its
# name and its tools (mcp__chrome-devtools__*). The command is a store path,
# not a name on the PATH: the entry works from any shell and any working
# directory, and a switch that updates the wrapper rewrites the path. A session
# that is already running keeps the one it started with, which stays in the
# store until it is collected.
#
# To use another server under that name, set it in me.nix:
#   ravnix.claude.mcpServers.chrome-devtools = { ...your server... };
# It replaces this one whole, and the servers you declare under other names
# come beside it. It follows programs.claude-code.enable: with Claude Code
# off, claude-mcp.nix takes ravnix's servers out of ~/.claude.json.
#
# Why the priorities are nested. nixosModules.common hands me.nix's value of
# ravnix.claude.mcpServers to home-manager as one lib.mkDefault on the whole
# set (nixos.nix), and the module system keeps only the definitions of the
# highest priority of an option before it merges the entries of an attrsOf.
# A plain `ravnix.claude.mcpServers.chrome-devtools = ...` here would
# therefore outrank that definition and silently drop every server of me.nix
# (tests/common/chrome-devtools-mcp.nix has the case). So this declaration is
# a lib.mkDefault on the whole set as well, and only the entry is a
# lib.mkOptionDefault: a chrome-devtools of me.nix then wins over it whole,
# instead of merging key by key and failing on the first key they disagree
# about. A server set with a plain definition in home-manager outranks both,
# which is how every value of ravnix reaches home-manager (nixos.nix): it
# replaces what me.nix and this module declare, not only one entry.
#
# It reads pkgs.ravnix, so the pkgs must carry overlays.default:
# nixosModules.common applies it, and so does any other host that builds the
# home from a pkgs with it (tests/common/helpers/hm.nix).
{ lib, pkgs, ... }:
let
  wrapper = pkgs.ravnix.chrome-devtools-mcp-helium;
in
{
  config = {
    ravnix.claude.mcpServers = lib.mkDefault {
      chrome-devtools = lib.mkOptionDefault {
        type = "stdio";
        command = lib.getExe wrapper;
        args = [ ];
      };
    };
    # Also on the PATH, to try the server by hand (`chrome-devtools-mcp-helium
    # --help` lists what it takes).
    home.packages = [ wrapper ];
  };
}
