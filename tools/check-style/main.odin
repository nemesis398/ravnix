// check-style: the style check. It searches the given paths for what
// docs/style.md forbids and a program can see, and prints one line per hit:
//
//   file:line:rule
//
// The rules:
//
//   hex-color     a hex color (#rrggbb or #rrggbbaa; #rgb and #rgba in CSS
//                 files, in quotes and after a color property) outside
//                 modules/theme/. A bare rrggbb or rrggbbaa value of a color
//                 key (fuzzel, swaylock) counts too, unless it is a word made
//                 of the letters a to f (facade). Colors come from the theme
//                 module's roles, so the user's accent reaches them. A hex
//                 color in a comment counts.
//   radius        a border radius other than 0: border-radius and its
//                 per-corner forms, every key that ends in radius, a border
//                 key set to rounded, and round_corners or rounded_corners
//                 unless it is 0 or false. indicator-radius, ring-radius and
//                 lock-ring-radius are not among these; the lock ring is a
//                 gauge.
//   opacity       anything below fully opaque: opacity or a background,
//                 window or similar *_alpha key below 1, alpha(), rgba() and
//                 hsla() with alpha below 1, sway's opacity command (also in
//                 a quoted string), Neovim's winblend and pumblend above 0,
//                 the CSS keyword transparent (after a colon only on a color
//                 property, so prose such as "Default: transparent" is none),
//                 a hex color or a bare RRGGBBAA value of a color key whose
//                 alpha is not full. The exemptions are two parts of the lock
//                 ring: swaylock's inside-color and inside-*-color keys (the
//                 inside) and its separator-color (the tick between the
//                 highlight segments), the latter only fully clear (alpha
//                 00), with or without a #. A child that shows its parent
//                 uses the role color or inherit.
//   motion        a transition or animation key, or @keyframes, unless the
//                 key turns motion off (none, false, off, no, 0s); also
//                 enable-animations and gtk-enable-animations set to
//                 anything else, also as the last part of an attribute path
//                 (gtk.gtk3.extraConfig.gtk-enable-animations = true). Words
//                 that only contain the names, such as systemd.TransitionTime,
//                 are no keys.
//   mermaid-init  a Mermaid init block (%%{init: ...}%% or
//                 %%{initialize: ...}%% at the start of a line) that differs
//                 from the shared one in docs/mermaid-theme.json, compared
//                 without white space, or that never closes. The shared block
//                 may hold hex colors. Prose that mentions the syntax in the
//                 middle of a line is no block.
//
// Usage: check-style PATH...
//
// At least one path is required. A directory is searched whole, a file by
// itself, and a symbolic link is never followed. The check judges styling
// sources and leaves the rest alone, so it cannot fire on a hash, a revision,
// a test fixture meant to fail or a program's own color table:
//
//   judged        *.nix, *.css, *.scss, *.tcss, *.rasi, *.ini, *.conf,
//                 *.toml, *.jsonc, *.kdl, *.colors, and every other file
//                 below a modules/ or hosts/ directory (Sway's config has no
//                 extension), for all five rules; Markdown and Mermaid files
//                 (*.md, *.markdown, *.mmd, *.mermaid) for hex colors and
//                 Mermaid blocks. Images, fonts and lock files are never
//                 judged.
//   not judged    anywhere: a directory named .git or node_modules. At the
//                 root of the judged tree only: .worktrees/, .superpowers/,
//                 and the fixture roots tests/, scripts/tests/ and
//                 tools/NAME/tests/, where fixtures fail on purpose.
//   hex allowed   at the root of the judged tree only: below modules/theme/
//                 and docs/style.md, and below vendor/, the one root for
//                 vendored files. Those places may not be translucent, round
//                 or animated either: vendor/ is exempt from the hex rule and
//                 no other.
//
// The root of the judged tree is the current directory (files.odin). A line
// that is only a comment is not searched for radius, opacity and motion; the
// body lines of a block comment are, unless they start with a *. Block
// comments that end before the code on their line are cut out of it. In a
// document or in a trailing comment (# or //, -- in Lua), an all-digit
// #123456 is an issue number and no color, and so is a link target such as
// [x](#facade).
//
// The shared Mermaid theme is the file that RAVNIX_MERMAID_THEME names, else
// docs/mermaid-theme.json of the flake this program was built from.
//
// Exit status: 0 when nothing was found, 1 on a hit, 2 on bad usage, a path
// that does not exist, a missing shared theme, or a file or directory the
// search could not read.
//
// Ported from scripts/check-style.sh; README.md lists what differs.
// Changing this program so it finds less needs the maintainer's explicit
// approval (AGENTS.md, rule 6).
package check_style

import "core:fmt"
import "core:io"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/linux"

// The shared Mermaid theme of the flake this program was built from, which
// default.nix names; RAVNIX_MERMAID_THEME replaces it.
DEFAULT_THEME :: #config(MERMAID_THEME, "")
THEME_VARIABLE :: "RAVNIX_MERMAID_THEME"

PROGRAM :: "check-style"

Config :: struct {
	// The current directory, where the judged tree is rooted.
	cwd:   string,
	// The shared Mermaid theme, or "" for none.
	theme: string,
	// The longest line a file may have, in bytes; 0 is LINE_LIMIT.
	line_limit: int,
}

// run judges the paths and prints the hits to out and the verdict to err.
// It returns the exit status.
run :: proc(args: []string, cfg: Config, out, err: io.Writer) -> int {
	if len(args) == 0 {
		return usage(err)
	}
	for arg in args {
		if strings.has_prefix(arg, "-") {
			return usage(err)
		}
	}
	files: File_Set
	for arg in args {
		if arg == "" {
			fmt.wprintfln(err, "%s: : no such file or directory", PROGRAM)
			return 2
		}
		abs := absolute(cfg.cwd, arg)
		lmode, lerr := lstat_mode(abs)
		if lerr == .NONE && linux.S_ISLNK(lmode) {
			continue
		}
		mode, serr := stat_mode(abs)
		if serr != .NONE {
			fmt.wprintfln(err, "%s: %s: no such file or directory", PROGRAM, arg)
			return 2
		}
		switch {
		case linux.S_ISDIR(mode):
			if message := walk_dir(cfg.cwd, arg, &files); message != "" {
				fmt.wprintfln(err, "%s: %s", PROGRAM, message)
				return 2
			}
		case linux.S_ISREG(mode):
			// Judged by its place below the current directory, when it is below
			// it.
			rel := arg
			prefix := strings.concatenate({cfg.cwd, "/"}, context.temp_allocator)
			if strings.has_prefix(arg, prefix) {
				rel = arg[len(prefix):]
			}
			classify(rel, arg, &files)
		case:
			fmt.wprintfln(err, "%s: %s is neither a file nor a directory", PROGRAM, arg)
			return 2
		}
	}

	hits: [dynamic]Hit
	theme := Theme {
		path = cfg.theme,
	}
	for file in files.list {
		if message := judge_file(file, cfg, &theme, &hits); message != "" {
			fmt.wprintfln(err, "%s: %s", PROGRAM, message)
			return 2
		}
	}
	if len(hits) == 0 {
		return 0
	}
	slice.sort_by(hits[:], hit_less)
	count := 0
	for hit, i in hits {
		if i > 0 && hits[i - 1] == hit {
			continue
		}
		count += 1
		fmt.wprintfln(out, "%s:%d:%s", hit.path, hit.line, rule_name(hit.rule))
	}
	if count == 1 {
		fmt.wprintfln(err, "%s: 1 hit: docs/style.md names the rule on the line above", PROGRAM)
	} else {
		fmt.wprintfln(err, "%s: %d hits: docs/style.md names the rules above", PROGRAM, count)
	}
	return 1
}

usage :: proc(err: io.Writer) -> int {
	fmt.wprintfln(err, "usage: %s PATH...", PROGRAM)
	return 2
}

// By file name as bytes, then line, then rule: the order of sort(1) in the C
// locale.
hit_less :: proc(a, b: Hit) -> bool {
	if a.path != b.path {
		return a.path < b.path
	}
	if a.line != b.line {
		return a.line < b.line
	}
	return a.rule < b.rule
}

// judge_file reads one file line by line and applies every rule to it. The
// error text is empty on success.
judge_file :: proc(file: File, cfg: Config, theme: ^Theme, hits: ^[dynamic]Hit) -> string {
	reader, errno := reader_open(absolute(cfg.cwd, file.shown), cfg.line_limit)
	if errno != .NONE {
		return fmt.aprintf("cannot read %s: %v", file.shown, errno)
	}
	defer reader_close(&reader)
	j := Judge {
		file  = file,
		hits  = hits,
		theme = theme,
	}
	defer judge_destroy(&j)
	for {
		line, ok, rerr, rno := reader_next(&reader)
		switch rerr {
		case .None:
		case .Failed:
			return fmt.aprintf("cannot read %s: %v", file.shown, rno)
		case .Line_Too_Long:
			return fmt.aprintf("cannot read %s: a line is longer than %d bytes", file.shown, reader.limit)
		}
		if !ok {
			break
		}
		if fatal := judge_line(&j, line); fatal != "" {
			return fatal
		}
	}
	finish_file(&j)
	return ""
}

// The current directory as the shell would call it: $PWD when it names the
// current directory (so a path through a link is not resolved), else what the
// system says.
current_directory :: proc() -> (cwd: string, ok: bool) {
	buf: [4096]u8
	n, errno := linux.getcwd(buf[:])
	if errno != .NONE || n < 2 {
		return "", false
	}
	physical := strings.clone(string(buf[:n - 1]))
	if pwd, found := os.lookup_env("PWD", context.allocator); found && strings.has_prefix(pwd, "/") {
		a, aerr := stat_ino(pwd)
		b, berr := stat_ino(".")
		if aerr == .NONE && berr == .NONE && a == b {
			return pwd, true
		}
	}
	return physical, true
}

stat_ino :: proc(path: string) -> (id: [2]u64, errno: linux.Errno) {
	st: linux.Stat
	errno = linux.stat(clone_c(path), &st)
	return {u64(st.dev), u64(st.ino)}, errno
}

main :: proc() {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		os.exit(2)
	}
	context.allocator = virtual.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	cwd, ok := current_directory()
	if !ok {
		fmt.eprintfln("%s: cannot find the current directory", PROGRAM)
		os.exit(2)
	}
	theme := DEFAULT_THEME
	if from_env, found := os.lookup_env(THEME_VARIABLE, context.allocator); found {
		theme = from_env
	}
	status := run(os.args[1:], Config{cwd = cwd, theme = theme}, os.to_writer(os.stdout), os.to_writer(os.stderr))
	os.exit(status)
}
