# The personal values of the public Claude Code skills: names, destinations
# and ids that the skills read from one generated JSON file instead of
# carrying them in their text. And the MCP servers Claude Code starts with.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.ravnix.claude;

  # What JSON can hold. No Nix paths: a path would be copied into the store
  # and rendered as its store path.
  json =
    types.nullOr (
      types.oneOf [
        types.bool
        types.int
        types.float
        types.str
        (types.attrsOf json)
        (types.listOf json)
      ]
    )
    // {
      description = "JSON value";
    };

  # What a header or an environment value of a server may be. Claude Code
  # resolves ${NAME} in its own environment when it reads the config, so the
  # value in the Nix store is the reference, and the token is in the
  # environment of the one process that needs it (ravnix.shell.secretEnv puts
  # it there). The reference may follow an authorization scheme, because that
  # is what a header looks like (`Bearer ${NAME}`); nothing else may stand
  # beside it, and a default (`${NAME:-x}`) is a place for a token to hide.
  reference = "([$][{][A-Za-z_][A-Za-z0-9_]*[}])";
  isReference = v: builtins.isString v && builtins.match "((Bearer|Basic|Token) )?${reference}" v != null;

  # The fields of a server that carry values to the server, by what the
  # message calls them. Both are sets of values, or absent.
  valueFields = [
    "headers"
    "env"
  ];

  # One message per fault, naming the server, the field and the key, and
  # never the value: it may be a token pasted by mistake, and the message
  # goes to the terminal and the log.
  faults = lib.concatMap (
    name:
    let
      server = cfg.mcpServers.${name};
      where = "ravnix.claude.mcpServers.${name}";
      field =
        f:
        let
          v = server.${f};
        in
        if v == null || !builtins.isAttrs v then
          [ "${where}.${f} must be a set of strings, each a reference such as \"Bearer \${NAME}\" or \"\${NAME}\"." ]
        else
          map (
            key:
            "${where}.${f}.${key} is not a reference such as \"Bearer \${NAME}\" or \"\${NAME}\": a header or an environment value holds a variable of Claude Code's environment (a secret reaches it through ravnix.shell.secretEnv), never the value itself, so that no token enters the Nix store."
          ) (lib.filter (key: !isReference v.${key}) (lib.attrNames v));
    in
    if !builtins.isAttrs server then
      [ "${where} must be a set, the JSON of one server as Claude Code's mcpServers holds it." ]
    else
      lib.concatMap field (lib.filter (f: server ? ${f}) valueFields)
  ) (lib.attrNames cfg.mcpServers);
in
{
  options.ravnix.claude.skillValues = mkOption {
    type = types.attrsOf json;
    default = { };
    example = {
      vault.root = "/home/alice/notes";
    };
    description = ''
      The values the public skills read, rendered to JSON. A skill whose
      value is missing stops and names the key to set.
    '';
  };

  options.ravnix.claude.mcpServers = mkOption {
    type = types.attrsOf json;
    default = { };
    example = {
      docs = {
        type = "http";
        url = "https://mcp.example.org/mcp";
        headers.Authorization = "Bearer \${DOCS_API_TOKEN}";
      };
      browser = {
        type = "stdio";
        command = "example-mcp";
        args = [ "--headless" ];
      };
    };
    description = ''
      The MCP servers Claude Code knows in every project (its user scope), by
      name, each the JSON that Claude Code's `mcpServers` holds for a server.
      The servers of this option are put into Claude Code's config
      (~/.claude.json) at every switch. A server you add yourself with
      `claude mcp add --scope user` stays, and a server you stop declaring
      here is taken out at the next switch.

      A header or an environment value must be a reference to a variable of
      Claude Code's environment: `''${NAME}`, or `Bearer ''${NAME}` (also
      `Basic` and `Token`). Anything else is refused at evaluation, so that
      no token can enter the Nix store. The variable gets its value from
      `ravnix.shell.secretEnv`, which the `claude` function reads from your
      Bitwarden when Claude Code starts.
    '';
  };

  config.assertions = map (message: {
    assertion = false;
    inherit message;
  }) faults;
}
