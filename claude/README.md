# Claude Code: hooks, status line, skill values and MCP servers

This directory holds the Bash that ravnix runs inside Claude Code: the hooks
in `hooks/` and the status line in `statusline/`. They came over from an
earlier setup and stay Bash, behind their tests, until their port to Odin
(AGENTS.md, rule 4). Two home-manager modules install them:

| Module | Does |
| --- | --- |
| `homeModules.claude-code` (`modules/common/claude-code.nix`, `claude-mcp.nix`) | `claude` on PATH, from `packages.claude-code`; the auto-updater off; the settings file writable; the MCP servers in Claude Code's user scope |
| `homeModules.claude-skills` (`modules/common/claude-skills.nix`) | the skill values file, the hooks and the status line, wired in the settings |

`homeModules.common` imports `homeModules.claude-skills`, which brings
`homeModules.claude-code` along, so a host that imports `common` has Claude
Code, its hooks and its skills, and the shell's `claude` function starts the
`claude` of the home-manager profile, that build, with the secrets of
`ravnix.shell.secretEnv` (`modules/common/bash/secrets.bash`). The shell that
Claude Code builds from its snapshot is the exception: the snapshot copies
functions but not variables, so there the function does not know the build,
and `claude` starts the first one on the PATH with only the environment
Claude Code itself holds, its secrets included. One more `claude` can win
over this one: a package in the host's own `users.users.USER.packages`,
because NixOS builds that profile with collisions ignored. Keep Claude Code
out of that list. To turn the function's choice off, set
`programs.claude-code.enable = false`; it then starts the first `claude` on
the PATH everywhere.

Import `homeModules.claude-code` from the flake, not the file. The flake's
module sets the package to `packages.claude-code`, the build with the
download it was made from attached, which `tools/claude-code-verify` checks
against Anthropic's release manifest. The file alone would install nixpkgs'
`claude-code`, which carries no download to check, and an assertion refuses
that.

The full gate of this repository checks the version in ravnix's own
`flake.lock`. A private flake that makes ravnix's `claude-code` input follow
its own, as the template does, installs the version of its own lock, which
that gate never sees. The private flake checks that one itself, with the
same tool on its own `packages.claude-code.download` (Task 6.1's update
timer).

The gate remembers what it verified, in
`${XDG_STATE_HOME:-$HOME/.local/state}/ravnix/claude-code-verified`. While
`downloads.claude.ai` is unreachable it passes for a version and download
it verified before, and fails for any other; a mismatch always fails
(`scripts/README.md`).

## The skill values

The skills, the hooks and the status line read their personal values from
one JSON file, rendered from `ravnix.claude.skillValues` in your `me.nix`:

```
~/.config/ravnix/skill-values.json
```

`RAVNIX_SKILL_VALUES` names it, in the session variables and in Claude
Code's settings `env`. A script that runs without that variable reads
`${XDG_CONFIG_HOME:-~/.config}/ravnix/skill-values.json`. The file sits in
the world-readable Nix store, so it holds values only, never a secret.

A key that is missing, or not of its type, counts as not set. Each script
then turns its part off and fails in no other way:

| Key | Type | Read by | Without it |
| --- | --- | --- | --- |
| `web.searxngUrl` | string, a URL | `web-route.sh` | WebSearch is never routed. `SEARXNG_URL` wins over the key |
| `nextcloud.root` | string, an absolute path | `session-preflight.sh` | no scan for conflicted copies. `PREFLIGHT_NEXTCLOUD_ROOT` wins over the key |
| `vault.root` | string, an absolute path inside `nextcloud.root` | `session-preflight.sh` | the vault's copies are counted under their folder, without the vault's rule |
| `vault.rule` | string, a sentence or two | `session-preflight.sh` | the vault's rule is to change nothing in it without the user's go-ahead |
| `netbird.managementUrl` | string, a URL | `session-preflight.sh` | no server counts as the wrong one, and a NeedsLogin names none |
| `netbird.whenDown` | string, one sentence | `session-preflight.sh` | the NetBird warnings do not say what fails while the mesh is down |
| `statusline.quietHosts` | list of host names, without a domain | `statusline.sh` | every host shows its tag |

For example:

```nix
ravnix.claude.skillValues = {
  web.searxngUrl = "https://search.example.org";
  nextcloud.root = "/home/alice/Nextcloud";
  vault.root = "/home/alice/Nextcloud/Notes";
  vault.rule = "Delete a note only with the vault's own tool, never with rm.";
  netbird.managementUrl = "https://netbird.example.org:443";
  netbird.whenDown = "While the mesh is down, the deploy server refuses every request.";
  statusline.quietHosts = [ "huginn" ];
};
```

## The hooks

`claude-skills` links one wrapper per hook at a fixed path,
`~/.claude/ravnix/hooks/<name>`, and the status line at
`~/.claude/ravnix/statusline`. The settings name those paths, never the
store. Each wrapper puts the tools its script needs first on PATH and execs
bash on the script. The `exec` keeps the process, which the status line
needs: it reads the session kind from its parent's environment.

| Event | Hook | Timeout | Does |
| --- | --- | --- | --- |
| SessionStart | `prune-claude-tmp` | 30 s | deletes the `/tmp/claude-<uid>` folders of sessions that have ended |
| SessionStart | `session-preflight` | 10 s | warns of Nextcloud conflicted copies and a NetBird mesh that is or goes down |
| PreToolUse, matcher `WebSearch` | `web-route` | 5 s | sends WebSearch to `searx` while SearXNG answers |
| WorktreeCreate | `worktree-create` | 600 s | creates and provisions the worktree: ignored files, dependencies, the repository's setup |
| WorktreeRemove | `worktree-remove` | 60 s | runs the repository's teardown, removes the worktree, and its branch when that is safe |
| SubagentStop | `worktree-subagent-stop` | 30 s | sweeps idle subagent worktrees, which Claude Code never removes |

The status line is the statusLine command, with `padding` 0 and a
`refreshInterval` of 60 s.

Each script's header says why it exists and what it does in each case.
`searx`, `netbird`, `pnpm`, `npm` and `uv` come from your PATH, not from
ravnix. A hook whose tool is missing stays silent, except `worktree-create`:
a lockfile whose tool is missing makes the worktree fail.

## Settings and your own hooks

Claude Code writes its settings file itself, so it stays writable. At every
activation home-manager merges the declared settings into it: a declared
key replaces the file's value, whole arrays included, and an undeclared one
keeps it. Declared there, ravnix's hooks would replace the file's whole
list for each of their events, and drop the entries other tools write, such
as herdr's SessionStart entry.

So ravnix's hooks stay out of that merge. A step of their own,
`settings/sync-hooks.sh`, runs after it at every activation. A hook is
ravnix's when its command starts with `~/.claude/ravnix/`, where only
ravnix links its wrappers. The step removes every such hook, adds the ones
ravnix declares now, and drops a group or an event left empty. Every other
entry and every other key stays as it was. A hook ravnix no longer declares
is gone at the next switch. With `claude-skills` or Claude Code turned off,
all of them are. A file whose content would not change is not written, so
its layout stays too.

Hooks of your own can live in the file, by hand or from another tool, and
they stay. Or declare them in your private flake:

```nix
programs.claude-code.settings.hooks.SessionStart = [
  { hooks = [ { type = "command"; command = "my-hook"; } ]; }
];
```

Those go through home-manager's merge, so a declared event replaces the
file's list for it, another tool's entries included. ravnix's own join it
afterwards.

ravnix's hooks are the option `ravnix.claude.hookEntries`, by event. To drop
one of them, set its event there with `lib.mkForce`, as in
`ravnix.claude.hookEntries.PreToolUse = lib.mkForce [ ];`. A `statusLine` of
your own replaces ravnix's without it.

Every hook in `ravnix.claude.hookEntries` must be a command hook whose
command starts with `~/.claude/ravnix/`, because the step can only take out
again what starts there; any other would be added once more at every
switch. An assertion refuses any other hook at evaluation, and the step
refuses it too. Declare it in `programs.claude-code.settings.hooks`, or link
its command under `~/.claude/ravnix/`.

Claude Code writes the file at any time. The step shares its way of
changing such a file with the MCP step (`settings/cas.sh`, described under
"MCP servers"): it takes a lock beside the file, `settings.json.lock`, reads
exactly one JSON document, and moves its result into place only while the
file is still the copy it read; when another write came in between, it reads
the file again, up to five times, and then fails the activation without
writing. So a write by Claude Code that lands before the step's last
comparison is kept; one in the moment between that comparison and the move
can still be lost (Known gaps).

With `mutableSettings = false` home-manager links the file whole from the
store. Then the step is off, and ravnix declares its hooks in that file.

## MCP servers

`ravnix.claude.mcpServers` holds the MCP servers Claude Code starts with in
every project, by name, each the JSON that Claude Code's `mcpServers` holds
for a server. There are none by default. An activation step,
`settings/sync-mcp.sh`, puts them into Claude Code's user-scope config,
`~/.claude.json` (`<configDir>/.claude.json` when the config directory is not
`~/.claude`, which is where Claude Code keeps the file then).

```nix
ravnix.claude.mcpServers = {
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
```

In a Nix string the reference is written `\${NAME}` (or `''${NAME}` inside
`''...''`), because a bare `${NAME}` is Nix's own interpolation and fails
with "undefined variable".

**The server ravnix declares itself.** Both hosts declare the Chrome DevTools MCP
server as `chrome-devtools` (`modules/common/chrome-devtools-mcp.nix`): the
wrapper `chrome-devtools-mcp-helium` driving a headless Helium, by its store
path (`packages/chrome-devtools-mcp-helium/README.md` says why a wrapper). To use
another server under that name, set `ravnix.claude.mcpServers.chrome-devtools`
in `me.nix`; it replaces the declared one whole, and your servers under other
names come beside it. A server set with a plain definition in home-manager
(`home-manager.users.NAME.ravnix.claude.mcpServers`) outranks everything that
`me.nix` and ravnix declare, `chrome-devtools` included, as it does for every
value of ravnix (`modules/common/nixos.nix`).

**No token enters the store.** A value under `headers` or `env` must be a
reference to a variable of Claude Code's environment: `${NAME}`, or
`Bearer ${NAME}` (also `Basic` and `Token`). Anything else is refused at
evaluation, with a message that names the server, the field and the key and
never repeats the value, which may be a token pasted by mistake. So is a
reference with a default (`${NAME:-x}`), which is a place for a token to
hide. The refusal is in the options, so the private flake's own `me` check
shows it before any host exists. Claude Code resolves the reference when it
starts. The value comes into its environment from `ravnix.shell.secretEnv`:
the `claude` function reads the Bitwarden item with rbw and gives it to that
one process. A variable that is no secret can go in
`programs.claude-code.settings.env`, which Claude Code applies before it
resolves the references.

**What the step keeps.** It changes the `mcpServers` key of the file and
nothing else, because Claude Code writes the file all the time and keeps its
history, its account and every project's settings in it. A server you add
with `claude mcp add --scope user` stays. A server in a project's own list
(the local scope) is not touched. A declared server replaces a server of the
same name whole. A server you stop declaring is taken out at the next
switch, and so are all of them when Claude Code is turned off. If you remove
a declared server with `claude mcp remove`, the next switch puts it back:
the declaration wins.

Which servers are ravnix's is told by their names in
`${XDG_STATE_HOME:-~/.local/state}/ravnix/claude-mcp-servers.json`, written
by the step. It sits beside the config and not in it, because Claude Code
owns that file and may drop a marker inside an entry. The step writes it
before the config with the old names and the new ones, and after it with the
new ones only, so a run that dies half-way can still take out what it put in.

**How it writes** (`settings/cas.sh`, which the hook step uses too). Claude
Code saves `~/.claude.json` under a lock, a directory `~/.claude.json.lock`
made with `mkdir`, and reads the file again under it before it applies its
change (checked with Claude Code 2.1.319: a key added to the file while a
`claude mcp add` waited for the lock was still there afterwards). The step
takes the same lock, on the path as given and not through a link, before it
reads, and keeps it until the new file is in place. While a fresh lock stands
(under 10 s old) it waits, 0.2 s and doubling up to 4 s, about 20 s in all,
and then fails the activation without writing; a stale lock is taken over.
The step touches the lock at each try only while it is still the one it
made; a lock that was removed or taken over meanwhile is left alone (never
made again by the touch), and the step goes on with the comparison below and
says so on stderr.
It also compares a copy: it builds the new file beside the old one and moves
it into place only while the file is still byte for byte the copy it read;
otherwise it reads again, up to five times with a growing pause, and then
fails without writing. That is the guard against a writer that takes no lock.
The config must be exactly one JSON document (a zero-byte file counts as
`{}`; whitespace alone, or two documents, fail the step), and so must the
state file. The step leaves a file whose JSON would not change byte for byte,
makes no file when nothing is declared and nothing was put in before, creates
a missing one with mode 600, keeps an existing one's mode, and follows a
symlink. On a link into the Nix store, or when Claude Code may read another
file (see Known gaps), it says so on stderr.

**Why not `programs.claude-code.mcpServers`.** home-manager renders those
into a plugin of its own. Claude Code then reports them in the scope
`plugin` as `plugin:hm:NAME`, and their tools are called
`mcp__plugin_hm_NAME__TOOL` instead of `mcp__NAME__TOOL`, so every
permission rule and skill that names a server's tools stops matching, and
`claude mcp remove` cannot take one out (checked with Claude Code 2.1.319).
A server in `~/.claude.json` is in the user scope, where `claude mcp add
--scope user` puts it, and keeps its name and its tools. The check
`claude-mcp` runs the real `claude mcp list` and `claude mcp get` on the
result and reads the scope from it.

## Tests

Every `*/tests/*.test.sh` runs with bash and no arguments, and in the
build sandbox as the check `claude-hooks`. The check `claude-home` builds a
home from the template's `me.nix` with both modules: the settings, the skill
values file, each wrapper running its script with no PATH, the activation's
two settings steps run in order on a file that holds herdr's entry, and
`claude` itself. `claude-package` checks the package and its download.
`claude-mcp` checks the MCP servers: the refusal of anything but a
reference, the step run on a config in which the real `claude mcp add` wrote
a server first (and no other key changing in any switch), `claude mcp list`
and `claude mcp get` reading the result, and the real `claude mcp add`
waiting for the lock that the step takes.

The prune suite runs itself in user and mount namespaces of its own, under
an unused uid and on a private tmpfs `/tmp`, so `/tmp/claude-<uid>` is the
hook's real root and a throwaway tree at once, and no case can reach the
machine's `/tmp`. It needs unprivileged user namespaces, nested four deep
for the mount cases; where they are off (Docker's default seccomp profile
refuses them), it fails and says so.

## Known gaps

- Both settings steps (`cas.sh`) take a lock beside the file and compare a
  copy before the move. Two programs that take a stale lock in the same
  moment can both hold it, and a writer that takes no lock and writes in the
  moment between the last comparison and the move is lost. A step that
  resumes after a stall of 10 s or more in the moment between its check of
  the lock and the touch or removal that follows can touch, and then remove,
  the lock of a writer that took it over meanwhile; proper-lockfile, which
  Claude Code uses, has the same gap. Claude Code takes the lock for
  `~/.claude.json`; nothing is known to take one for `settings.json`, so the
  hook step rests on the comparison there.
  home-manager's own merge into `settings.json`, which runs just before the
  hook step, has the same moment.
- A session that outlives a switch may later write an older copy of
  `settings.json` back, without ravnix's current hooks or with stale ones,
  if Claude Code does not read the file again before it writes. The next
  switch puts them right; whether Claude Code reads first is untested for
  that file. For `~/.claude.json` it does read again under its lock.
- A SIGTERM, SIGINT or SIGHUP that reaches a step in the few milliseconds
  in which it records the stamp of its own lock (when it makes the lock, and
  after each touch) leaves that lock behind, because the exit trap no longer
  recognises it as the step's own. It goes stale after 10 s and is taken
  over, as after SIGKILL, which leaves the lock and the two temporary files
  beside the config.
- A step that finds the lock held fails the activation after about 20 s,
  with nothing written to the config. Run the switch again.
- A settings link whose target does not exist is followed: the step creates
  the file it names, when there is something to add.
- Only `headers` and `env` are checked for references. Every other field is
  not: a token in a server's `url` (a query string, `user:password@`), its
  `args` (`--api-key X`), its `command` or its `headersHelper` is not found,
  and goes into the store. Put such a value in `headers` or `env`, or let
  the server read the variable itself. Two more places leak: when a string
  such as a header is defined twice with different values (in `me.nix` and a
  host), the module system's own conflict error prints both values before
  any assertion runs; and the refusal repeats server names and header or
  environment keys, which is harmless unless a token is pasted as a key.
- Claude Code may not read the file the MCP step writes. Version 2.1.319 reads
  an old `<configDir>/.config.json` instead of `.claude.json` when that
  file exists and is not empty (or is writable and `.claude.json` does not
  exist yet), and `.claude-custom-oauth.json` when
  `CLAUDE_CODE_CUSTOM_OAUTH_URL` is set. The step writes `.claude.json` all
  the same; it warns on stderr for the first when it sees the old file, and
  for the second when the variable is set in the environment of the switch.
  A config that is a link into the store is left alone with a message.
- A lone surrogate in `~/.claude.json` blocks every switch. jq refuses
  `"\ud83d"` (a string cut inside an emoji), which `JSON.stringify` writes
  for such a string, so the step fails with jq's message until the file is
  repaired. It fails closed and writes nothing. The same holds for
  `settings.json` and the hook step.
- If the state file of the MCP step is lost, the servers that ravnix put in
  and that were dropped from the declaration afterwards stay until `claude
  mcp remove`. A state file the step cannot read fails the activation and
  names the file, and is left as it was.
- Which servers are ravnix's is told by name alone, so ownership is lossy.
  A server of Claude Code's own that a declaration replaces (the same name,
  added by `claude mcp add`) is not restored when the declaration is
  dropped: it is deleted. A state file restored from a backup deletes a
  later hand-added server whose name it lists. A run that fails after it
  wrote the state, on a held lock say, leaves names in the state that were
  never put in.
- `prune-claude-tmp` prunes `/tmp/claude-<uid>` and nothing else, and
  `PRUNE_TMP_ROOT` cannot move it. A Claude Code that puts its temporary
  directory elsewhere leaves that one unpruned.
- The refusal of a root reached through a symbolic link, a `/tmp` that is
  one, has no test: the suite cannot make its own `/tmp` a link.
- `prune-claude-tmp` sees a live session only by an open file, a working
  directory or a change within `PRUNE_TMP_MAX_AGE_MIN`. A session idle for
  longer than that, with nothing open in its folder, loses the folder.
- `prune-claude-tmp` deletes as it goes: a `rm` that fails half-way leaves
  part of a folder, and that folder is neither counted nor logged.
- Two `prune-claude-tmp` runs at once may both report a folder that only
  one of them deleted.
