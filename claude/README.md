# Claude Code: hooks, status line and skill values

This directory holds the Bash that ravnix runs inside Claude Code: the hooks
in `hooks/` and the status line in `statusline/`. They came over from an
earlier setup and stay Bash, behind their tests, until their port to Odin
(AGENTS.md, rule 4). Two home-manager modules install them:

| Module | Does |
| --- | --- |
| `homeModules.claude-code` (`modules/common/claude-code.nix`) | `claude` on PATH, from `packages.claude-code`; the auto-updater off; the settings file writable |
| `homeModules.claude-skills` (`modules/common/claude-skills.nix`) | the skill values file, the hooks and the status line, wired in the settings |

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

Claude Code writes the file at any time, without a lock. The step reads a
copy, and moves its result into place only while the file is still that
copy; when another write came in between, it reads the file again, up to
five times, and then fails the activation without writing. So a write by
Claude Code that lands before the step's last comparison is kept; one in
the moment between that comparison and the move can still be lost (Known
gaps).

With `mutableSettings = false` home-manager links the file whole from the
store. Then the step is off, and ravnix declares its hooks in that file.

## Tests

Every `*/tests/*.test.sh` runs with bash and no arguments, and in the
build sandbox as the check `claude-hooks`. The check `claude-home` builds a
home from the template's `me.nix` with both modules: the settings, the skill
values file, each wrapper running its script with no PATH, the activation's
two settings steps run in order on a file that holds herdr's entry, and
`claude` itself. `claude-package` checks the package and its download.

The prune suite runs itself in user and mount namespaces of its own, under
an unused uid and on a private tmpfs `/tmp`, so `/tmp/claude-<uid>` is the
hook's real root and a throwaway tree at once, and no case can reach the
machine's `/tmp`. It needs unprivileged user namespaces, nested four deep
for the mount cases; where they are off (Docker's default seccomp profile
refuses them), it fails and says so.

## Known gaps

- The settings step compares the file with its copy just before it moves
  its result into place. A write by Claude Code in the moment between that
  comparison and the move is lost. home-manager's own merge, which runs just
  before the step, has the same moment.
- A session that outlives a switch may later write an older copy of the
  settings back, without ravnix's current hooks or with stale ones, if
  Claude Code does not read the file again before it writes. The next switch
  puts them right; whether Claude Code reads first is untested.
- A settings link whose target does not exist is followed: the step creates
  the file it names, when there is something to add.
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
