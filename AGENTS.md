# Agent rules for ravnix

These rules apply to every AI agent that works in this repository. They are
short on purpose, and the git hooks enforce the ones that matter most.

## What this repository is

Ravnix is a NixOS flake that makes two machines one system: a laptop shape,
`huginn`, for the graphical applications, and a server shape, `muninn`, for
the terminal applications, so sessions survive a closed lid. This repository
is public and holds no personal value. Each user keeps their values in a
private flake of their own that imports this one; `templates/default/` is
its starting point.

| Path | Holds |
| --- | --- |
| `flake.nix` | the outputs: `nixosModules`, `homeModules`, `packages`, `checks`, `templates` |
| `modules/common/` | what both hosts share: shell, prompt, git, CLI tools, Claude Code, the user account |
| `modules/desktop/` | Sway, Waybar, fuzzel, dunst, swaylock, kanshi, greetd, the graphical applications |
| `modules/workbench/` | the server side: herdr, mail, chat, calendar, toolchains, Podman |
| `modules/hardware/` | one directory per supported laptop model |
| `modules/glue/` | the pieces that make two hosts one system |
| `modules/theme/` | the only place that defines colors, line widths, fonts and sizes |
| `hosts/` | the two shapes, `laptop` and `server` |
| `packages/` | derivations for what nixpkgs lacks |
| `tools/` | the tools ravnix writes itself, in Odin |
| `templates/default/` | the starter private flake |
| `docs/` | the install guide, the architecture, and `docs/style.md` |

Most of these paths do not exist yet. Each arrives with the work that fills
it.

## Rules

1. **Nothing personal enters this repository.** No name, mail address,
   hostname, IP address, domain, account ID or secret of any user, in a file
   or in a commit message. A personal value is a typed `ravnix.*` option that
   the private flake sets, with no default that looks like a real one. Secrets
   come from Bitwarden at runtime through `rbw` and live in neither
   repository. `scripts/check-public.sh` checks every file against a deny
   list kept outside this repository; the pre-commit hook runs it on every
   commit, and the commit-msg hook on every message. The authors' names and addresses in `LICENSE`, `AUTHORS` and the
   commit metadata are the only exception.
2. **Never write to a disk the configuration does not name.** The install
   target is chosen by model and serial from the private flake, never by a
   device name such as `nvme0n1`, because NVMe names can swap between boots.
   Run disko, `nixos-install` or anything else that writes a disk only against
   the device the disk guard prints, and only when the guard exits 0. Every
   other disk gets no partition, filesystem, bootloader or EFI change.
3. **Ask before anything needs the security key.** SSH to the git hosts needs
   a touch on the user's hardware key. Before each such command (fetch, pull,
   push, clone, `ls-remote`), ask in the question dialog, every time, and run
   the command only after the answer. Never switch to a route that skips the
   key on your own. Without a human to answer, do not start the command; say
   that it waits for the key.
4. **New tools are written in Odin.** Bash is for thin glue only: a wrapper or
   a keybinding target. Bash and Python tools carried over from an earlier
   setup stay as they are until their port, one tool at a time, behind their
   existing tests.
5. **Every tool has tests, and the tests hunt for problems:** edge cases,
   malformed input, missing files, empty and huge values, concurrent runs, a
   dead dependency. Odin tools use `core:testing`, Bash glue uses shell tests,
   and all of them run in `nix flake check`. Write the failing test first and
   watch it fail. A finding you do not fix goes into the tool's `README.md`.
6. **Run the gate before you say done, and show its output.** The gate is
   `scripts/check.sh`. The git hooks run its fast part on every commit and
   all of it before every push, and the Claude Code Stop hook runs the fast
   part before you stop. There is no CI, so nothing catches what the hooks
   miss: never pass `--no-verify` or override `core.hooksPath` (a guard
   refuses both), and never weaken a check, skip a test or widen an exemption
   to get green without the maintainer's explicit approval.
7. **Commit in Conventional Commits 1.0.0, in English.** One logical change
   per commit, a subject in the imperative of at most 72 characters, and a
   body that says why when that is not obvious. An agent's commit names the
   model in a `Co-Authored-By:` trailer.

## Build and test

```sh
scripts/check.sh --fast                      # what pre-commit and the Stop hook run
scripts/check.sh                             # the full gate, as pre-push runs it
nix build .#checks.x86_64-linux.NAME         # one Nix check
```

Turn the hooks on once per clone with `git config core.hooksPath .githooks`,
and point `git config ravnix.denyList` at your deny list; without it the gate
says the boundary check was skipped. The ravnix module sets both for the
checkout that `ravnix.dev.checkout` names. Before a push, `pre-push` also
checks every commit and message the push sends.

A test is a file, and adding one never touches `flake.nix`. Every
`tests/AREA/NAME.nix` is the check `AREA-NAME`: a function of
`{ self, inputs, pkgs, lib, system, ... }` that returns a derivation;
helpers and fixtures go in a subdirectory of the area. A shell test is
`scripts/tests/NAME.test.sh` on top of `scripts/tests/lib.sh`, and the check
`scripts-tests` runs it in the sandbox.

A host is built from a private flake, against a local checkout of this one:

```sh
nix build PRIVATE_FLAKE#nixosConfigurations.HOST.config.system.build.toplevel \
  --override-input ravnix path:.
```

## Style

Read [docs/style.md](docs/style.md) before you style anything: an
application, a screen, a diagram or a document. It holds the rules and the
reasons. When something new needs styling, walk this list in order:

1. Background is Base. A strip that frames the work is Mantle. Text is Text.
2. Is it floating? Then a 1 px accent frame. Otherwise no frame.
3. Spend the accent on focus and place only: the active item, icons, the
   prompt, matches, and the cursor.
4. State gets a state color. Warm hues are for warnings and errors and
   nothing else.
5. Square corners. No shadow, no gradient, no blur, no transparency, no
   animation.
6. JetBrainsMono Nerd Font. Pick the size by job: small to read, large to
   glance at.
7. Anything whose value changes gets a fixed width.
8. A row is a Surface wash. A fill is for where you are, and only one per
   list.
9. If the application cannot be made to follow this, list it as an exception
   with the reason, in the module that installs it.

Never write a hex color outside `modules/theme/`. Read the color from the
theme module's roles, so the user's accent reaches it.
